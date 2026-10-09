//
//  SpineSyncStatus.swift
//  SISO Voice (freeflow fork) — Instructions & Account page (§3.5)
//
//  Reads the spine-sync state for the Account page. Foundation-only, no
//  dependency on other freeflow files.
//
//  Truth model:
//   - The outbox `~/.siso/voice-outbox.ndjson` is append-only; its line count is
//     the total utterances ever written by SISO Voice (a proxy, not "pending").
//   - The drainer `extensions/voice/voice-sync.py` is expected (separate upstream
//     task) to write `~/.siso/voice-sync-state.json` = {synced_count, last_flush_at}
//     after each flush. Until that file exists we CANNOT know the real synced
//     count, so we report the outbox line count as a total and label synced "—"
//     rather than fabricate a number.
//

import Foundation

// MARK: - SpineSyncSnapshot

struct SpineSyncSnapshot {
    /// Total lines in the outbox file (utterances ever queued). Proxy for volume.
    let outboxCount: Int
    /// Real synced count from voice-sync-state.json, or nil when unavailable.
    let syncedCount: Int?
    /// ISO timestamp of the last drainer flush, or nil when unavailable.
    let lastFlushISO: String?

    /// True when a real sync-state file was found (synced count is trustworthy).
    var hasRealSyncState: Bool { syncedCount != nil }

    /// Pending = outbox total − synced, when the real synced count is known.
    /// nil when we have no sync-state file (don't fabricate).
    var pendingCount: Int? {
        guard let synced = syncedCount else { return nil }
        return max(0, outboxCount - synced)
    }

    static let empty = SpineSyncSnapshot(outboxCount: 0, syncedCount: nil, lastFlushISO: nil)
}

// MARK: - SpineSyncReader

enum SpineSyncReader {

    /// Read the current spine-sync snapshot from the `~/.siso` files. Pure I/O;
    /// never throws into the caller — missing files yield the empty snapshot.
    static func read() -> SpineSyncSnapshot {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".siso", isDirectory: true)

        let outboxCount = lineCount(at: dir.appendingPathComponent("voice-outbox.ndjson"))
        let (synced, flush) = syncState(at: dir.appendingPathComponent("voice-sync-state.json"))

        return SpineSyncSnapshot(outboxCount: outboxCount,
                                 syncedCount: synced,
                                 lastFlushISO: flush)
    }

    /// Count non-empty newline-delimited records in the outbox.
    private static func lineCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// Parse `voice-sync-state.json` if present: {synced_count, last_flush_at}.
    private static func syncState(at url: URL) -> (Int?, String?) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        let synced = (obj["synced_count"] as? Int)
            ?? (obj["synced_count"] as? NSNumber)?.intValue
        let flush = obj["last_flush_at"] as? String
        return (synced, flush)
    }
}
