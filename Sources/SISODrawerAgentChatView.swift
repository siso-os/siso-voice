import AppKit
import WebKit

/// Native JARVIS chat view: a scrollable message log + composer that talks to the
/// JARVIS Opus pane over `HerdrBridge` and mirrors the saved conversation log.
///
/// Extracted verbatim from the old `SidebarDrawerManager.swift` (the only part of
/// that file worth keeping). Hosted by `EdgeDockController`'s JARVIS tab.
final class SISODrawerAgentChatView: NSView {
    private let messagesScrollView = NSScrollView()
    private let messagesTextView = NSTextView()
    private let inputField = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let pushLogButton = NSButton(title: "Send log → JARVIS", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        layer?.cornerRadius = 12

        sisoSetupViews()
        loadConversationHistory()

        // Reload history whenever a new turn is sent, so the pane reflects the full conversation.
        NotificationCenter.default.addObserver(
            forName: TranscriptRouter.didSendToJarvis, object: nil, queue: .main
        ) { [weak self] _ in self?.loadConversationHistory() }

        // Show orb-tapped / voice exchanges here too (TranscriptRouter broadcasts them).
        NotificationCenter.default.addObserver(
            forName: TranscriptRouter.chatTurn, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let role = note.userInfo?["role"] as? String,
                  let text = note.userInfo?["text"] as? String else { return }
            switch role {
            case "You":          self.appendChatLine("You: \(text)", color: NSColor(calibratedWhite: 0.93, alpha: 1))
            case "JARVIS":       self.appendChatLine("JARVIS: \(text)", color: NSColor.systemTeal)
            case "JARVIS-final": self.replaceLastLine(with: "JARVIS: \(text)", color: NSColor.systemTeal)
            default:             self.appendChatLine("\(role): \(text)")
            }
        }
    }

    /// Replace the trailing line (used to swap the "JARVIS: …" placeholder for the real reply).
    private func replaceLastLine(with text: String, color: NSColor) {
        guard let storage = messagesTextView.textStorage else { return }
        let full = storage.string as NSString
        let lastNL = full.range(of: "\n", options: .backwards)
        let start = lastNL.location == NSNotFound ? 0 : lastNL.location + 1
        let range = NSRange(location: start, length: storage.length - start)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: color
        ]
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
        messagesTextView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Load JARVIS's conversation into the pane so opening the chat shows the real conversation.
    /// Two sources merged: (1) the saved conversation log files (voice/orb-tap/typed turns), and
    /// (2) a LIVE MIRROR of what JARVIS just said in its Opus pane — so the drawer reflects JARVIS
    /// no matter how it was messaged (pane, drawer, or voice), not just drawer-originated chat.
    func loadConversationHistory() {
        messagesTextView.textStorage?.setAttributedString(NSAttributedString(string: ""))

        // (1) All saved conversation files, oldest→newest (not just the newest — fixes the date-roll
        // empty where a new day has no file yet).
        let dir = "\(NSHomeDirectory())/SISO_Workspace/.agents/jarvis/memory/conversations"
        let logs = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".md") }.sorted()
        var shown = 0
        for file in logs {
            guard let content = try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8) else { continue }
            for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(raw)
                guard line.hasPrefix("**["), let close = line.range(of: ":**") else { continue }
                let head = String(line[line.startIndex..<close.lowerBound])
                let text = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                let isJarvis = head.contains("JARVIS")
                let isShaan = head.contains("Shaan") || head.contains("You")
                let speaker = isJarvis ? "JARVIS" : (isShaan ? "You" : "system")
                let color: NSColor = isJarvis ? .systemTeal : (isShaan ? NSColor(calibratedWhite: 0.93, alpha: 1) : NSColor(calibratedWhite: 0.5, alpha: 1))
                appendChatLine("\(speaker): \(text)", color: color)
                shown += 1
            }
        }

        // (2) Live mirror: pull JARVIS's latest reply from its Opus pane (covers conversations that
        // happened in the herdr pane and were never written to the log). Off the main thread.
        if SISOVoiceConfig.jarvisHerdrBridgeEnabled {
            jarvisQueue.async { [weak self] in
                guard let pane = (try? HerdrBridge.resolveOpusPane()) ?? nil,
                      let snapshot = try? HerdrBridge.readPane(pane, lines: 40) else { return }
                let reply = SISODrawerAgentChatView.extractReply(from: snapshot, notIn: "")
                guard !reply.isEmpty else { return }
                DispatchQueue.main.async {
                    // Avoid duplicating if it's already the last line.
                    if !(self?.messagesTextView.string.hasSuffix(reply) ?? false) {
                        self?.appendChatLine("JARVIS (live): \(reply)", color: .systemTeal)
                    }
                }
            }
        }

        if shown == 0 {
            appendChatLine("Mirroring JARVIS — its latest from the pane appears here. Tap the orb or type to talk.",
                           color: NSColor(calibratedWhite: 0.5, alpha: 1))
        }
    }

    private func sisoSetupViews() {
        messagesScrollView.translatesAutoresizingMaskIntoConstraints = false
        messagesScrollView.hasVerticalScroller = true
        messagesScrollView.hasHorizontalScroller = false
        messagesScrollView.drawsBackground = false
        messagesScrollView.borderType = .noBorder

        messagesTextView.isEditable = false
        messagesTextView.isSelectable = true
        messagesTextView.isAutomaticTextCompletionEnabled = false
        messagesTextView.isAutomaticTextReplacementEnabled = false
        messagesTextView.textContainerInset = NSSize(width: 10, height: 10)
        messagesTextView.backgroundColor = NSColor.clear
        messagesTextView.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        messagesTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        messagesTextView.drawsBackground = false
        messagesTextView.insertionPointColor = NSColor.clear
        messagesTextView.textContainer?.widthTracksTextView = true
        messagesTextView.isVerticallyResizable = true
        messagesTextView.isHorizontallyResizable = false
        messagesTextView.autoresizingMask = [.width]
        messagesScrollView.documentView = messagesTextView

        inputField.placeholderString = "Type a message…"
        inputField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        inputField.isBezeled = true
        inputField.bezelStyle = .roundedBezel
        inputField.isBordered = true
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.target = self
        inputField.action = #selector(sisoSendTapped(_:))
        inputField.focusRingType = .default

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sisoSendTapped(_:))
        sendButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        sendButton.keyEquivalent = "\r"

        pushLogButton.translatesAutoresizingMaskIntoConstraints = false
        pushLogButton.bezelStyle = .rounded
        pushLogButton.target = self
        pushLogButton.action = #selector(sisoPushLogTapped(_:))
        pushLogButton.font = NSFont.systemFont(ofSize: 11, weight: .regular)

        if !SISOVoiceConfig.jarvisHerdrBridgeEnabled {
            inputField.isEnabled = false
            sendButton.isEnabled = false
            pushLogButton.isEnabled = false
        }

        addSubview(messagesScrollView)
        addSubview(inputField)
        addSubview(sendButton)
        addSubview(pushLogButton)

        messagesScrollView.documentView = messagesTextView
    }

    override func layout() {
        super.layout()

        let inset: CGFloat = 10
        let buttonWidth: CGFloat = 76
        let composerHeight: CGFloat = 32
        let pushBarHeight: CGFloat = 26
        let composerY = inset
        let composerWidth = max(0, bounds.width - inset * 2)
        let fieldWidth = max(0, composerWidth - buttonWidth - 8)

        // Composer row (bottom).
        inputField.frame = NSRect(x: inset, y: composerY, width: fieldWidth, height: composerHeight)
        sendButton.frame = NSRect(x: inset + fieldWidth + 8, y: composerY, width: buttonWidth, height: composerHeight)

        // Push-log bar (just above the composer).
        let pushBarY = composerY + composerHeight + 6
        pushLogButton.frame = NSRect(x: inset, y: pushBarY, width: composerWidth, height: pushBarHeight)

        // Message log (fills the rest above the push bar).
        let logY = pushBarY + pushBarHeight + 8
        messagesScrollView.frame = NSRect(
            x: inset,
            y: logY,
            width: composerWidth,
            height: max(0, bounds.height - logY - inset)
        )
    }

    private let jarvisQueue = DispatchQueue(label: "com.siso.voice.jarvis", qos: .userInitiated)
    private var awaitingReply = false

    @objc private func sisoSendTapped(_ sender: AnyObject?) {
        guard SISOVoiceConfig.jarvisHerdrBridgeEnabled else {
            appendChatLine("JARVIS send disabled.", color: NSColor.systemOrange)
            return
        }

        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !awaitingReply else { return }

        appendChatLine("You: \(text)", color: NSColor(calibratedWhite: 0.93, alpha: 1))
        inputField.stringValue = ""
        inputField.becomeFirstResponder()
        sendToJarvis(text)
    }

    /// Push the whole chat/voice log into JARVIS's inbox, then ping Opus to read it.
    /// This is the "catch up on what I've been doing" button.
    @objc private func sisoPushLogTapped(_ sender: AnyObject?) {
        guard SISOVoiceConfig.jarvisHerdrBridgeEnabled else {
            appendChatLine("JARVIS log push disabled.", color: NSColor.systemOrange)
            return
        }

        guard !awaitingReply else { return }
        let log = messagesTextView.string
        guard !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        appendChatLine("→ pushing log to JARVIS inbox…", color: NSColor(calibratedWhite: 0.55, alpha: 1))
        jarvisQueue.async { [weak self] in
            guard let self else { return }
            // Write a timestamped inbox file (the shared-brain drop-box, agent-zero style).
            let home = "\(NSHomeDirectory())/SISO_Workspace/.agents/jarvis/inbox"
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
            let stamp = fmt.string(from: Date()).replacingOccurrences(of: ":", with: "")
            let path = "\(home)/\(stamp)-orb-chatlog.md"
            let body = "# Chat/voice log pushed from the orb — \(Date())\n\n\(log)\n"
            do {
                try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
                try body.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                self.replaceThinking(with: "Couldn't write inbox: \(error)", color: NSColor.systemRed)
                return
            }
            // Ping Opus to read the new inbox file (if it's booted).
            if let pane = (try? HerdrBridge.resolveOpusPane()) ?? nil {
                try? HerdrBridge.send("I dropped a new log in your inbox/ — read the newest file and catch up.", toPane: pane)
            }
            DispatchQueue.main.async {
                self.appendChatLine("✓ log in JARVIS inbox — Opus pinged to read it.", color: NSColor.systemGreen)
            }
        }
    }

    /// Send a message to the JARVIS Opus pane and stream the reply back into the log.
    func sendToJarvis(_ text: String) {
        guard SISOVoiceConfig.jarvisHerdrBridgeEnabled else {
            appendChatLine("JARVIS send disabled.", color: NSColor.systemOrange)
            return
        }

        awaitingReply = true
        let thinkingLine = "JARVIS: …"
        appendChatLine(thinkingLine, color: NSColor.systemTeal)

        jarvisQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let pane = try HerdrBridge.resolveOpusPane() else {
                    self.replaceThinking(with: "JARVIS isn't booted — open the JARVIS workspace (Opus pane) in herdr.", color: NSColor.systemOrange)
                    return
                }
                // Snapshot before sending so we can tell the reply apart from prior scrollback.
                let before = (try? HerdrBridge.readPane(pane, lines: 60)) ?? ""
                try HerdrBridge.send(text, toPane: pane)

                // Poll until the reply block stabilizes (Claude renders incrementally).
                var last = ""
                var stableCount = 0
                for _ in 0..<40 {   // ~20s max (40 * 0.5s)
                    Thread.sleep(forTimeInterval: 0.5)
                    let now = (try? HerdrBridge.readPane(pane, lines: 60)) ?? ""
                    let reply = Self.extractReply(from: now, notIn: before)
                    if !reply.isEmpty && reply == last {
                        stableCount += 1
                        if stableCount >= 2 {   // unchanged across ~1s → done
                            self.replaceThinking(with: "JARVIS: \(reply)", color: NSColor.systemTeal)
                            return
                        }
                    } else {
                        stableCount = 0
                    }
                    last = reply
                }
                if last.isEmpty {
                    self.replaceThinking(with: "JARVIS: (no reply captured — check the pane)", color: NSColor.systemOrange)
                } else {
                    self.replaceThinking(with: "JARVIS: \(last)", color: NSColor.systemTeal)
                }
            } catch {
                self.replaceThinking(with: "JARVIS bridge error: \(error)", color: NSColor.systemRed)
            }
        }
    }

    /// Replace the trailing "JARVIS: …" placeholder line with the final text (main thread).
    private func replaceThinking(with text: String, color: NSColor) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = self.messagesTextView.textStorage else { return }
            let full = storage.string as NSString
            // Find the last line and replace it.
            let lastNL = full.range(of: "\n", options: .backwards)
            let lineStart = lastNL.location == NSNotFound ? 0 : lastNL.location + 1
            let range = NSRange(location: lineStart, length: storage.length - lineStart)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color
            ]
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
            self.messagesTextView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
            self.awaitingReply = false
        }
    }

    /// Extract JARVIS's reply from a Claude pane snapshot: the text under the LAST `⏺` marker,
    /// stripping TUI chrome (input echo, status bar, recaps, frame lines). `notIn` is the
    /// pre-send snapshot used to ignore stale prior replies that look identical.
    static func extractReply(from snapshot: String, notIn before: String) -> String {
        var reply: [String] = []
        var capturing = false
        for raw in snapshot.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("⏺") {
                reply = [String(s.dropFirst()).trimmingCharacters(in: .whitespaces)]
                capturing = true
                continue
            }
            if capturing {
                if s.isEmpty || s.hasPrefix("✻") || s.hasPrefix("※") || s.hasPrefix("❯")
                    || s.hasPrefix("─") || s.hasPrefix("⏵") || s.contains("Opus 4.8 |")
                    || s.contains("JARVIS-OPUS") {
                    capturing = false
                    continue
                }
                reply.append(s)
            }
        }
        return reply.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func appendChatLine(_ text: String, color: NSColor = NSColor(calibratedWhite: 0.93, alpha: 1)) {
        guard let storage = messagesTextView.textStorage else { return }
        let prefix = storage.length > 0 ? "\n" : ""
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: color
        ]
        storage.append(NSAttributedString(string: "\(prefix)\(text)", attributes: attrs))
        messagesTextView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }
}
