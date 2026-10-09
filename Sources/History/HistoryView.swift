//
//  HistoryView.swift
//  SISO Voice (freeflow fork) — History page (UI v2 §3.3)
//
//  Searchable, infinite-scroll transcript log: dense bare rows separated by
//  hairlines, grouped under sticky-ish date headers (newest first), with a
//  debounced search field + app-filter pills. Each row offers copy + re-use
//  (NotificationCenter "sisoReuseTranscript"). Empty / no-results states via
//  the shared empty state.
//
//  Consumes `history: [PipelineHistoryItem]` plus optional retry hooks supplied
//  by the caller. Shared components + SISOTheme only.
//
//  macOS 13+ / Swift 6.1.
//

import SwiftUI

struct HistoryView: View {
    let history: [PipelineHistoryItem]
    var onRefresh: (() -> Void)?
    var retryingItemIDs: Set<UUID>
    var onRetry: ((PipelineHistoryItem) -> Void)?

    init(
        history: [PipelineHistoryItem],
        onRefresh: (() -> Void)? = nil,
        retryingItemIDs: Set<UUID> = [],
        onRetry: ((PipelineHistoryItem) -> Void)? = nil
    ) {
        self.history = history
        self.onRefresh = onRefresh
        self.retryingItemIDs = retryingItemIDs
        self.onRetry = onRetry
    }

    // Search: `query` is live (drives the field + clear button); `committedQuery`
    // is the debounced value that actually filters.
    @State private var query: String = ""
    @State private var committedQuery: String = ""
    @State private var appFilters: Set<String> = []
    @State private var visibleCount: Int = HistoryView.pageSize
    @State private var selectedID: UUID?

    @FocusState private var searchFocused: Bool

    private static let pageSize = 50

    // MARK: Derived

    /// Newest-first, then app-filtered, then text-filtered.
    private var filtered: [PipelineHistoryItem] {
        var rows = history.sorted { $0.timestamp > $1.timestamp }

        if !appFilters.isEmpty {
            rows = rows.filter { item in
                guard let app = item.contextAppName else { return false }
                return appFilters.contains(app)
            }
        }

        let trimmed = committedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let needle = trimmed.lowercased()
            rows = rows.filter { item in
                HistoryText.display(item).lowercased().contains(needle)
                    || (item.contextAppName?.lowercased().contains(needle) ?? false)
            }
        }
        return rows
    }

    /// The currently revealed window (infinite-scroll head).
    private var visible: [PipelineHistoryItem] {
        Array(filtered.prefix(visibleCount))
    }

    private var groups: [HistoryGroup] {
        HistoryDateGroup.grouped(visible)
    }

    private var topApps: [String] { HistoryFilterBar.topApps(history) }

    private var hasMore: Bool { filtered.count > visibleCount }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
            MainWindowHeader(title: "History", onRefresh: onRefresh)

            HistorySearchField(text: $query,
                               debouncedText: $committedQuery,
                               focus: $searchFocused)

            HistoryFilterBar(apps: topApps, selected: $appFilters)

            content
        }
        .padding(SISOTheme.Metrics.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // ⌘F focuses search.
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        )
        // Reset the reveal window whenever the result set changes.
        .onChange(of: committedQuery) { _ in resetWindow() }
        .onChange(of: appFilters) { _ in resetWindow() }
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    let now = Date()
                    ForEach(groups) { group in
                        Section {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                                MainWindowHistoryRow(item: item,
                                                     isSelected: selectedID == item.id,
                                                     now: now,
                                                     isRetrying: retryingItemIDs.contains(item.id),
                                                     onRetry: onRetry.map { retry in
                                                         { retry(item) }
                                                     })
                                    .onAppear { revealMoreIfNeeded(item) }
                                if idx < group.items.count - 1 {
                                    SISOHairline()
                                        .padding(.horizontal, SISOTheme.Metrics.s4)
                                }
                            }
                        } header: {
                            sectionHeader(group.label)
                        }
                    }

                    if hasMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(SISOTheme.Metrics.s4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Arrow / Return keyboard handling.
            .background(keyboardCommands)
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        HStack {
            SISOSectionLabel(label)
            Spacer()
        }
        .padding(.horizontal, SISOTheme.Metrics.s4)
        .padding(.vertical, SISOTheme.Metrics.s2)
        .background(SISOTheme.Colors.canvas.opacity(0.96))
    }

    private var emptyState: some View {
        SISOEmptyState(
            icon: committedQuery.isEmpty && appFilters.isEmpty
                ? "clock.arrow.circlepath" : "magnifyingglass",
            title: committedQuery.isEmpty && appFilters.isEmpty
                ? "No history yet" : "No matches",
            message: committedQuery.isEmpty && appFilters.isEmpty
                ? "Everything you dictate is saved here."
                : "Try a different search or clear the filters."
        )
        .padding(SISOTheme.Metrics.s6)
    }

    // MARK: Keyboard

    private var keyboardCommands: some View {
        ZStack {
            Button("") { moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { reuseSelected() }
                .keyboardShortcut(.return, modifiers: [])
            Button("") { copySelected() }
                .keyboardShortcut("c", modifiers: .command)
        }
        .opacity(0)
    }

    // MARK: Mutations

    private func resetWindow() {
        visibleCount = HistoryView.pageSize
        selectedID = nil
    }

    private func revealMoreIfNeeded(_ item: PipelineHistoryItem) {
        // Grow the window when the tail row appears.
        guard hasMore, item.id == visible.last?.id else { return }
        visibleCount += HistoryView.pageSize
    }

    private func moveSelection(by delta: Int) {
        let rows = visible
        guard !rows.isEmpty else { return }
        guard let current = selectedID,
              let idx = rows.firstIndex(where: { $0.id == current }) else {
            selectedID = rows.first?.id
            return
        }
        let next = min(max(idx + delta, 0), rows.count - 1)
        selectedID = rows[next].id
    }

    private func selectedItem() -> PipelineHistoryItem? {
        guard let selectedID else { return nil }
        return visible.first { $0.id == selectedID }
    }

    private func copySelected() {
        guard let item = selectedItem() else { return }
        let text = HistoryText.display(item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func reuseSelected() {
        guard let item = selectedItem() else { return }
        let text = HistoryText.display(item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NotificationCenter.default.post(name: .sisoReuseTranscript, object: text)
    }
}

#if DEBUG
private enum HistoryPreviewData {
    static func make() -> [PipelineHistoryItem] {
        let apps = ["Safari", "Xcode", "Slack", "Notes"]
        let bundles = ["com.apple.Safari", "com.apple.dt.Xcode",
                       "com.tinyspeck.slackmacgap", "com.apple.Notes"]
        let samples = [
            "Let's ship the History page today and verify the typecheck is clean.",
            "Remind me to follow up with the partnerships team next week.",
            "The quick brown fox jumps over the lazy dog, then files a PR.",
            "Note to self: the debounce should be about two hundred milliseconds.",
        ]
        return (0..<140).map { i in
            let appIdx = i % apps.count
            // Spread across several days + within-day to exercise grouping.
            let date = Calendar.current.date(
                byAdding: .hour, value: -(i * 7), to: Date()) ?? Date()
            return PipelineHistoryItem(
                intent: i % 5 == 0 ? .commandManual : .dictation,
                timestamp: date,
                rawTranscript: samples[i % samples.count],
                postProcessedTranscript: i % 3 == 0 ? "" : samples[i % samples.count],
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "skipped",
                postProcessingStatus: "done",
                debugStatus: "ok",
                customVocabulary: "",
                contextAppName: apps[appIdx],
                contextBundleIdentifier: bundles[appIdx]
            )
        }
    }
}

#Preview("History — populated") {
    HistoryView(history: HistoryPreviewData.make(), onRefresh: {})
        .frame(width: 760, height: 640)
        .background(SISOTheme.Colors.canvas)
}

#Preview("History — empty") {
    HistoryView(history: [], onRefresh: {})
        .frame(width: 760, height: 640)
        .background(SISOTheme.Colors.canvas)
}
#endif
