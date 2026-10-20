import Foundation

enum VoiceFeatureTests {
    static func run() {
        let defaults = UserDefaults.standard
        let prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        let fixture: [String: Any] = [
            VoicePersonalization.mappingsStorageKey: #"[{"bundleIdentifier":"test.editor","mode":"code"}]"#,
            VoicePersonalization.snippetsStorageKey: #"[{"id":"00000000-0000-0000-0000-000000000001","trigger":"my link","content":"https://example.test/my-link"},{"id":"00000000-0000-0000-0000-000000000002","trigger":"example","content":"wrong"}]"#,
            "siso.replacements.rules": #"[{"from":"siso","to":"SISO","enabled":true,"caseSensitive":false},{"from":"SISO","to":"wrong","enabled":true,"caseSensitive":true}]"#,
            "siso.dictionary.terms": #"[{"text":"SISO"},{"text":"Shaan"}]"#
        ]
        defaults.setVolatileDomain(prior.merging(fixture) { _, new in new }, forName: UserDefaults.argumentDomain)
        let spoken = VoicePersonalization.resolve("Email mode: hello there", bundleIdentifier: "test.editor")
        precondition(spoken.mode == .email && spoken.text == "hello there")
        let unrecognized = VoicePersonalization.resolve("email model is fast", bundleIdentifier: "test.editor")
        precondition(unrecognized.mode == .code && unrecognized.text == "email model is fast")
        precondition(VoicePersonalization.resolve("verbatim mode keep um this", bundleIdentifier: nil).text == "keep um this")
        precondition(VoicePersonalization.resolve("normal speech", bundleIdentifier: nil).mode == .standard)
        precondition(VoicePersonalization.expandSnippets(in: "Use MY LINK, not my links.") == "Use https://example.test/my-link, not my links.")
        precondition(VoicePersonalization.applyReplacements(to: "siso sisodia siso_name") == "SISO sisodia siso_name")
        precondition(VoicePersonalization.customVocabulary() == ["SISO", "Shaan"])
        let correction = VoiceLearning.correction(original: "hello see so team", corrected: "hello SISO team")
        precondition(correction?.from == "see so" && correction?.to == "SISO")
        precondition(VoiceLearning.correction(original: "unchanged", corrected: "unchanged") == nil)
        precondition(VoiceLearning.correction(original: "one two three four five six seven", corrected: "replacement") == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        func item(daysAgo: Int, words: Int = 1, duration: Double? = nil) -> PipelineHistoryItem {
            let text = Array(repeating: "word", count: words).joined(separator: " ")
            return PipelineHistoryItem(timestamp: calendar.date(byAdding: .day, value: -daysAgo, to: today)!,
                rawTranscript: text, postProcessedTranscript: text, postProcessingPrompt: nil,
                contextSummary: "", contextScreenshotDataURL: nil, contextScreenshotStatus: "",
                postProcessingStatus: "", debugStatus: "", customVocabulary: "",
                audioDurationSeconds: duration)
        }
        let progress = VoiceProgress.make(from: [item(daysAgo: 0, words: 100, duration: 60), item(daysAgo: 2), item(daysAgo: 5)], now: today, calendar: calendar)
        precondition(progress.forgivingStreakDays == 1 && progress.graceDaysUsedThisWeek == 1)
        precondition(progress.recordedDurationWPM == 100)
        precondition(progress.bestDayWords == 100)
        precondition(progress.previousWeekWords == 1 && progress.previousWeekEntries == 1)
        precondition(progress.earnedStreakFreezes == 0 && progress.streakFreezesUsed == 0)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18))!
        precondition(VoiceProgress.make(from: [item(daysAgo: 5)], now: monday, calendar: calendar).previousWeekEntries == 1)
        precondition(VoiceProgress.make(from: [item(daysAgo: 5)], now: sunday, calendar: calendar).previousWeekEntries == 1)

        let earnedDays = (0..<7).map { offset in
            PipelineHistoryItem(timestamp: calendar.date(byAdding: .day, value: -offset - 4, to: today)!,
                rawTranscript: "word", postProcessedTranscript: "word", postProcessingPrompt: nil,
                contextSummary: "", contextScreenshotDataURL: nil, contextScreenshotStatus: "",
                postProcessingStatus: "", debugStatus: "", customVocabulary: "")
        }
        let protectedGap = VoiceProgress.make(from: earnedDays + [item(daysAgo: 2), item(daysAgo: 0)], now: today, calendar: calendar)
        precondition(protectedGap.streakFreezesUsed == 1 && protectedGap.earnedStreakFreezes == 0)
        precondition(progress.unlockedAchievements.count == 1)
        precondition(VoiceProgress.make(from: [], now: today).unlockedAchievements.isEmpty)
        let high = VoiceProgress.make(from: [item(daysAgo: 0)], lifetimeWords: 10_000)
        precondition(high.availableSkins.contains(.midnight) && high.stats.totalWords == 10_000)
        let suiteName = "siso.voice.feature-tests.\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suiteName)!
        defer { isolated.removePersistentDomain(forName: suiteName) }
        VoiceProgressLedger.record(words: 10, baseline: 100, defaults: isolated)
        VoiceProgressLedger.record(words: 5, baseline: 1, defaults: isolated)
        precondition(isolated.integer(forKey: VoiceProgressLedger.wordsKey) == 115)
        print("VoiceFeatureTests passed")
    }
}
