import AppKit
import SwiftUI

@MainActor
final class DictationDraftPresenter: NSObject, NSWindowDelegate {
    static let shared = DictationDraftPresenter()

    private var panel: NSPanel?
    private var draftState: DictationDraftState?
    private var targetPID: pid_t?
    private var onPaste: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    private var completionPending = false
    private var activationInProgress = false

    private override init() {
        super.init()
    }

    func present(text: String, onPaste: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        cancelCurrentDraft()

        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        self.onPaste = onPaste
        self.onCancel = onCancel
        completionPending = true
        activationInProgress = false

        let state = DictationDraftState(text: text)
        draftState = state
        let panel = ensurePanel()
        panel.contentView = NSHostingView(rootView: DictationDraftEditor(state: state,
            onPaste: { [weak self] in self?.pasteDraft() },
            onCancel: { [weak self] in self?.cancelCurrentDraft() }))
        panel.setFrame(panelFrame(), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard completionPending else { return }
        completionPending = false
        finishCancel()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: panelFrame(),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Dictation draft"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.minSize = NSSize(width: 420, height: 250)
        self.panel = panel
        return panel
    }

    private func panelFrame() -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        return NSRect(x: visible.midX - 280, y: visible.midY - 190, width: 560, height: 380)
    }

    private func pasteDraft() {
        guard completionPending, !activationInProgress, let state = draftState else { return }
        activationInProgress = true
        state.errorMessage = nil
        guard let pid = targetPID,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else {
            activationFailed("The original app is unavailable. Copy the draft or retry when it is open.")
            return
        }
        app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            guard self.completionPending, self.activationInProgress, self.targetPID == pid else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                self.activationFailed("The original app did not return to the front. Retry or copy the draft.")
                return
            }
            let text = state.text
            self.onPaste?(text)
            self.completionPending = false
            self.activationInProgress = false
            self.onPaste = nil
            self.onCancel = nil
            self.targetPID = nil
            self.panel?.orderOut(nil)
        }
    }

    private func cancelCurrentDraft() {
        guard completionPending else {
            panel?.orderOut(nil)
            return
        }
        completionPending = false
        activationInProgress = false
        panel?.orderOut(nil)
        finishCancel()
    }

    private func finishCancel() {
        activationInProgress = false
        let callback = onCancel
        onPaste = nil
        onCancel = nil
        targetPID = nil
        callback?()
    }

    private func activationFailed(_ message: String) {
        activationInProgress = false
        draftState?.errorMessage = message
    }
}

@MainActor
private final class DictationDraftState: ObservableObject {
    @Published var text: String
    @Published var errorMessage: String?
    init(text: String) {
        self.text = text
        self.errorMessage = nil
    }
}

private struct DictationDraftEditor: View {
    @ObservedObject var state: DictationDraftState
    let onPaste: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
            Text("Review your transcript").sisoText(.cardTitle)
            TextEditor(text: $state.text)
                .font(SISOTheme.font(.body))
                .padding(6)
                .background(SISOTheme.Colors.cardWhite)
                .overlay(RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius).stroke(SISOTheme.Colors.hairline))
            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .sisoText(.caption, color: SISOTheme.Colors.destructive)
                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.text, forType: .string)
                    }
                    Button("Retry", action: onPaste)
                        .buttonStyle(.borderedProminent)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if state.errorMessage == nil {
                    Button("Paste", action: onPaste)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(SISOTheme.Metrics.s4)
        .background(SISOTheme.Colors.canvas)
        .frame(minWidth: 420, minHeight: 250)
    }
}
