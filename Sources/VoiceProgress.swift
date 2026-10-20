//
//  VoiceProgress.swift
//  History-derived progression for SISO Voice.
//

import Foundation

enum VoiceHUDSkin: String, CaseIterable, Identifiable {
    case classic
    case gold
    case midnight

    static let preferenceKey = "siso.voice.hudSkin"

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Unlock thresholds use the existing level curve. Classic is available
    /// from the start; later skins require actual lifetime dictation history.
    var minimumLevel: Int {
        switch self {
        case .classic: 1
        case .gold: 3
        case .midnight: 5
        }
    }

    func isUnlocked(at level: Int) -> Bool { level >= minimumLevel }
}

struct VoiceAchievement: Identifiable {
    let id: String
    let title: String
    let detail: String

    var shareText: String { "SISO Voice achievement unlocked: \(title) — \(detail)" }
}

struct VoiceProgress {
    let stats: ShareCardStats
    let forgivingStreakDays: Int
    let graceDaysUsedThisWeek: Int
    /// One earned freeze for each seven active dictation days. This is a
    /// transparent activity reward; freezes are not inferred from missing
    /// days or from private account state.
    let earnedStreakFreezes: Int
    let streakFreezesUsed: Int
    /// WPM from recorded audio duration, when at least one valid duration is
    /// available. This is distinct from the wall-clock History WPM estimate.
    let recordedDurationWPM: Int?
    let bestDayWords: Int
    let bestDay: Date?
    let previousWeekWords: Int
    let previousWeekEntries: Int
    let nextMilestone: Int?
    let unlockedAchievements: [VoiceAchievement]
    let availableSkins: [VoiceHUDSkin]

    static let lifetimeMilestones = [100, 1_000, 10_000, 100_000, 1_000_000]

    static func make(from history: [PipelineHistoryItem], now: Date = Date(), calendar: Calendar = .current,
                     lifetimeWords: Int? = nil) -> VoiceProgress {
        let completed = history.filter { ShareCardStats.wordCount(of: $0) > 0 && !$0.debugStatus.hasPrefix("Reprocessed as ") }
        let retained = ShareCardStats.make(from: completed, now: now, calendar: calendar)
        let total = max(retained.totalWords, lifetimeWords ?? 0)
        let stats = ShareCardStats(totalWords: total, wordsToday: retained.wordsToday, entries: retained.entries,
            wpm: retained.wpm, topApp: retained.topApp, streakDays: retained.streakDays,
            timeSavedMinutes: Int(Double(total) / ShareCardConstants.typingWPM), level: ShareCardLevel.compute(totalWords: total))
        let activeDays = Set(completed.map { calendar.startOfDay(for: $0.timestamp) })
        let streak = forgivingStreak(activeDays: activeDays, now: now, calendar: calendar)
        let durationSamples = completed.compactMap { item -> (Int, Double)? in
            guard let duration = item.audioDurationSeconds, duration.isFinite, duration > 0 else { return nil }
            let words = ShareCardStats.wordCount(of: item)
            return words > 0 ? (words, duration) : nil
        }
        let recordedDurationWPM: Int? = {
            let words = durationSamples.reduce(0) { $0 + $1.0 }
            let seconds = durationSamples.reduce(0.0) { $0 + $1.1 }
            guard seconds > 0, words > 0 else { return nil }
            return Int((Double(words) / (seconds / 60.0)).rounded())
        }()
        var wordsByDay: [Date: Int] = [:]
        for item in completed {
            let day = calendar.startOfDay(for: item.timestamp)
            wordsByDay[day, default: 0] += ShareCardStats.wordCount(of: item)
        }
        let best = wordsByDay.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }
        let thisMonday = monday(containing: calendar.startOfDay(for: now), calendar: calendar)
        let previousMonday = calendar.date(byAdding: .day, value: -7, to: thisMonday) ?? thisMonday
        let previousWeekItems = completed.filter { $0.timestamp >= previousMonday && $0.timestamp < thisMonday }
        let previousWeekWords = previousWeekItems.reduce(0) { $0 + ShareCardStats.wordCount(of: $1) }
        let earned = lifetimeMilestones.filter { stats.totalWords >= $0 }
        let achievements = earned.map { words in
            VoiceAchievement(id: "words-\(words)", title: "\(ShareCardStats.grouped(words)) words", detail: "Dictated \(ShareCardStats.grouped(words)) lifetime words.")
        }
        let skins = VoiceHUDSkin.allCases.filter { $0.isUnlocked(at: stats.level.level) }
        return VoiceProgress(
            stats: stats,
            forgivingStreakDays: streak.days,
            graceDaysUsedThisWeek: streak.graceDaysThisWeek,
            earnedStreakFreezes: streak.freezesAvailable,
            streakFreezesUsed: streak.freezesUsed,
            recordedDurationWPM: recordedDurationWPM,
            bestDayWords: best?.value ?? 0,
            bestDay: best?.key,
            previousWeekWords: previousWeekWords,
            previousWeekEntries: previousWeekItems.count,
            nextMilestone: lifetimeMilestones.first { stats.totalWords < $0 },
            unlockedAchievements: achievements,
            availableSkins: skins
        )
    }

    private static func monday(containing day: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: day) // Sunday = 1, Monday = 2
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
    }

    private static func forgivingStreak(activeDays: Set<Date>, now: Date, calendar: Calendar = .current) -> (days: Int, graceDaysThisWeek: Int, freezesAvailable: Int, freezesUsed: Int) {
        guard let oldest = activeDays.min() else { return (0, 0, 0, 0) }
        let today = calendar.startOfDay(for: now)
        // An absent current day is still in progress: do not spend grace or a
        // freeze until that day has ended. An active current day is included.
        let lastDay = activeDays.contains(today) ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        guard lastDay >= oldest else { return (0, 0, 0, 0) }
        var cursor = oldest
        var activeCount = 0
        var run = 0
        var freezesEarned = 0
        var freezesUsed = 0
        var graceWeeks: Set<Date> = []
        while cursor <= lastDay {
            if activeDays.contains(cursor) {
                activeCount += 1
                freezesEarned = activeCount / 7
                run += 1
            } else if run > 0 {
                let week = monday(containing: cursor, calendar: calendar)
                if !graceWeeks.contains(week) {
                    graceWeeks.insert(week)
                } else if freezesUsed < freezesEarned {
                    freezesUsed += 1
                } else {
                    run = 0
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let currentWeek = monday(containing: today, calendar: calendar)
        let graceUsedThisWeek = graceWeeks.contains(currentWeek) ? 1 : 0
        return (run, graceUsedThisWeek, max(0, freezesEarned - freezesUsed), freezesUsed)
    }
}

/// Counts new completed dictations beyond the retained History window. The
/// initial baseline is the history available when this version first runs.
enum VoiceProgressLedger {
    static let wordsKey = "siso.voice.lifetimeWords"

    static func record(words: Int, baseline: Int, defaults: UserDefaults = .standard) {
        guard words > 0 else { return }
        let previous = defaults.object(forKey: wordsKey) as? Int ?? baseline
        defaults.set(max(previous, baseline) + words, forKey: wordsKey)
    }
}
