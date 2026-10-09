//
//  HomeSettingsView.swift
//  SISO Voice (freeflow fork) — UI v2
//
//  The Home / Settings page (spec §3.1 `home`): greeting + stat pills + four
//  settings groups (Microphone, Transcription, Keybindings, System). Reads/
//  writes prefs directly on `AppState` `@Published` properties — each persists
//  via its own `didSet` — and renders the hotkey editor (KeycapEditor.swift),
//  which is the hotkey-revert-bug fix.
//
//  Option lists for the model/language/streaming selects are OWNED by this page
//  (AppState stores raw strings, no enum), per spec.
//
//  Pure SwiftUI, macOS 13+.
//

import SwiftUI

struct HomeSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("edge_dock_enabled") private var edgeDockEnabled: Bool = true
    @State private var stats: HomeStats

    /// Dictation history, used only to compute the read-only stat pills.
    /// MainWindowView already loads this and passes it down.
    let history: [PipelineHistoryItem]

    /// Optional refresh handler forwarded to the shared header.
    let onRefresh: (() -> Void)?

    /// - Parameters:
    ///   - history: pipeline history for the stat pills (read-only).
    ///   - onRefresh: optional header refresh action.
    init(history: [PipelineHistoryItem], onRefresh: (() -> Void)? = nil) {
        self.history = history
        self.onRefresh = onRefresh
        _stats = State(initialValue: HomeStats(history: history))
    }

    // MARK: Page-owned option lists

    /// Curated transcription model choices. AppState stores a raw string; the
    /// current value is always shown even if it is not in this list.
    static let transcriptionModelOptions: [(value: String, label: String)] = [
        ("whisper-large-v3", "Whisper Large v3"),
        ("whisper-large-v3-turbo", "Whisper Large v3 Turbo"),
        ("distil-whisper-large-v3-en", "Distil-Whisper Large v3 (EN)"),
        ("gpt-4o-transcribe", "GPT-4o Transcribe"),
        ("gpt-4o-mini-transcribe", "GPT-4o Mini Transcribe")
    ]

    /// Streaming (realtime) transcription model choices, shown only when
    /// streaming is enabled.
    static let streamingModelOptions: [(value: String, label: String)] = [
        ("", "Provider default"),
        ("gpt-4o-transcribe", "GPT-4o Transcribe"),
        ("gpt-4o-mini-transcribe", "GPT-4o Mini Transcribe")
    ]

    /// Language choices mirror AppState's canonical list ("" / "auto" both map
    /// to Auto-detect).
    static var languageOptions: [(value: String, label: String)] {
        AppState.transcriptionLanguageOptions.map { (value: $0.code, label: $0.name) }
    }

    /// Words-per-minute used for the "time saved" estimate.
    private static let typingWordsPerMinute = 40.0

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {
                MainWindowHeader(title: HomeGreeting.current, onRefresh: onRefresh)

                statPills

                microphoneGroup
                transcriptionGroup
                keybindingsGroup
                systemGroup
            }
            .padding(SISOTheme.Metrics.s6)
        }
        .background(SISOTheme.Colors.canvas)
        .onReceive(appState.$pipelineHistory) { history in
            stats = HomeStats(history: history)
        }
    }

    // MARK: Stat pills

    private var statPills: some View {
        HStack(spacing: SISOTheme.Metrics.s3) {
            SISOStatPill(
                value: stats.totalWordsFormatted,
                label: "words dictated",
                delta: stats.wordsTodayDelta
            )
            SISOStatPill(
                value: stats.avgWordsFormatted,
                label: "avg words / entry"
            )
            SISOStatPill(
                value: stats.timeSavedFormatted(wpm: Self.typingWordsPerMinute),
                label: "≈ time saved"
            )
        }
    }

    // MARK: Microphone

    private var microphoneGroup: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
            SISOSectionLabel("Microphone")
            SISOCard(padding: 0) {
                SISORow(icon: "mic.fill",
                        label: "Input device",
                        sublabel: "Microphone used for dictation") {
                    SISOSelect(
                        selection: $appState.selectedMicrophoneID,
                        options: microphoneOptions
                    )
                    .frame(maxWidth: 220)
                }
            }
        }
    }

    private var microphoneOptions: [(value: String, label: String)] {
        var options: [(value: String, label: String)] = [("default", "System Default")]
        options += appState.availableMicrophones.map { (value: $0.id, label: $0.name) }
        return options
    }

    // MARK: Transcription

    private var transcriptionGroup: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
            SISOSectionLabel("Transcription")
            SISOCard(padding: 0) {
                VStack(spacing: 0) {
                    SISORow(icon: "waveform",
                            label: "Model",
                            sublabel: "Speech-to-text model") {
                        SISOSelect(
                            selection: $appState.transcriptionModel,
                            options: modelOptionsIncludingCurrent
                        )
                        .frame(maxWidth: 240)
                    }

                    HomeHairline()

                    SISORow(icon: "globe",
                            label: "Language",
                            sublabel: "Auto-detect works for most users") {
                        SISOSelect(
                            selection: $appState.transcriptionLanguage,
                            options: Self.languageOptions
                        )
                        .frame(maxWidth: 200)
                    }

                    HomeHairline()

                    SISOToggleRow(icon: "dot.radiowaves.left.and.right",
                                  label: "Realtime streaming",
                                  sublabel: "Stream partial transcripts as you speak",
                                  isOn: $appState.realtimeStreamingEnabled)

                    if appState.realtimeStreamingEnabled {
                        HomeHairline()
                        SISORow(icon: "bolt.fill",
                                label: "Streaming model",
                                sublabel: "Model used while streaming") {
                            SISOSelect(
                                selection: $appState.realtimeStreamingModel,
                                options: streamingModelOptionsIncludingCurrent
                            )
                            .frame(maxWidth: 240)
                        }
                    }
                }
            }
        }
    }

    /// Ensures the currently-stored model value is always selectable even if it
    /// is not one of the curated options.
    private var modelOptionsIncludingCurrent: [(value: String, label: String)] {
        Self.optionsIncluding(appState.transcriptionModel, in: Self.transcriptionModelOptions)
    }

    private var streamingModelOptionsIncludingCurrent: [(value: String, label: String)] {
        Self.optionsIncluding(appState.realtimeStreamingModel, in: Self.streamingModelOptions)
    }

    private static func optionsIncluding(
        _ current: String,
        in options: [(value: String, label: String)]
    ) -> [(value: String, label: String)] {
        if options.contains(where: { $0.value == current }) {
            return options
        }
        return options + [(value: current, label: current)]
    }

    // MARK: Keybindings

    private var keybindingsGroup: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
            SISOSectionLabel("Keybindings")
            SISOCard(padding: 0) {
                VStack(spacing: 0) {
                    HomeKeybindingRow(
                        icon: "mic.circle",
                        label: ShortcutRole.hold.title,
                        sublabel: "Hold while speaking",
                        binding: appState.holdShortcut,
                        savedBinding: appState.savedCustomShortcut(for: .hold),
                        commit: { appState.setShortcut($0, for: .hold) }
                    )

                    HomeHairline()

                    HomeKeybindingRow(
                        icon: "switch.2",
                        label: ShortcutRole.toggle.title,
                        sublabel: "Tap once to start, again to stop",
                        binding: appState.toggleShortcut,
                        savedBinding: appState.savedCustomShortcut(for: .toggle),
                        commit: { appState.setShortcut($0, for: .toggle) }
                    )

                    HomeHairline()

                    HomeKeybindingRow(
                        icon: "doc.on.clipboard",
                        label: ShortcutRole.copyAgain.title,
                        sublabel: "Paste your last transcript again",
                        binding: appState.copyAgainShortcut,
                        savedBinding: appState.savedCustomShortcut(for: .copyAgain),
                        commit: { appState.setShortcut($0, for: .copyAgain) }
                    )
                }
            }
        }
    }

    // MARK: System

    private var systemGroup: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
            SISOSectionLabel("System")
            SISOCard(padding: 0) {
                VStack(spacing: 0) {
                    SISOToggleRow(icon: "power",
                                  label: "Launch at login",
                                  sublabel: "Start SISO Voice when you log in",
                                  isOn: $appState.launchAtLogin)
                    HomeHairline()
                    SISOToggleRow(icon: "doc.on.doc",
                                  label: "Preserve clipboard",
                                  sublabel: "Restore your clipboard after pasting",
                                  isOn: $appState.preserveClipboard)
                    HomeHairline()
                    SISOToggleRow(icon: "speaker.wave.2.fill",
                                  label: "Alert sounds",
                                  sublabel: "Play a sound on start and stop",
                                  isOn: $appState.alertSoundsEnabled)
                    HomeHairline()
                    SISOToggleRow(icon: "command",
                                  label: "Command mode",
                                  sublabel: "Recognize spoken voice commands",
                                  isOn: $appState.isCommandModeEnabled)
                    HomeHairline()
                    SISOToggleRow(icon: "sidebar.right",
                                  label: "Edge dock",
                                  sublabel: "Right-edge flyout for JARVIS and SISO Internal",
                                  isOn: $edgeDockEnabled)
                }
            }
        }
    }
}

// MARK: - HomeGreeting

/// Time-of-day greeting for the header. MainWindowView's `MainWindowGreeting`
/// is `private`, so this mirrors it locally.
private enum HomeGreeting {
    static var current: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<18: return "Good afternoon"
        default:      return "Good evening"
        }
    }
}

// MARK: - HomeHairline

/// A thin inset hairline separating rows inside a `SISOCard`. Named with the
/// Home prefix to avoid colliding with the shared `SISOHairline`.
private struct HomeHairline: View {
    var body: some View {
        Rectangle()
            .fill(SISOTheme.Colors.hairline)
            .frame(height: 1)
            .padding(.horizontal, SISOTheme.Metrics.s4)
    }
}

// MARK: - HomeStats

/// Read-only stat aggregates for the pills. Mirrors MainWindowView's private
/// `MainWindowStats` (which is not visible here) and adds a today-delta and a
/// time-saved estimate.
private struct HomeStats {
    let totalEntries: Int
    let totalWords: Int
    let todayWords: Int

    init(history: [PipelineHistoryItem]) {
        totalEntries = history.count
        let calendar = Calendar.current
        var words = 0
        var today = 0
        for item in history {
            let processed = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = processed.isEmpty ? item.rawTranscript : item.postProcessedTranscript
            let count = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
            words += count
            if calendar.isDateInToday(item.timestamp) { today += count }
        }
        totalWords = words
        todayWords = today
    }

    var avgWords: Int { totalEntries == 0 ? 0 : Int((Double(totalWords) / Double(totalEntries)).rounded()) }

    var totalWordsFormatted: String { Self.grouped(totalWords) }
    var avgWordsFormatted: String { Self.grouped(avgWords) }

    /// Words dictated today, as a "+N" delta badge (nil when zero).
    var wordsTodayDelta: String? {
        return todayWords > 0 ? "+\(Self.grouped(todayWords)) today" : nil
    }

    /// Estimated time saved vs. typing at `wpm`, formatted as a short duration.
    func timeSavedFormatted(wpm: Double) -> String {
        guard wpm > 0 else { return "0m" }
        let minutes = Double(totalWords) / wpm
        if minutes < 1 { return "0m" }
        let totalMinutes = Int(minutes.rounded())
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private static let groupingFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    static func grouped(_ value: Int) -> String {
        groupingFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

#if DEBUG
#Preview("Home / Settings") {
    HomeSettingsView(history: [], onRefresh: {})
        .environmentObject(AppState())
        .frame(width: 720, height: 720)
}
#endif
