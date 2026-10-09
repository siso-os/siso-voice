import Foundation

/// TranscriptRouter — owns deliberate JARVIS sends from the shortcut/chat surface.
///
/// This is a deliberate carve-out from AppState (the god-file): AppState still asks the router
/// "did you handle this?" at the paste point, but normal dictation is no longer auto-routed.
/// Deliberate shortcut/chat sends go through `sendToJarvis`.
enum TranscriptRouter {

    /// JARVIS mode is no longer persisted or armed. Sends are deliberate one-shot actions.
    static var isJarvisMode: Bool {
        false
    }

    static let jarvisHome = "\(NSHomeDirectory())/SISO_Workspace/.agents/jarvis"
    static let jarvisSessionTranscriptPath =
        "\(NSHomeDirectory())/.claude/projects/-Users-shaansisodia-SISO-Workspace--agents-jarvis/5c6479d5-6b39-4a3b-b890-a35d7850ceff.jsonl"
    private static let jarvisReplyTimeout: TimeInterval = 300
    private static let jarvisReplyPollInterval: TimeInterval = 0.5

    /// Deliver a finished transcript through the normal dictation path. This intentionally does
    /// not auto-route to JARVIS; AppState handles an armed JARVIS turn explicitly at finalization.
    @discardableResult
    static func deliver(_: String) -> Bool {
        return false   // paste continues unless AppState consumed an armed JARVIS turn
    }

    /// Posted when something is sent to JARVIS, so the UI can surface the chat drawer to show the reply.
    static let didSendToJarvis = Notification.Name("didSendToJarvis")
    /// Posted with a turn to display in the chat drawer. userInfo: ["role": String, "text": String].
    static let chatTurn = Notification.Name("jarvisChatTurn")

    /// Broadcast a turn to the chat drawer UI.
    static func postChatTurn(role: String, text: String) {
        NotificationCenter.default.post(name: chatTurn, object: nil, userInfo: ["role": role, "text": text])
    }

    // MARK: - Routing

    /// Public entry: send arbitrary text to JARVIS.
    /// Logs it, opens the response surface, routes it.
    static func sendToJarvis(_ text: String) {
        guard SISOVoiceConfig.jarvisHerdrBridgeEnabled else { return }

        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Surface the chat drawer so Shaan sees the reply land (he asked: "will I see responses?").
        NotificationCenter.default.post(name: didSendToJarvis, object: nil)
        postChatTurn(role: "You", text: t)
        postChatTurn(role: "JARVIS", text: "…")
        DispatchQueue.global(qos: .userInitiated).async {
            logConversation(role: "Shaan", text: t)
            routeToJarvis(t)
        }
    }

    private static func routeToJarvis(_ text: String) {
        do {
            guard let pane = try HerdrBridge.resolveOpusPane() else {
                let message = "JARVIS is not booted — message saved to memory, not delivered."
                logConversation(role: "system", text: "(\(message))")
                postChatTurn(role: "JARVIS-error", text: message)
                return
            }
            let transcriptOffset = currentSessionTranscriptOffset()
            try HerdrBridge.send(text, toPane: pane)
            // Capture JARVIS's reply from the Claude session JSONL, not terminal scrollback.
            captureAndLogReply(afterOffset: transcriptOffset)
        } catch {
            let message = "JARVIS bridge error: \(error)"
            logConversation(role: "system", text: "(\(message))")
            postChatTurn(role: "JARVIS-error", text: message)
        }
    }

    /// Tail the JARVIS Claude session JSONL until the next completed assistant text reply lands.
    private static func captureAndLogReply(afterOffset offset: UInt64) {
        if let reply = waitForAssistantReply(afterOffset: offset) {
            logConversation(role: "JARVIS", text: reply)
            postChatTurn(role: "JARVIS-final", text: reply)
            return
        }

        postChatTurn(
            role: "JARVIS-timeout",
            text: "No completed JARVIS reply appeared in the session log within 5 minutes."
        )
    }

    private static func currentSessionTranscriptOffset() -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: jarvisSessionTranscriptPath) else {
            return 0
        }
        defer { handle.closeFile() }
        return handle.seekToEndOfFile()
    }

    private static func waitForAssistantReply(afterOffset startOffset: UInt64) -> String? {
        let deadline = Date().addingTimeInterval(jarvisReplyTimeout)
        var offset = startOffset
        var pending = ""

        while Date() < deadline {
            guard let handle = FileHandle(forReadingAtPath: jarvisSessionTranscriptPath) else {
                Thread.sleep(forTimeInterval: jarvisReplyPollInterval)
                continue
            }

            let size = sessionTranscriptSize()
            if offset > size { offset = 0 }

            handle.seek(toFileOffset: offset)
            let data = handle.readDataToEndOfFile()
            offset = handle.offsetInFile
            handle.closeFile()

            if !data.isEmpty {
                pending += String(decoding: data, as: UTF8.self)
                let lines = pending.components(separatedBy: "\n")
                pending = lines.last ?? ""

                for line in lines.dropLast() {
                    if let reply = assistantReplyText(fromJSONLine: line) {
                        return reply
                    }
                }
            }

            Thread.sleep(forTimeInterval: jarvisReplyPollInterval)
        }

        return nil
    }

    private static func sessionTranscriptSize() -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: jarvisSessionTranscriptPath),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private static func assistantReplyText(fromJSONLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["type"] as? String) == "assistant",
              let message = root["message"] as? [String: Any],
              (message["role"] as? String) == "assistant" else {
            return nil
        }

        let stopReason = message["stop_reason"] as? String
        guard stopReason == nil || stopReason == "end_turn" || stopReason == "stop_sequence" else {
            return nil
        }

        let text = assistantText(from: message["content"])
        return text.isEmpty ? nil : text
    }

    private static func assistantText(from content: Any?) -> String {
        if let text = content as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text",
                  let text = block["text"] as? String else {
                return nil
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    // MARK: - Conversation persistence

    /// Append a turn to today's conversation log in JARVIS's home. Verbatim, durable — this is
    /// what lets JARVIS "remember everything you ever said to it" and be pushed to read recent history.
    static func logConversation(role: String, text: String) {
        let dir = "\(jarvisHome)/memory/conversations"
        let day = Self.dayFormatter.string(from: Date())
        let path = "\(dir)/\(day).md"
        let stamp = Self.timeFormatter.string(from: Date())
        let line = "**[\(stamp)] \(role):** \(text)\n\n"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                handle.closeFile()
            } else {
                let header = "# JARVIS conversation — \(day)\n\n"
                try (header + line).write(toFile: path, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("[TranscriptRouter] conversation log failed: \(error.localizedDescription)")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}
