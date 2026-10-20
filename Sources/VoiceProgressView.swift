//
//  VoiceProgressView.swift
//  Progress panel for the Stats destination.
//

import SwiftUI

struct VoiceProgressView: View {
    let history: [PipelineHistoryItem]

    @AppStorage(VoiceHUDSkin.preferenceKey) private var storedSkin = VoiceHUDSkin.classic.rawValue
    @AppStorage(VoiceProgressLedger.wordsKey) private var lifetimeWords = 0
    @State private var copiedAchievement = false

    private var progress: VoiceProgress { VoiceProgress.make(from: history, lifetimeWords: lifetimeWords) }
    /// Read this same preference in the HUD renderer to apply the chosen skin.
    static let hudSkinPreferenceKey = VoiceHUDSkin.preferenceKey

    private var selectedSkin: VoiceHUDSkin {
        let requested = VoiceHUDSkin(rawValue: storedSkin) ?? .classic
        return progress.availableSkins.contains(requested) ? requested : .classic
    }

    var body: some View {
        SISOCard {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                SISOSectionLabel("Progress")
                Text("Lifetime progress starts with retained History and keeps counting new dictations.")
                    .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                HStack {
                    VStack(alignment: .leading, spacing: SISOTheme.Metrics.s1) {
                        Text("Level \(progress.stats.level.level) · \(progress.stats.level.title)")
                            .sisoText(.cardTitle, color: SISOTheme.Colors.textPrimary)
                        Text(progress.stats.levelCaption)
                            .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                    }
                    Spacer()
                    Text("\(Int(progress.stats.level.progress * 100))%")
                        .sisoText(.label, color: SISOTheme.Colors.textSecondary)
                }
                ProgressView(value: progress.stats.level.progress)
                    .tint(SISOTheme.Colors.brandBlueLight)

                HStack(spacing: SISOTheme.Metrics.s2) {
                    Image(systemName: "flame.fill").foregroundColor(SISOTheme.Colors.gold)
                    Text("\(progress.forgivingStreakDays)-day streak")
                        .sisoText(.label, color: SISOTheme.Colors.textPrimary)
                    Text("· one grace day per week (\(progress.graceDaysUsedThisWeek) used)")
                        .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                }
                Text("Streak freezes · \(progress.earnedStreakFreezes) available · \(progress.streakFreezesUsed) used (earn 1 per 7 active days)")
                    .sisoText(.caption, color: SISOTheme.Colors.textSecondary)

                HStack(spacing: SISOTheme.Metrics.s2) {
                    Text("Speed")
                        .sisoText(.label, color: SISOTheme.Colors.textSecondary)
                    Text(progress.recordedDurationWPM.map { "\($0) WPM" } ?? "—")
                        .sisoText(.label, color: SISOTheme.Colors.textPrimary)
                    Text("from recorded audio")
                        .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                }
                Text("Personal best · \(ShareCardStats.grouped(progress.bestDayWords)) words in one day")
                    .sisoText(.caption, color: SISOTheme.Colors.textSecondary)

                Text("Previous Monday–Monday · \(ShareCardStats.grouped(progress.previousWeekWords)) words · \(progress.previousWeekEntries) entries")
                    .sisoText(.caption, color: SISOTheme.Colors.textSecondary)
                Text("Recap uses retained History only; older activity may be outside this window.")
                    .sisoText(.caption, color: SISOTheme.Colors.textMuted)

                if let milestone = progress.nextMilestone {
                    Text("Next milestone · \(ShareCardStats.grouped(milestone)) lifetime words")
                        .sisoText(.caption, color: SISOTheme.Colors.textSecondary)
                } else if let last = VoiceProgress.lifetimeMilestones.last {
                    Text("All lifetime word milestones reached · \(ShareCardStats.grouped(last))+")
                        .sisoText(.caption, color: SISOTheme.Colors.textSecondary)
                }

                HStack(spacing: SISOTheme.Metrics.s2) {
                    Text("HUD skin").sisoText(.label, color: SISOTheme.Colors.textSecondary)
                    Picker("HUD skin", selection: skinBinding) {
                        ForEach(VoiceHUDSkin.allCases) { skin in
                            Text(skin.title + (progress.availableSkins.contains(skin) ? "" : " · Level \(skin.minimumLevel)"))
                                .tag(skin.rawValue)
                                .disabled(!progress.availableSkins.contains(skin))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }

                if let achievement = progress.unlockedAchievements.last {
                    HStack {
                        Text("Achievement · \(achievement.title)")
                            .sisoText(.caption, color: SISOTheme.Colors.textSecondary)
                        Spacer()
                        SISOButton(copiedAchievement ? "Copied" : "Share achievement", variant: .secondary) {
                            ShareCardExport.copyAchievement(achievement)
                            copiedAchievement = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedAchievement = false }
                        }
                    }
                } else {
                    Text("Your first shareable achievement unlocks at 100 lifetime words.")
                        .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                }
            }
        }
    }

    private var skinBinding: Binding<String> {
        Binding(
            get: { selectedSkin.rawValue },
            set: { value in
                guard let skin = VoiceHUDSkin(rawValue: value), progress.availableSkins.contains(skin) else { return }
                storedSkin = skin.rawValue
            }
        )
    }
}
