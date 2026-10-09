//
//  AccountActivityView.swift
//  SISO Voice (freeflow fork) — Instructions & Account page (§3.5)
//
//  The "Account" tab body: a stat-pill row + dictation-activity heatmap card +
//  spine-sync status card. Owns day-bucketing/streak math and the outbox /
//  sync-state file reads. NO billing / subscription section — this is our own
//  internal tool, not Aqua.
//

import SwiftUI

// MARK: - AccountActivityView

struct AccountActivityView: View {
    let history: [PipelineHistoryItem]

    /// Trailing window of days shown in the heatmap (7 rows × 17 weeks ≈ 119).
    private let trailingDays = 7 * 17

    @State private var sync: SpineSyncSnapshot = .empty

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
            statPills
            heatmapCard
            syncCard
        }
        .onAppear { sync = SpineSyncReader.read() }
    }

    // MARK: Stat pills (total / this week / streak)

    private var statPills: some View {
        HStack(spacing: SISOTheme.Metrics.s3) {
            SISOStatPill(value: grouped(history.count), label: "Total dictations")
            SISOStatPill(value: grouped(thisWeekCount), label: "This week")
            SISOStatPill(value: grouped(dayStreak),
                         label: dayStreak == 1 ? "Day streak" : "Day streak")
        }
    }

    // MARK: Heatmap card

    private var heatmapCard: some View {
        SISOCard {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                SISOSectionLabel("Dictation activity")
                if history.isEmpty {
                    SISOEmptyState(icon: "calendar",
                                   title: "No activity yet",
                                   message: "Your dictation streak appears here once you start.")
                        .padding(.vertical, SISOTheme.Metrics.s4)
                } else {
                    ContributionHeatmap(days: bucketedDays)
                }
            }
        }
    }

    // MARK: Sync card

    private var syncCard: some View {
        SISOCard {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                SISOSectionLabel("Spine sync")
                if sync.hasRealSyncState {
                    syncRow(title: "Synced to spine",
                            value: "\(grouped(sync.syncedCount ?? 0)) utterances",
                            icon: "checkmark.icloud")
                    SISOHairline()
                    syncRow(title: "Pending in outbox",
                            value: grouped(sync.pendingCount ?? 0),
                            icon: "tray.and.arrow.up")
                    if let flush = lastFlushRelative {
                        Text("Last flush · \(flush)")
                            .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                    }
                } else {
                    // Truthful proxy: no sync-state file yet → report outbox total,
                    // label synced unknown rather than fabricate a number.
                    syncRow(title: "Queued in outbox",
                            value: "\(grouped(sync.outboxCount)) utterances",
                            icon: "tray.and.arrow.up")
                    SISOHairline()
                    syncRow(title: "Synced to spine", value: "—", icon: "checkmark.icloud")
                    Text("Real synced count needs voice-sync.py to write ~/.siso/voice-sync-state.json (a separate task).")
                        .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func syncRow(title: String, value: String, icon: String) -> some View {
        HStack(spacing: SISOTheme.Metrics.s3) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(SISOTheme.Colors.textSecondary)
                .frame(width: 18)
            Text(title)
                .sisoText(.label, color: SISOTheme.Colors.textPrimary)
            Spacer(minLength: SISOTheme.Metrics.s3)
            Text(value)
                .font(SISOTheme.mono(size: 13, weight: .medium))
                .foregroundColor(SISOTheme.Colors.textSecondary)
                .padding(.horizontal, SISOTheme.Metrics.s3)
                .padding(.vertical, 3)
                .background(Capsule().fill(SISOTheme.Colors.canvasInset))
        }
    }

    // MARK: - Derived data

    /// `history` bucketed by `startOfDay` over the trailing window, oldest first.
    private var bucketedDays: [(day: Date, count: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        var counts: [Date: Int] = [:]
        for item in history {
            let day = cal.startOfDay(for: item.timestamp)
            counts[day, default: 0] += 1
        }

        return (0..<trailingDays).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, counts[day] ?? 0)
        }
    }

    /// Dictations within the current trailing 7-day window (today inclusive).
    private var thisWeekCount: Int {
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))
        else { return 0 }
        return history.filter { $0.timestamp >= cutoff }.count
    }

    /// Consecutive days (ending today or yesterday) with ≥1 dictation.
    private var dayStreak: Int {
        let cal = Calendar.current
        let activeDays = Set(history.map { cal.startOfDay(for: $0.timestamp) })
        guard !activeDays.isEmpty else { return 0 }

        var streak = 0
        var cursor = cal.startOfDay(for: Date())
        // Allow the streak to count even if today has no dictation yet.
        if !activeDays.contains(cursor) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor),
                  activeDays.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        while activeDays.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    private var lastFlushRelative: String? {
        guard let iso = sync.lastFlushISO,
              let date = Self.iso.date(from: iso) else { return nil }
        return Self.relative.localizedString(for: date, relativeTo: Date())
    }

    private func grouped(_ n: Int) -> String {
        Self.number.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}

#if DEBUG
#Preview("Account Activity") {
    let cal = Calendar.current
    let now = Date()
    let sample: [PipelineHistoryItem] = (0..<60).map { i in
        PipelineHistoryItem(
            timestamp: cal.date(byAdding: .day, value: -(i / 2), to: now)!,
            rawTranscript: "sample \(i)",
            postProcessedTranscript: "sample \(i)",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "",
            postProcessingStatus: "",
            debugStatus: "",
            customVocabulary: ""
        )
    }
    return ScrollView {
        AccountActivityView(history: sample)
            .padding(SISOTheme.Metrics.s6)
    }
    .frame(width: 620, height: 640)
    .background(SISOTheme.Colors.canvas)
}
#endif
