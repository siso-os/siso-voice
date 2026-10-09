//
//  OrbOverlay.swift
//  freeflow
//
//  The floating-overlay surface that hosts `JarvisOrb` in an always-on-top,
//  click-through `NSPanel`. A drop-in alternative to the notch pill
//  (`RecordingOverlayManager`): same public method names so `AppState` can pick
//  either via the `overlay_style` UserDefaults flag (0 = pill, 1 = orb).
//
//  Resident model: when `orb_always_visible` is true, the orb stays on-screen
//  breathing dim in `.idle` even after `dismiss()`. Otherwise `dismiss()`
//  orders the panel out.
//

import SwiftUI
import AppKit

// MARK: - State

/// Observable backing state for the orb overlay. The SwiftUI orb observes this;
/// the manager mutates it on the main thread.
final class OrbOverlayState: ObservableObject {
    @Published var phase: OrbPhase = .idle
    @Published var audioLevel: Float = 0.0
}

// MARK: - Anchor

/// Where the orb parks on its target screen. `webcam` derives a top-center
/// point from the notch (auxiliary-top-left area) with zero camera permissions;
/// non-notched displays fall back to top-center.
enum OrbAnchor: Int {
    case topRight = 0
    case topLeft = 1
    case bottomRight = 2
    case bottomLeft = 3
    case webcam = 4

    /// Read the persisted anchor (`orb_anchor`), defaulting to top-right.
    static var current: OrbAnchor {
        OrbAnchor(rawValue: UserDefaults.standard.integer(forKey: "orb_anchor")) ?? .topRight
    }
}

// MARK: - Root View

/// The SwiftUI root hosted in the panel. Observes the overlay state and renders
/// the orb sized so its bloom fits inside the panel.
private struct OrbOverlayRoot: View {
    @ObservedObject var state: OrbOverlayState
    let coreDiameter: CGFloat

    var body: some View {
        JarvisOrb(audioLevel: state.audioLevel, phase: state.phase, coreDiameter: coreDiameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Panel factory

/// Build the borderless, click-through, always-on-top panel that hosts the orb.
/// Transparent (`.clear`), no shadow (the glow is drawn in SwiftUI), screen-saver
/// level, joins all spaces + full-screen aux so it persists over fullscreen apps.
private func makeOrbPanel(size: CGFloat) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: size, height: size),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    return panel
}

// MARK: - Manager

/// NSPanel lifecycle + geometry for the orb overlay. Mirrors the pill manager's
/// method names so it's a drop-in `RecordingOverlaySurface` (see
/// RecordingOverlaySurface.swift for the conformance).
final class OrbOverlayManager {
    private var panel: NSPanel?
    private let state = OrbOverlayState()
    private var screenObserver: NSObjectProtocol?

    /// Whether `.feedback` (error) is currently showing; used to auto-resolve
    /// the red pulse back to idle/hidden.
    private var errorToken: UUID?

    // MARK: Protocol callbacks (the orb ignores both; kept for interface parity).
    var onStopButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?
    var onOrbTapped: (() -> Void)?

    // MARK: Geometry constants

    /// Sphere diameter. Panel is larger by `glowBleedFactor` so the bloom isn't clipped.
    private let coreDiameter: CGFloat = 64
    /// Panel = coreDiameter * this, so the outer aura (~1.45× + blur) has room.
    private let glowBleedFactor: CGFloat = 2.4
    private var panelSize: CGFloat { coreDiameter * glowBleedFactor }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.repositionPanel()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: Resident-visibility flag

    /// When true, the orb stays on-screen breathing dim in `.idle` after dismiss.
    private var alwaysVisible: Bool {
        (UserDefaults.standard.object(forKey: "orb_always_visible") as? Bool) ?? false
    }
    private var userHidden = false

    // MARK: Target screen + frame

    /// The screen the orb parks on — same UserDefaults contract as the pill
    /// (`overlay_display_id`: 0 = active/main, -1 = primary, else specific displayID).
    private var targetScreen: NSScreen? {
        let savedID = UserDefaults.standard.integer(forKey: "overlay_display_id")
        switch savedID {
        case 0:
            return NSScreen.main ?? NSScreen.screens.first
        case -1:
            return NSScreen.screens.first ?? NSScreen.main
        default:
            if let match = NSScreen.screens.first(where: { Int($0.displayID ?? 0) == savedID }) {
                return match
            }
            return NSScreen.screens.first ?? NSScreen.main
        }
    }

    /// User-configured edge offset (`orb_offset_x` / `orb_offset_y`, default 24pt).
    private var offset: CGSize {
        let d = UserDefaults.standard
        let x = d.object(forKey: "orb_offset_x") as? Int ?? 24
        let y = d.object(forKey: "orb_offset_y") as? Int ?? 24
        return CGSize(width: CGFloat(x), height: CGFloat(y))
    }

    /// The panel frame for the current anchor + screen, in screen coordinates.
    private var orbFrame: NSRect {
        guard let screen = targetScreen else { return .zero }
        let f = screen.frame
        let s = panelSize
        let ox = offset.width
        let oy = offset.height

        switch OrbAnchor.current {
        case .topRight:
            return NSRect(x: f.maxX - s - ox, y: f.maxY - s - oy, width: s, height: s)
        case .topLeft:
            return NSRect(x: f.minX + ox, y: f.maxY - s - oy, width: s, height: s)
        case .bottomRight:
            return NSRect(x: f.maxX - s - ox, y: f.minY + oy, width: s, height: s)
        case .bottomLeft:
            return NSRect(x: f.minX + ox, y: f.minY + oy, width: s, height: s)
        case .webcam:
            // Notch-derived center, zero camera permissions. The notch sits
            // between the two auxiliary top areas; its center-x is the midpoint
            // between leftArea.maxX and rightArea.minX. Non-notched displays
            // fall back to screen top-center. Y hugs the top edge (under the notch).
            let centerX = webcamCenterX(on: screen)
            let x = centerX - s / 2
            let y = f.maxY - s - oy
            return NSRect(x: x, y: y, width: s, height: s)
        }
    }

    /// Horizontal center of the notch (camera) on a screen, or screen midX when
    /// the display has no notch. Uses `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`
    /// only — no `AVCaptureDevice` probing, so no camera permission prompt.
    private func webcamCenterX(on screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            // leftArea is anchored at the screen's left edge; rightArea at the right.
            // The notch spans from leftArea.maxX to rightArea.minX.
            let left = screen.frame.minX + leftArea.maxX
            let right = screen.frame.minX + rightArea.minX
            return (left + right) / 2
        }
        return screen.frame.midX
    }

    // MARK: Surface methods (mirror the pill manager)

    func showInitializing(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        setPhase(.listening, audioLevel: 0)
    }

    func showRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        setPhase(.listening, audioLevel: 0)
    }

    func transitionToRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        setPhase(.listening, audioLevel: nil)
    }

    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool) {
        // Trigger mode does not change the orb's visuals; no-op for parity.
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.state.audioLevel = level
        }
    }

    func showTranscribing() {
        setPhase(.transcribing, audioLevel: 0)
    }

    func showFailureIndicator() {
        showErrorPulse()
    }

    func showError(_ message: String) {
        // The orb has no text affordance; surface errors as the red pulse.
        showErrorPulse()
    }

    func showUpdateAvailable(version: String) {
        // Ignored per spec (`.updateAvailable` → ignored). Keep resident idle.
        if alwaysVisible && !userHidden { setPhase(.idle, audioLevel: 0) }
    }

    func dismiss() {
        DispatchQueue.main.async {
            self.errorToken = nil
            if self.alwaysVisible {
                // Resident: fall back to dim breathing idle, stay on-screen.
                self.state.phase = .idle
                self.state.audioLevel = 0
                self.ensurePanelVisible()
            } else {
                self.state.phase = .idle
                self.state.audioLevel = 0
                self.panel?.orderOut(nil)
            }
        }
    }

    // MARK: Internals

    private func applyUserHiddenState() {
        self.errorToken = nil
        self.state.phase = .idle
        self.state.audioLevel = 0
        self.panel?.orderOut(nil)
    }

    func toggleUserHidden() {
        DispatchQueue.main.async {
            self.userHidden.toggle()
            if self.userHidden {
                self.applyUserHiddenState()
            } else {
                self.state.phase = .idle
                self.state.audioLevel = 0
                self.ensurePanelVisible()
            }
        }
    }

    private func showErrorPulse() {
        let token = UUID()
        DispatchQueue.main.async {
            guard !self.userHidden else {
                self.applyUserHiddenState()
                return
            }
            self.errorToken = token
            self.state.audioLevel = 0
            self.state.phase = .error
            self.ensurePanelVisible()
            // Red pulse → auto-resolve to idle (or hidden) after a short hold.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.errorToken == token else { return }
                self.errorToken = nil
                if self.alwaysVisible {
                    self.state.phase = .idle
                } else {
                    self.state.phase = .idle
                    self.panel?.orderOut(nil)
                }
            }
        }
    }

    /// Set the orb phase (and optionally audio level) and make sure the panel is up.
    private func setPhase(_ phase: OrbPhase, audioLevel: Float?) {
        DispatchQueue.main.async {
            guard !self.userHidden else {
                self.applyUserHiddenState()
                return
            }
            self.errorToken = nil
            self.state.phase = phase
            if let audioLevel { self.state.audioLevel = audioLevel }
            self.ensurePanelVisible()
        }
    }

    /// Create the panel on first use (or re-show an existing one) and position it.
    private func ensurePanelVisible() {
        guard !userHidden else {
            panel?.orderOut(nil)
            return
        }
        if let panel {
            panel.setFrame(orbFrame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let p = makeOrbPanel(size: panelSize)
        let host = NSHostingView(
            rootView: OrbOverlayRoot(state: state, coreDiameter: coreDiameter)
        )
        host.frame = NSRect(x: 0, y: 0, width: panelSize, height: panelSize)
        host.autoresizingMask = [.width, .height]
        // Keep the hosting view transparent so only the orb's glow shows.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host
        p.setFrame(orbFrame, display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
    }

    /// Re-place the panel after a screen-arrangement change; tolerate the target
    /// display being unplugged (frame falls back to another screen).
    private func repositionPanel() {
        guard let panel else { return }
        guard !userHidden else {
            panel.orderOut(nil)
            return
        }
        let frame = orbFrame
        guard frame != .zero else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(frame, display: true)
    }
}
