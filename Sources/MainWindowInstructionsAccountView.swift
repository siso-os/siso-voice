//
//  MainWindowInstructionsAccountView.swift
//  SISO Voice (freeflow fork) — Instructions & Account page (§3.5)
//
//  Page root for the new `instructions` nav section. Header + segmented
//  Instructions/Account switch. The ONLY file `MainWindowView` references for
//  this page; switch-arm wiring is a separate task.
//
//  Two tabs:
//   - Instructions: cleanup-LLM system-prompt editor (beat-Aqua surface).
//   - Account: dictation-activity heatmap + spine-sync status. No billing.
//

import SwiftUI

// MARK: - MainWindowInstructionsAccountView

struct MainWindowInstructionsAccountView: View {
    let history: [PipelineHistoryItem]

    @StateObject private var store = InstructionsStore()
    @State private var selectedTab: String = "instructions"

    /// - Parameter history: dictation history used for the Account heatmap/stats.
    init(history: [PipelineHistoryItem]) {
        self.history = history
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {
                MainWindowHeader(title: "Instructions", onRefresh: nil)

                SISOSegmented(
                    selection: $selectedTab,
                    options: [("instructions", "Instructions"), ("account", "Account")]
                )
                .frame(maxWidth: 320)

                if selectedTab == "instructions" {
                    InstructionsEditorView(store: store)
                } else {
                    AccountActivityView(history: history)
                }
            }
            .padding(SISOTheme.Metrics.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SISOTheme.Colors.canvas)
    }
}

#if DEBUG
#Preview("Instructions & Account") {
    let now = Date()
    let cal = Calendar.current
    let sample: [PipelineHistoryItem] = (0..<40).map { i in
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
    return MainWindowInstructionsAccountView(history: sample)
        .frame(width: 760, height: 720)
}
#endif
