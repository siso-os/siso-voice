//
//  MainWindowView.swift
//  SISO Voice (freeflow fork)
//
//  An Aqua-Voice-style main window: a clean two-column layout — a left sidebar
//  nav over a content area. Pure SwiftUI + AppKit. Depends only on the SISOTheme
//  design system, the SISOOrb logo, and the PipelineHistoryStore / Item types.
//
//  Present via:
//      let host = NSHostingView(rootView: MainWindowView())
//      let window = NSWindow(contentRect: …, styleMask: [.titled, .closable,
//                            .miniaturizable, .resizable], …)
//      window.contentView = host
//
//  Every internal helper view is prefixed `MainWindow`/`SISO` so it cannot
//  collide with freeflow's existing types.
//
//  Target: Swift 6.1 / SwiftUI on macOS 13+.
//

import SwiftUI
import AppKit

// MARK: - Sidebar Sections

/// The five top-level destinations in the SISO Voice main window.
enum MainWindowSection: String, CaseIterable, Identifiable {
    case home
    case history
    case dictionary
    case stats
    case instructions
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:         return "Home"
        case .history:      return "History"
        case .dictionary:   return "Dictionary"
        case .stats:        return "Stats"
        case .instructions: return "Instructions"
        case .settings:     return "Settings"
        }
    }

    /// SF Symbol name for the nav icon.
    var systemImage: String {
        switch self {
        case .home:         return "house"
        case .history:      return "clock.arrow.circlepath"
        case .dictionary:   return "character.book.closed"
        case .stats:        return "chart.bar"
        case .instructions: return "text.alignleft"
        case .settings:     return "gearshape"
        }
    }
}

// MARK: - Root

/// The two-column main window: sidebar nav + content area.
struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: MainWindowSection = .home

    private let store = PipelineHistoryStore()

    var body: some View {
        HStack(spacing: 0) {
            MainWindowSidebar(selection: $selection)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SISOTheme.Colors.canvas)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(SISOTheme.Colors.canvas)
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private var content: some View {
        // UI v2: new page views (Sources/*, Sources/History/*, Sources/Shared/*).
        // Home & Settings both render the combined HomeSettingsView (Settings is a
        // section within it). Old MainWindow* placeholder views are superseded.
        switch selection {
        case .home:
            HomeSettingsView(history: appState.pipelineHistory, onRefresh: reload)
        case .history:
            HistoryView(
                history: appState.pipelineHistory,
                onRefresh: reload,
                retryingItemIDs: appState.retryingItemIDs,
                onRetry: { item in appState.retryTranscription(item: item) }
            )
        case .dictionary:
            DictionaryReplacementsView(history: appState.pipelineHistory)
        case .stats:
            StatsShareCardView(history: appState.pipelineHistory)
        case .instructions:
            MainWindowInstructionsAccountView(history: appState.pipelineHistory)
        case .settings:
            HomeSettingsView(history: appState.pipelineHistory, onRefresh: reload)
        }
    }

    private func reload() {
        appState.pipelineHistory = store.loadAllHistory(fetchLimit: 1_000)
    }
}

// MARK: - Sidebar

private struct MainWindowSidebar: View {
    @Binding var selection: MainWindowSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Wordmark
            HStack(spacing: SISOTheme.Metrics.s2) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SISOTheme.Colors.textSecondary)
                Text("SISO Voice")
                    .sisoText(.cardTitle)
            }
            .padding(.horizontal, SISOTheme.Metrics.s4)
            .padding(.top, SISOTheme.Metrics.s6)
            .padding(.bottom, SISOTheme.Metrics.s4)

            // Nav items
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s1) {
                ForEach(MainWindowSection.allCases) { section in
                    MainWindowNavItem(
                        section: section,
                        isSelected: selection == section
                    ) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, SISOTheme.Metrics.s2)

            Spacer(minLength: 0)
        }
        .frame(width: SISOTheme.Metrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SISOTheme.Colors.canvasInset)
        .overlay(alignment: .trailing) {
            SISOHairline(axis: .vertical)
        }
    }
}

private struct MainWindowNavItem: View {
    let section: MainWindowSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SISOTheme.Metrics.s2) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, alignment: .center)
                Text(section.title)
                    .sisoText(.label, color: foreground)
                Spacer(minLength: 0)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, SISOTheme.Metrics.s3)
            .padding(.vertical, SISOTheme.Metrics.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        isSelected ? SISOTheme.Colors.textPrimary : SISOTheme.Colors.textMuted
    }

    private var background: Color {
        if isSelected {
            return SISOTheme.Colors.cardWhite
        } else if isHovering {
            return SISOTheme.Colors.canvas.opacity(0.6)
        } else {
            return Color.clear
        }
    }
}

// MARK: - Home

private struct MainWindowHomeView: View {
    let history: [PipelineHistoryItem]
    let onRefresh: () -> Void

    private var stats: MainWindowStats { MainWindowStats(history: history) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {
                MainWindowHeader(title: MainWindowGreeting.current, onRefresh: onRefresh)

                // Stat pills
                HStack(spacing: SISOTheme.Metrics.s3) {
                    MainWindowStatPill(value: stats.totalWordsFormatted, label: "words dictated")
                    MainWindowStatPill(value: stats.totalEntriesFormatted, label: "entries")
                    MainWindowStatPill(value: stats.avgWordsFormatted, label: "avg words / entry")
                }

                // Recent
                VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                    Text("Recent")
                        .sisoText(.cardTitle)
                    MainWindowRecentCard(items: Array(history.prefix(8)))
                }
            }
            .padding(SISOTheme.Metrics.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MainWindowStatPill: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s1) {
            Text(value)
                .font(SISOTheme.mono(size: 22, weight: .medium))
                .foregroundColor(SISOTheme.Colors.textPrimary)
            Text(label)
                .sisoText(.caption, color: SISOTheme.Colors.textMuted)
        }
        .padding(.horizontal, SISOTheme.Metrics.s4)
        .padding(.vertical, SISOTheme.Metrics.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sisoCard(cornerRadius: SISOTheme.Metrics.cardRadius)
    }
}

private struct MainWindowRecentCard: View {
    let items: [PipelineHistoryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                MainWindowEmptyState(
                    icon: "text.bubble",
                    title: "Nothing yet",
                    message: "Your recent dictations will show up here."
                )
                .padding(SISOTheme.Metrics.s6)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    MainWindowTranscriptRow(item: item, showAppName: false, truncate: true)
                        .padding(.horizontal, SISOTheme.Metrics.s4)
                        .padding(.vertical, SISOTheme.Metrics.s3)
                    if index < items.count - 1 {
                        SISOHairline()
                            .padding(.horizontal, SISOTheme.Metrics.s4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sisoCard(cornerRadius: SISOTheme.Metrics.cardRadius)
    }
}

// MARK: - History

private struct MainWindowHistoryView: View {
    let history: [PipelineHistoryItem]
    let onRefresh: () -> Void

    @State private var query: String = ""

    private var filtered: [PipelineHistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history }
        let needle = trimmed.lowercased()
        return history.filter { item in
            MainWindowText.display(item).lowercased().contains(needle)
                || (item.contextAppName?.lowercased().contains(needle) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
            MainWindowHeader(title: "History", onRefresh: onRefresh)

            // Search box
            HStack(spacing: SISOTheme.Metrics.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SISOTheme.Colors.textMuted)
                TextField("Search everything you've said…", text: $query)
                    .textFieldStyle(.plain)
                    .sisoText(.body)
            }
            .padding(.horizontal, SISOTheme.Metrics.s3)
            .padding(.vertical, SISOTheme.Metrics.s2)
            .background(
                RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius, style: .continuous)
                    .fill(SISOTheme.Colors.cardWhite)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius, style: .continuous)
                    .stroke(SISOTheme.Colors.hairline, lineWidth: SISOTheme.Metrics.hairline)
            )

            // List
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if filtered.isEmpty {
                        MainWindowEmptyState(
                            icon: "clock.arrow.circlepath",
                            title: query.isEmpty ? "No history yet" : "No matches",
                            message: query.isEmpty
                                ? "Everything you dictate is saved here."
                                : "Try a different search."
                        )
                        .padding(SISOTheme.Metrics.s6)
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            MainWindowTranscriptRow(item: item, showAppName: true, truncate: false)
                                .padding(.horizontal, SISOTheme.Metrics.s4)
                                .padding(.vertical, SISOTheme.Metrics.s3)
                            if index < filtered.count - 1 {
                                SISOHairline()
                                    .padding(.horizontal, SISOTheme.Metrics.s4)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .sisoCard(cornerRadius: SISOTheme.Metrics.cardRadius)
            }
        }
        .padding(SISOTheme.Metrics.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Dictionary

private struct MainWindowDictionaryView: View {
    let history: [PipelineHistoryItem]

    /// Distinct, non-empty custom-vocabulary blobs seen across history.
    private var vocabularies: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in history {
            let vocab = item.customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !vocab.isEmpty, !seen.contains(vocab) else { continue }
            seen.insert(vocab)
            result.append(vocab)
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {
                MainWindowHeader(title: "Dictionary", onRefresh: nil)

                VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
                    Text("Custom vocabulary")
                        .sisoText(.cardTitle)

                    if vocabularies.isEmpty {
                        MainWindowEmptyState(
                            icon: "character.book.closed",
                            title: "No custom words yet",
                            message: "Add names, jargon, and acronyms so SISO Voice spells them right."
                        )
                    } else {
                        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                            ForEach(Array(vocabularies.enumerated()), id: \.offset) { _, vocab in
                                Text(vocab)
                                    .sisoText(.body, color: SISOTheme.Colors.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(SISOTheme.Metrics.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sisoCard(cornerRadius: SISOTheme.Metrics.cardRadius)
            }
            .padding(SISOTheme.Metrics.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Stats

private struct MainWindowStatsView: View {
    let history: [PipelineHistoryItem]

    private var stats: MainWindowStats { MainWindowStats(history: history) }

    private let columns = [
        GridItem(.flexible(), spacing: SISOTheme.Metrics.s3),
        GridItem(.flexible(), spacing: SISOTheme.Metrics.s3)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {
                MainWindowHeader(title: "Stats", onRefresh: nil)

                LazyVGrid(columns: columns, alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                    MainWindowStatCard(value: stats.totalWordsFormatted, label: "Total words")
                    MainWindowStatCard(value: stats.totalEntriesFormatted, label: "Entries")
                    if let wpm = stats.wordsPerMinuteFormatted {
                        MainWindowStatCard(value: wpm, label: "Words / minute")
                    }
                    if let app = stats.mostUsedApp {
                        MainWindowStatCard(value: app, label: "Most-used app", mono: false)
                    }
                }
            }
            .padding(SISOTheme.Metrics.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MainWindowStatCard: View {
    let value: String
    let label: String
    var mono: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s2) {
            Text(value)
                .font(mono
                      ? SISOTheme.mono(size: 26, weight: .medium)
                      : SISOTheme.font(size: 22, weight: .medium))
                .foregroundColor(SISOTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .sisoText(.caption, color: SISOTheme.Colors.textMuted)
        }
        .padding(SISOTheme.Metrics.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sisoCard(cornerRadius: SISOTheme.Metrics.cardRadius)
    }
}

// MARK: - Settings

private struct MainWindowSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {
                MainWindowHeader(title: "Settings", onRefresh: nil)

                VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
                    Text("Preferences")
                        .sisoText(.cardTitle)
                    Text("Hotkeys, transcription model, post-processing, and more live in the full settings window.")
                        .sisoText(.body, color: SISOTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        NotificationCenter.default.post(
                            name: Notification.Name("showSettings"),
                            object: nil
                        )
                    } label: {
                        Text("Open Settings…")
                            .sisoText(.label, color: .white)
                            .padding(.horizontal, SISOTheme.Metrics.s4)
                            .padding(.vertical, SISOTheme.Metrics.s2)
                            .background(
                                RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius, style: .continuous)
                                    .fill(SISOTheme.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(SISOTheme.Metrics.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sisoCard(cornerRadius: SISOTheme.Metrics.cardRadius)
            }
            .padding(SISOTheme.Metrics.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared Components

struct MainWindowHeader: View {
    let title: String
    let onRefresh: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .sisoText(.greeting)
            Spacer(minLength: SISOTheme.Metrics.s4)
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SISOTheme.Colors.textMuted)
                        .padding(SISOTheme.Metrics.s2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
    }
}

private struct MainWindowTranscriptRow: View {
    let item: PipelineHistoryItem
    let showAppName: Bool
    let truncate: Bool

    @State private var didCopy = false

    private var text: String { MainWindowText.display(item) }

    var body: some View {
        HStack(alignment: .top, spacing: SISOTheme.Metrics.s3) {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s1) {
                HStack(spacing: SISOTheme.Metrics.s2) {
                    Text(MainWindowText.relative(item.timestamp))
                        .font(SISOTheme.mono(size: 11))
                        .foregroundColor(SISOTheme.Colors.textMuted)
                    if showAppName, let app = item.contextAppName, !app.isEmpty {
                        Text("·")
                            .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                        Text(app)
                            .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                    }
                }
                Text(text)
                    .sisoText(.body, color: SISOTheme.Colors.textPrimary)
                    .lineLimit(truncate ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: !truncate)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: copy) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(didCopy ? SISOTheme.Colors.accent : SISOTheme.Colors.textMuted)
                    .padding(SISOTheme.Metrics.s2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }
}

struct MainWindowEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: SISOTheme.Metrics.s2) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundColor(SISOTheme.Colors.textMuted)
            Text(title)
                .sisoText(.cardTitle, color: SISOTheme.Colors.textSecondary)
            Text(message)
                .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Stats Model

private struct MainWindowStats {
    let history: [PipelineHistoryItem]

    private var wordCounts: [Int] {
        history.map { MainWindowText.wordCount(MainWindowText.display($0)) }
    }

    var totalEntries: Int { history.count }
    var totalWords: Int { wordCounts.reduce(0, +) }
    var avgWords: Int { totalEntries == 0 ? 0 : Int((Double(totalWords) / Double(totalEntries)).rounded()) }

    var totalWordsFormatted: String { MainWindowText.grouped(totalWords) }
    var totalEntriesFormatted: String { MainWindowText.grouped(totalEntries) }
    var avgWordsFormatted: String { MainWindowText.grouped(avgWords) }

    /// Words-per-minute estimate across the spanned wall-clock window, only when
    /// there are at least two entries spanning a non-trivial duration.
    var wordsPerMinuteFormatted: String? {
        guard history.count >= 2 else { return nil }
        let timestamps = history.map(\.timestamp)
        guard let earliest = timestamps.min(), let latest = timestamps.max() else { return nil }
        let minutes = latest.timeIntervalSince(earliest) / 60.0
        guard minutes >= 1.0 else { return nil }
        let wpm = Double(totalWords) / minutes
        guard wpm.isFinite, wpm > 0 else { return nil }
        return MainWindowText.grouped(Int(wpm.rounded()))
    }

    /// The most frequently captured app name, if any.
    var mostUsedApp: String? {
        var counts: [String: Int] = [:]
        for item in history {
            guard let app = item.contextAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !app.isEmpty else { continue }
            counts[app, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}

// MARK: - Greeting

private enum MainWindowGreeting {
    /// "Good morning" / "Good afternoon" / "Good evening" from the local hour.
    static var current: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<18: return "Good afternoon"
        default:      return "Good evening"
        }
    }
}

// MARK: - Text Helpers

private enum MainWindowText {
    /// Prefer the post-processed transcript; fall back to the raw one.
    static func display(_ item: PipelineHistoryItem) -> String {
        let processed = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !processed.isEmpty { return item.postProcessedTranscript }
        return item.rawTranscript
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Main Window") {
    MainWindowView()
        .environmentObject(AppState())
        .frame(width: 960, height: 640)
}
#endif
