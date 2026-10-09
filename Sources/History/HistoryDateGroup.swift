//
//  HistoryDateGroup.swift
//  SISO Voice (freeflow fork) — History page
//
//  Pure helpers: bucket a flat `[PipelineHistoryItem]` into ordered, day-keyed
//  sections (newest first) with human labels ("Today" / "Yesterday" /
//  weekday / "MMM d" / "MMM d, yyyy"), plus the display-text + relative-time
//  helpers the History page needs. Namespaced `History*` to avoid colliding
//  with the file-private `MainWindowText` in MainWindowView.swift.
//
//  Foundation-only. macOS 13+.
//

import Foundation

/// One date-keyed group of history rows, newest day first.
struct HistoryGroup: Identifiable {
    let id: Date          // start-of-day key
    let label: String     // "Today" / "Yesterday" / weekday / date
    let items: [PipelineHistoryItem]
}

/// Pure bucketing + formatting helpers for the History page.
enum HistoryDateGroup {

    /// Bucket items by calendar day (newest day first; items within a day kept
    /// in the order given — callers pass newest-first).
    static func grouped(_ items: [PipelineHistoryItem],
                        calendar: Calendar = .current,
                        now: Date = Date()) -> [HistoryGroup] {
        guard !items.isEmpty else { return [] }

        // Preserve first-seen day order (input is newest-first) so groups stay
        // newest-first without an extra sort.
        var order: [Date] = []
        var buckets: [Date: [PipelineHistoryItem]] = [:]
        for item in items {
            let key = calendar.startOfDay(for: item.timestamp)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(item)
        }

        return order.map { key in
            HistoryGroup(id: key,
                         label: label(for: key, calendar: calendar, now: now),
                         items: buckets[key] ?? [])
        }
    }

    /// Human label for a start-of-day date relative to `now`.
    static func label(for day: Date,
                      calendar: Calendar = .current,
                      now: Date = Date()) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }

        let today = calendar.startOfDay(for: now)
        if let daysAgo = calendar.dateComponents([.day], from: day, to: today).day,
           daysAgo > 1, daysAgo < 7 {
            return weekdayFormatter.string(from: day)        // e.g. "Tuesday"
        }

        let sameYear = calendar.component(.year, from: day)
            == calendar.component(.year, from: now)
        return (sameYear ? monthDayFormatter : monthDayYearFormatter).string(from: day)
    }

    // MARK: Formatters

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let monthDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}

/// Text helpers local to the History page (the analogous `MainWindowText` is
/// file-private and unreachable from here).
enum HistoryText {

    /// Prefer the post-processed transcript; fall back to the raw one.
    static func display(_ item: PipelineHistoryItem) -> String {
        let processed = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !processed.isEmpty { return item.postProcessedTranscript }
        let raw = item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return item.rawTranscript }
        if item.audioFileName != nil { return "Transcribing… / Pending" }
        return ""
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Abbreviated relative time, e.g. "3m ago".
    static func relative(_ date: Date, relativeTo: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: relativeTo)
    }
}
