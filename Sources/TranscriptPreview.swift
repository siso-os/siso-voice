import AppKit
import SwiftUI

@MainActor
final class TranscriptPreviewManager {
    static let shared = TranscriptPreviewManager()

    private let panelSize = CGSize(width: 360, height: 118)
    private let horizontalMargin: CGFloat = 24
    private let verticalMargin: CGFloat = 24
    private let visibleDuration: TimeInterval = 4.0
    private let fadeAnimationDuration: TimeInterval = 0.22

    private let state = TranscriptPreviewState()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        state.text = trimmed
        state.isVisible = false

        let panel = ensurePanel()
        panel.orderFrontRegardless()

        withAnimation(.easeOut(duration: fadeAnimationDuration)) {
            state.isVisible = true
        }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(visibleDuration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: fadeAnimationDuration)) {
                self.state.isVisible = false
            }
            try? await Task.sleep(for: .seconds(fadeAnimationDuration))
            guard !Task.isCancelled else { return }
            if !self.state.isVisible {
                self.panel?.orderOut(nil)
            }
        }

        panel.setFrame(adjustedPanelFrame(), display: true)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let frame = adjustedPanelFrame()
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: TranscriptPreviewCard(state: state))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        self.panel = panel
        panel.setFrame(frame, display: true)
        return panel
    }

    private func adjustedPanelFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? .init(x: 0, y: 0, width: 1024, height: 768)
        let x = visibleFrame.maxX - panelSize.width - horizontalMargin
        let y = visibleFrame.maxY - panelSize.height - verticalMargin
        return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }
}

private final class TranscriptPreviewState: ObservableObject {
    @Published var text = ""
    @Published var isVisible = false
}

private struct TranscriptPreviewCard: View {
    @ObservedObject var state: TranscriptPreviewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.text)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.86))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                )
                .opacity(state.isVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: state.isVisible)
        }
        .frame(width: 350, alignment: .leading)
        .padding(2)
    }
}
