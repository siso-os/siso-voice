//
//  ShareCardStats.swift
//  SISO Voice (freeflow fork) — Stats Share-Card (UI v2 §3.2)
//
//  Pure value types: `ShareCardStats` computes every figure shown on the
//  ticket from a `[PipelineHistoryItem]`, and `ShareCardLevel` defines the
//  SISO-themed gamification curve + title band table. No AppKit, no SwiftUI
//  state — deterministic, testable, and safe to render inside `ImageRenderer`.
//
//  Namespaced `ShareCard*` so it never collides with the private
//  `MainWindowStats`/`MainWindowText` (intentional by-design duplication per
//  spec — those are `private` to MainWindowView).
//
//  Target: Swift 6.1 / SwiftUI on macOS 13+.
//

import Foundation

// MARK: - Tuning constants (honest, named)

enum ShareCardConstants {
    /// Typical sustained typing speed (words/minute) used to estimate how much
    /// time dictation saved vs. typing. 40 WPM is a conservative average for
    /// real-world prose typing (incl. thinking/pauses), matching the Home pill.
    static let typingWPM: Double = 40

    /// XP-per-level curve: words needed to reach level L is `100 * L^2`, so
    /// `level = floor(sqrt(totalWords / 100)) + 1`. A square-root curve means
    /// each level takes progressively more words — classic gamification ramp.
    static let xpPerLevelBase: Double = 100
}

// MARK: - Level model

/// The gamified SISO level: a level index, a themed title, and progress toward
/// the next level. Titles are SISO-themed scale bands (NOT Aqua's oceans).
struct ShareCardLevel {
    let level: Int
    let title: String
    /// Words accumulated within the current level.
    let xpInLevel: Int
    /// Words required to span the current level (xpForNext − xpForCurrent).
    let xpForNext: Int
    /// Total words still needed to reach the next level.
    let wordsToNext: Int

    /// Fraction (0...1) of the way through the current level.
    var progress: Double {
        guard xpForNext > 0 else { return 0 }
        return min(1.0, max(0.0, Double(xpInLevel) / Double(xpForNext)))
    }

    /// SISO-themed title bands keyed by level. Beyond the table, the top band
    /// repeats — you've maxed the named ranks.
    static func title(for level: Int) -> String {
        // Scale-of-leverage theme: from a single keystroke up to a fleet/JARVIS.
        let bands = [
            "Whisper",        // Lv 1
            "Signal",         // Lv 2
            "Operator",       // Lv 3
            "Conductor",      // Lv 4
            "Architect",      // Lv 5
            "Vanguard",       // Lv 6
            "Overclock",      // Lv 7
            "Singularity",    // Lv 8
            "Hypervisor",     // Lv 9
            "JARVIS Tier"     // Lv 10+
        ]
        let idx = min(max(level - 1, 0), bands.count - 1)
        return bands[idx]
    }

    /// Compute the level for a given total word count using the sqrt curve.
    static func compute(totalWords: Int) -> ShareCardLevel {
        let words = max(0, totalWords)
        let base = ShareCardConstants.xpPerLevelBase
        // level = floor(sqrt(words / base)) + 1
        let level = Int((Double(words) / base).squareRoot().rounded(.down)) + 1
        // Words required to *reach* level L (the start of L): base * (L-1)^2.
        let xpForCurrent = Int(base * Double(level - 1) * Double(level - 1))
        let xpForNextLevel = Int(base * Double(level) * Double(level))
        let span = xpForNextLevel - xpForCurrent
        let inLevel = words - xpForCurrent
        return ShareCardLevel(
            level: level,
            title: title(for: level),
            xpInLevel: max(0, inLevel),
            xpForNext: max(1, span),
            wordsToNext: max(0, xpForNextLevel - words)
        )
    }
}

// MARK: - Stats model

/// Every figure rendered on the share-card ticket, computed once from history.
struct ShareCardStats {
    let totalWords: Int
    let wordsToday: Int
    let entries: Int
    /// Words-per-minute estimate, or `nil` when not derivable (<2 entries or
    /// <1 minute of span).
    let wpm: Int?
    /// Most-frequent `contextAppName`, or `nil` when none recorded.
    let topApp: String?
    /// Consecutive days back from today with ≥1 entry.
    let streakDays: Int
    /// Estimated minutes saved vs. typing at `typingWPM`.
    let timeSavedMinutes: Int
    let level: ShareCardLevel

    var isEmpty: Bool { entries == 0 }

    // MARK: Formatting helpers

    /// Grouped total, e.g. "345,599".
    var totalWordsFormatted: String { Self.grouped(totalWords) }

    /// "+N" today delta, grouped; empty string when zero.
    var wordsTodayFormatted: String {
        wordsToday > 0 ? "+\(Self.grouped(wordsToday)) today" : ""
    }

    var wpmFormatted: String { wpm.map { "\($0)" } ?? "—" }
    var topAppFormatted: String { (topApp?.isEmpty == false ? topApp! : "—") }
    var streakFormatted: String { streakDays == 1 ? "1 day" : "\(streakDays) days" }

    /// Human time-saved, e.g. "4d 1h", "2h 13m", "0m".
    var timeSavedFormatted: String { Self.humanDuration(minutes: timeSavedMinutes) }

    /// The level-bar caption, e.g. "654,401 words to Lv.9 (+17,121 today)".
    var levelCaption: String {
        var s = "\(Self.grouped(level.wordsToNext)) words to Lv.\(level.level + 1)"
        if wordsToday > 0 { s += " (+\(Self.grouped(wordsToday)) today)" }
        return s
    }

    /// The level title line, e.g. "Level 8: Singularity".
    var levelTitleLine: String { "Level \(level.level): \(level.title)" }

    // MARK: Computation

    static func make(from history: [PipelineHistoryItem],
                     now: Date = Date(),
                     calendar: Calendar = .current) -> ShareCardStats {
        guard !history.isEmpty else { return .zero }

        let total = history.reduce(0) { $0 + wordCount(of: $1) }

        // Today's words.
        let startOfToday = calendar.startOfDay(for: now)
        let today = history
            .filter { $0.timestamp >= startOfToday }
            .reduce(0) { $0 + wordCount(of: $1) }

        // WPM: total words over wall-clock span (earliest→latest), guarded.
        let timestamps = history.map(\.timestamp)
        var wpm: Int? = nil
        if history.count >= 2,
           let earliest = timestamps.min(),
           let latest = timestamps.max() {
            let minutes = latest.timeIntervalSince(earliest) / 60.0
            if minutes >= 1 {
                let v = Double(total) / minutes
                if v.isFinite, v > 0 { wpm = Int(v.rounded()) }
            }
        }

        // Top app: mode of non-empty contextAppName.
        var appCounts: [String: Int] = [:]
        for item in history {
            guard let app = item.contextAppName, !app.isEmpty else { continue }
            appCounts[app, default: 0] += 1
        }
        let topApp = appCounts.max {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        }?.key

        // Streak: consecutive days back from today with ≥1 entry.
        let activeDays: Set<Date> = Set(history.map { calendar.startOfDay(for: $0.timestamp) })
        var streak = 0
        var cursor = startOfToday
        while activeDays.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        // Time saved vs. typing.
        let savedMinutes = Int((Double(total) / ShareCardConstants.typingWPM).rounded())

        return ShareCardStats(
            totalWords: total,
            wordsToday: today,
            entries: history.count,
            wpm: wpm,
            topApp: topApp,
            streakDays: streak,
            timeSavedMinutes: savedMinutes,
            level: ShareCardLevel.compute(totalWords: total)
        )
    }

    /// The zeroed ticket shown for empty history.
    static let zero = ShareCardStats(
        totalWords: 0,
        wordsToday: 0,
        entries: 0,
        wpm: nil,
        topApp: nil,
        streakDays: 0,
        timeSavedMinutes: 0,
        level: ShareCardLevel.compute(totalWords: 0)
    )

    // MARK: - Static utilities (prefixed)

    /// Word count of a single item: prefer the post-processed transcript, fall
    /// back to the raw transcript when post-processing is empty.
    static func wordCount(of item: PipelineHistoryItem) -> Int {
        let text = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? item.rawTranscript
            : item.postProcessedTranscript
        return text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .count
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func humanDuration(minutes: Int) -> String {
        guard minutes > 0 else { return "0m" }
        let days = minutes / (60 * 24)
        let hours = (minutes % (60 * 24)) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }
}
