import Foundation

/// SpineOutbox — append-only, fire-and-forget bridge from SISO Voice to the
/// JARVIS spine. Every dictation transcript (TEXT ONLY, never audio) is written
/// as ONE NDJSON line to ~/.siso/voice-outbox.ndjson. A separate Python drainer
/// (extensions/voice/voice-sync.py) flushes the file to the Mac Mini brain-API.
///
/// Self-contained: import Foundation only, no dependency on other freeflow files.
/// Never throws into the caller — errors are swallowed and logged so a dictation
/// is never blocked by the mirror.
enum SpineOutbox {
    /// Serial queue keeps appends ordered and avoids interleaved partial lines.
    private static let queue = DispatchQueue(label: "com.siso.voice.spine-outbox")

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Append one utterance to the outbox. Keys are snake_case matching the
    /// voice_utterances SQL columns. Returns immediately; the write happens
    /// asynchronously on the serial queue.
    static func append(
        clientID: String,
        capturedAt: Date,
        rawTranscript: String,
        cleanedTranscript: String?,
        intent: String,
        appName: String?,
        bundleID: String?,
        windowTitle: String?,
        model: String?,
        wordCount: Int
    ) {
        let machine = Host.current().localizedName ?? "macbook"
        var record: [String: Any] = [
            "client_id": clientID,
            "captured_at": iso.string(from: capturedAt),
            "raw_transcript": rawTranscript,
            "intent": intent,
            "word_count": wordCount,
            "machine": machine,
        ]
        if let cleanedTranscript { record["cleaned_transcript"] = cleanedTranscript }
        if let appName { record["app_name"] = appName }
        if let bundleID { record["bundle_id"] = bundleID }
        if let windowTitle { record["window_title"] = windowTitle }
        if let model { record["model"] = model }

        queue.async {
            do {
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                guard var line = String(data: data, encoding: .utf8) else {
                    NSLog("[SpineOutbox] failed to encode record as UTF-8")
                    return
                }
                line += "\n"
                let dir = sisoDir()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("voice-outbox.ndjson")
                guard let bytes = line.data(using: .utf8) else { return }
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: bytes)
                } else {
                    // file does not exist yet — create it with this first line
                    try bytes.write(to: url, options: .atomic)
                }
            } catch {
                NSLog("[SpineOutbox] append failed: \(error.localizedDescription)")
            }
        }
    }

    /// Convenience: mirror a finalized PipelineHistoryItem. Maps freeflow's
    /// history record onto the outbox primitives. `cleaned` is the
    /// post-processed transcript when it differs from raw and is non-empty.
    static func append(entry: PipelineHistoryItem, model: String?) {
        let raw = entry.rawTranscript
        let processed = entry.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned: String? = (!processed.isEmpty && processed != raw) ? entry.postProcessedTranscript : nil
        let wordCount = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        append(
            clientID: entry.id.uuidString,
            capturedAt: entry.timestamp,
            rawTranscript: raw,
            cleanedTranscript: cleaned,
            intent: entry.intent.rawValue,
            appName: entry.contextAppName,
            bundleID: entry.contextBundleIdentifier,
            windowTitle: entry.contextWindowTitle,
            model: model,
            wordCount: wordCount
        )
    }

    private static func sisoDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".siso", isDirectory: true)
    }
}
