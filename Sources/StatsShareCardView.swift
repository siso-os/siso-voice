//
//  StatsShareCardView.swift
//  SISO Voice (freeflow fork) — Stats Share-Card page (UI v2 §3.2)
//
//  Page root: replaces the old 2×2 stat grid with a single hero dashed-ticket
//  share card + copy / download-PNG / share action buttons. Composes the
//  exportable `ShareCardTicket` and routes its actions through `ShareCardExport`.
//
//  Consumes shared §2 components (SISOButton, SISOHairline, MainWindowHeader)
//  and `SISOOrb` (inside the ticket). Empty history → zeroed ticket + disabled
//  action buttons.
//
//  Namespaced `Stats*`/`ShareCard*`. Target: Swift 6.1 / SwiftUI on macOS 13+.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct StatsShareCardView: View {
    let history: [PipelineHistoryItem]

    @State private var copied = false
    @State private var savedURL: URL?
    @State private var shareAnchor = StatsShareAnchor()

    init(history: [PipelineHistoryItem]) {
        self.history = history
    }

    private var stats: ShareCardStats { ShareCardStats.make(from: history) }
    private var actionsEnabled: Bool { !stats.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {
            MainWindowHeader(title: "Stats", onRefresh: nil)

            ScrollView {
                VStack(spacing: SISOTheme.Metrics.s6) {
                    ShareCardTicket(stats: stats)
                        .frame(maxWidth: 720)

                    actionBar

                    if let url = savedURL {
                        Text("Saved to \(url.path)")
                            .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SISOTheme.Metrics.s4)
            }
        }
        .padding(SISOTheme.Metrics.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SISOTheme.Colors.canvas)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: SISOTheme.Metrics.s3) {
            SISOButton(copied ? "Copied" : "Copy", variant: .secondary) {
                ShareCardExport.copySummary(stats)
                flashCopied()
            }
            .disabled(!actionsEnabled)

            SISOButton("Download PNG", variant: .secondary) {
                savedURL = ShareCardExport.savePNG(for: stats)
            }
            .disabled(!actionsEnabled)

            // Share anchors to a hidden NSView so the picker has a frame.
            ZStack {
                StatsShareAnchorView(anchor: shareAnchor)
                    .frame(width: 1, height: 1)
                SISOButton("Share", variant: .primary) {
                    shareAnchor.present(stats: stats)
                }
            }
            .disabled(!actionsEnabled)
            .opacity(actionsEnabled ? 1 : 0.5)
        }
        .opacity(actionsEnabled ? 1 : 0.5)
    }

    private func flashCopied() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}

// MARK: - Share anchor (NSView bridge for NSSharingServicePicker)

/// Holds a weak reference to the live `NSView` backing the Share button so the
/// share picker can anchor to a real frame. Updated by `StatsShareAnchorView`.
@MainActor
final class StatsShareAnchor: ObservableObject {
    weak var view: NSView?

    func present(stats: ShareCardStats) {
        guard let view else { return }
        ShareCardExport.share(stats, relativeTo: view.bounds, of: view)
    }
}

/// A zero-size `NSViewRepresentable` whose backing view is captured into the
/// `StatsShareAnchor` so the share sheet has something to anchor to.
private struct StatsShareAnchorView: NSViewRepresentable {
    let anchor: StatsShareAnchor

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

#if DEBUG
// MARK: - Preview fixtures

enum ShareCardPreviewData {
    static var sample: [PipelineHistoryItem] {
        let apps = ["cmux", "Xcode", "Safari", "cmux", "Slack", "cmux"]
        let now = Date()
        return (0..<24).map { i in
            let words = ["the quick brown fox jumps over the lazy dog and keeps going",
                         "ship it then verify the running artifact down the changed path",
                         "build to the spec and beat aqua voice on the share card"][i % 3]
            return PipelineHistoryItem(
                timestamp: now.addingTimeInterval(Double(-i) * 3600 * 5),
                rawTranscript: words,
                postProcessedTranscript: words,
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "none",
                postProcessingStatus: "done",
                debugStatus: "",
                customVocabulary: "",
                contextAppName: apps[i % apps.count]
            )
        }
    }
}

#Preview("Stats — with history") {
    StatsShareCardView(history: ShareCardPreviewData.sample)
        .frame(width: 900, height: 720)
}

#Preview("Stats — empty") {
    StatsShareCardView(history: [])
        .frame(width: 900, height: 720)
}
#endif
