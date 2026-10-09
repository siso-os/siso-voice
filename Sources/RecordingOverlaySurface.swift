//
//  RecordingOverlaySurface.swift
//  freeflow
//
//  The shared method surface for recording overlays. SISO Voice uses the native
//  waveform popup; the disabled no-op and legacy orb implementations remain
//  available for source compatibility without being constructed in production.
//  All existing call sites bind to this protocol unchanged.
//
//  Swift protocol requirements cannot carry default argument values, so the
//  requirements take explicit args and a protocol `extension` restores the
//  no-arg ergonomics the call sites rely on (e.g. `showRecording()`).
//

import Foundation

// MARK: - Protocol

/// The interface both overlay managers expose. Method names + signatures mirror
/// the original `RecordingOverlayManager` so the managers are drop-in
/// interchangeable behind `overlay_style`.
protocol RecordingOverlaySurface: AnyObject {
    /// Stop-button tap callback (toggle mode). Pill wires it; orb may ignore.
    var onStopButtonPressed: (() -> Void)? { get set }
    /// "Update available" affordance tap callback.
    var onUpdateOverlayPressed: (() -> Void)? { get set }
    /// Legacy callback kept for manager compatibility. The orb no longer uses clicks as a trigger.
    var onOrbTapped: (() -> Void)? { get set }
    /// Optional native HUD controls. Non-interactive overlay styles use the default no-op storage.
    var onPauseButtonPressed: (() -> Void)? { get set }
    var onMuteButtonPressed: (() -> Void)? { get set }

    func showInitializing(mode: RecordingTriggerMode, isCommandMode: Bool)
    func showRecording(mode: RecordingTriggerMode, isCommandMode: Bool)
    func transitionToRecording(mode: RecordingTriggerMode, isCommandMode: Bool)
    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool)
    func updateAudioLevel(_ level: Float)
    func showTranscribing()
    func showFailureIndicator()
    func showError(_ message: String)
    func showUpdateAvailable(version: String)
    func setJarvisSending(_ isSending: Bool)
    func setJarvisSpeaking(_ isSpeaking: Bool)
    func setPaused(_ isPaused: Bool)
    func setMuted(_ isMuted: Bool)
    func toggleUserHidden()
    func dismiss()
}

// MARK: - Defaulted convenience overloads

/// Restore the default-argument ergonomics that protocol requirements can't
/// express. Call sites like `showRecording()` / `showInitializing(mode:)`
/// resolve to these, which forward to the explicit-arg requirements.
extension RecordingOverlaySurface {
    var onPauseButtonPressed: (() -> Void)? {
        get { nil }
        set {}
    }

    var onMuteButtonPressed: (() -> Void)? {
        get { nil }
        set {}
    }

    func showInitializing(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        showInitializing(mode: mode, isCommandMode: isCommandMode)
    }

    func showRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        showRecording(mode: mode, isCommandMode: isCommandMode)
    }

    func transitionToRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        transitionToRecording(mode: mode, isCommandMode: isCommandMode)
    }

    func setJarvisSpeaking(_ isSpeaking: Bool) {}

    func setJarvisSending(_ isSending: Bool) {}

    func setPaused(_ isPaused: Bool) {}

    func setMuted(_ isMuted: Bool) {}

    func toggleUserHidden() {}
}

// MARK: - Disabled runtime surface

/// Keeps the recording pipeline's UI contract intact without creating an overlay
/// window, display link, Metal view, WebView, timer, or audio-level rendering.
final class NoopRecordingOverlayManager: RecordingOverlaySurface {
    var onStopButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?
    var onOrbTapped: (() -> Void)?
    var onPauseButtonPressed: (() -> Void)?
    var onMuteButtonPressed: (() -> Void)?

    func showInitializing(mode: RecordingTriggerMode, isCommandMode: Bool) {}
    func showRecording(mode: RecordingTriggerMode, isCommandMode: Bool) {}
    func transitionToRecording(mode: RecordingTriggerMode, isCommandMode: Bool) {}
    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool) {}
    func updateAudioLevel(_ level: Float) {}
    func showTranscribing() {}
    func showFailureIndicator() {}
    func showError(_ message: String) {}
    func showUpdateAvailable(version: String) {}
    func setJarvisSending(_ isSending: Bool) {}
    func setJarvisSpeaking(_ isSpeaking: Bool) {}
    func setPaused(_ isPaused: Bool) {}
    func setMuted(_ isMuted: Bool) {}
    func toggleUserHidden() {}
    func dismiss() {}
}

// MARK: - Conformances

extension RecordingOverlayManager: RecordingOverlaySurface {}
extension OrbOverlayManager: RecordingOverlaySurface {}
