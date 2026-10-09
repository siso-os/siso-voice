//
//  KeycapEditor.swift
//  SISO Voice (freeflow fork) — UI v2
//
//  The hotkey keycap editor (spec §3.1 "the spec's KeycapChip.swift capture
//  controller"). THE hotkey-revert-bug fix: bindings are read live from
//  `appState.{hold,toggle,copyAgain}Shortcut` and committed back through
//  `appState.setShortcut(_:for:)` — whose `@Published` `didSet` persists. This
//  view owns ZERO persistent state; all capture state is transient `@State`.
//
//  Capture reuses the proven `LocalShortcutCaptureBackend` + `ShortcutMatcher`
//  mechanism from ShortcutComponents.swift — it is not reinvented here.
//
//  Pure SwiftUI, macOS 13+.
//

import SwiftUI
import AppKit

// MARK: - HomeKeybindingRow

/// A keybinding row for the Home/Settings page: label/sublabel on the left, the
/// current binding rendered as a `SISOKeycapChip` plus a pencil-edit affordance
/// on the right. Tapping edit drops into an inline capture controller that
/// commits the new chord directly to AppState.
///
/// **Bug-proof contract:** the displayed chip ALWAYS reflects the live
/// `binding.displayName`; on commit we call `commit(newBinding)` (which is
/// `appState.setShortcut(_:for:)`), and the chip re-renders from the resulting
/// `@Published` value. No local copy of the binding is held across edits.
struct HomeKeybindingRow: View {
    let icon: String?
    let label: String
    let sublabel: String?
    /// The live binding to render (read from AppState's `@Published` property).
    let binding: ShortcutBinding
    /// The saved custom shortcut for "use saved", if any.
    let savedBinding: ShortcutBinding?
    /// Commit a chord. Returns a non-nil validation message to reject + stay in
    /// capture; nil means accepted. Wire this to `appState.setShortcut(_:for:)`.
    let commit: (ShortcutBinding) -> String?

    @State private var isCapturing = false
    @State private var validationMessage: String?

    /// - Parameters:
    ///   - icon: optional SF Symbol for the row.
    ///   - label: primary label (e.g. "Hold to Talk").
    ///   - sublabel: optional secondary line.
    ///   - binding: the live `ShortcutBinding` from AppState.
    ///   - savedBinding: the saved custom shortcut for this role, if any.
    ///   - commit: chord-commit closure (`appState.setShortcut(_:for:)`).
    init(icon: String? = nil,
         label: String,
         sublabel: String? = nil,
         binding: ShortcutBinding,
         savedBinding: ShortcutBinding?,
         commit: @escaping (ShortcutBinding) -> String?) {
        self.icon = icon
        self.label = label
        self.sublabel = sublabel
        self.binding = binding
        self.savedBinding = savedBinding
        self.commit = commit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s2) {
            SISORow(icon: icon, label: label, sublabel: sublabel) {
                if isCapturing {
                    HomeKeycapCaptureController(
                        savedBinding: savedBinding,
                        onCommit: { newBinding in
                            let message = commit(newBinding)
                            validationMessage = message
                            if message == nil {
                                isCapturing = false
                            }
                            return message
                        },
                        onCancel: {
                            validationMessage = nil
                            isCapturing = false
                        }
                    )
                } else {
                    HStack(spacing: SISOTheme.Metrics.s2) {
                        SISOKeycapChip(binding.displayName)
                        Button {
                            validationMessage = nil
                            isCapturing = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(SISOTheme.Colors.textMuted)
                                .padding(SISOTheme.Metrics.s1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Edit shortcut")
                    }
                }
            }

            if let validationMessage, !validationMessage.isEmpty {
                SISOValidationPill(validationMessage)
                    .padding(.horizontal, SISOTheme.Metrics.s4)
            }
        }
    }
}

// MARK: - HomeKeycapCaptureController

/// The embedded capture controller. Drives `LocalShortcutCaptureBackend`, holds
/// only transient `@State`, and commits the captured chord via `onCommit`. Lifts
/// the capture logic from `ShortcutCaptureRow` (ShortcutComponents.swift) but
/// renders it in the SISO design system.
///
/// On commit, `onCommit` returns an optional validation message: non-nil means
/// the chord was rejected — we surface it and STAY in capture (matching the
/// spec's "non-nil = validation msg, stay in capture").
private struct HomeKeycapCaptureController: View {
    let savedBinding: ShortcutBinding?
    /// Returns a non-nil validation message to reject + stay in capture.
    let onCommit: (ShortcutBinding) -> String?
    let onCancel: () -> Void

    @State private var captureBackend: LocalShortcutCaptureBackend?
    @State private var captureInputState = ShortcutInputState()
    @State private var currentBinding: ShortcutBinding?

    var body: some View {
        HStack(spacing: SISOTheme.Metrics.s2) {
            // Live preview of the chord being captured.
            if let currentBinding {
                SISOKeycapChip(currentBinding.displayName)
            } else {
                Text("Press a shortcut…")
                    .sisoText(.caption, color: SISOTheme.Colors.accent)
            }

            Spacer(minLength: SISOTheme.Metrics.s2)

            if let savedBinding {
                SISOButton("Use Saved", variant: .secondary) {
                    _ = onCommit(savedBinding)
                }
            }
            SISOButton("Save", variant: .primary) {
                finishCapture()
            }
            SISOButton("Cancel", variant: .ghost) {
                cancelCapture()
            }
        }
        .onAppear { startCapture() }
        .onDisappear { stopBackend() }
    }

    private func startCapture() {
        stopBackend()
        captureInputState = ShortcutInputState()
        currentBinding = nil

        let backend = LocalShortcutCaptureBackend()
        backend.onInputEvent = { inputEvent in
            let result = ShortcutMatcher.reduce(
                state: captureInputState,
                event: inputEvent,
                configuration: .disabled
            )
            captureInputState = result.state

            guard case .modifierChanged(let keyCode, _) = inputEvent else { return }
            if let binding = ShortcutBinding.fromModifierKeyCode(
                keyCode,
                pressedModifierKeyCodes: captureInputState.pressedModifierKeyCodes,
                allowBareModifier: true
            ) {
                currentBinding = binding
            }
        }
        backend.onKeyDownEvent = { event in
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            let hasPendingCapture = currentBinding != nil

            if isReturnKey && hasPendingCapture {
                finishCapture()
                return
            }
            // Esc with a pending chord commits; Esc with nothing cancels.
            if event.keyCode == 53 {
                if hasPendingCapture {
                    finishCapture()
                } else {
                    cancelCapture()
                }
                return
            }

            guard !ShortcutBinding.modifierKeyCodes.contains(event.keyCode) else { return }

            guard let binding = ShortcutBinding.from(
                event: event,
                pressedModifierKeyCodes: captureInputState.pressedModifierKeyCodes
            ) else { return }

            currentBinding = binding
        }
        backend.start()
        captureBackend = backend
    }

    private func finishCapture() {
        guard let currentBinding else {
            cancelCapture()
            return
        }
        // Commit through AppState. If rejected (non-nil message), the parent row
        // surfaces it and keeps us in capture; restart so the user can retry.
        if onCommit(currentBinding) != nil {
            self.currentBinding = nil
            startCapture()
        } else {
            stopBackend()
        }
    }

    private func cancelCapture() {
        stopBackend()
        onCancel()
    }

    private func stopBackend() {
        captureBackend?.stop()
        captureBackend = nil
        captureInputState = ShortcutInputState()
        currentBinding = nil
    }
}

#if DEBUG
#Preview("Keycap Editor") {
    HomeKeycapEditorPreviewHost()
        .padding(SISOTheme.Metrics.s6)
        .frame(width: 420)
        .background(SISOTheme.Colors.canvas)
}

private struct HomeKeycapEditorPreviewHost: View {
    @State private var binding: ShortcutBinding = .defaultToggle
    var body: some View {
        SISOCard {
            HomeKeybindingRow(
                icon: "switch.2",
                label: "Tap to Toggle",
                sublabel: "Tap once to start, again to stop",
                binding: binding,
                savedBinding: nil,
                commit: { newBinding in
                    binding = newBinding
                    return nil
                }
            )
        }
    }
}
#endif
