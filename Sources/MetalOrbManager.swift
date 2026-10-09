import AppKit

/// Native AppKit manager for the preserved voice HUD. This active surface intentionally has no
/// Metal, renderer, display-link, or screen-sampler dependency.
final class VoiceHUDManager: NSObject, RecordingOverlaySurface {
    var onStopButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?
    var onOrbTapped: (() -> Void)?
    var onPauseButtonPressed: (() -> Void)?
    var onMuteButtonPressed: (() -> Void)?

    private var panel: NSPanel?
    private var hudView: VoiceHUDContainerView?
    private var observer: NSObjectProtocol?
    private static let capsuleSize = NSSize(width: 276, height: 44)
    private static let railSize = NSSize(width: 50, height: 192)
    private static let edgeMargin: CGFloat = 8
    private static let topOverlap: CGFloat = 6
    private static let snapDistance: CGFloat = 28
    private static let dockKey = "voice_hud_dock_v1"
    private static let screenKey = "voice_hud_screen_id_v1"
    private static let normalizedXKey = "voice_hud_normalized_x_v1"
    private static let normalizedYKey = "voice_hud_normalized_y_v1"
    private var dockMode = VoiceHUDDock(rawValue: UserDefaults.standard.string(forKey: "voice_hud_dock_v1") ?? "") ?? .topCenter
    private var sessionActive = false
    private var recordingPaused = false
    private var microphoneMuted = false
    private var controlsReady = false
    private var phase: VoiceHUDVisualPhase = .idle
    private var timer: Timer?
    private var startedAt: TimeInterval?
    private var frozenElapsed: TimeInterval = 0
    private var userHidden = false
    private var wasTranscribing = false
    private var isJarvisSpeaking = false
    private var isJarvisSending = false
    private var dragOffset: CGSize?
    private var dragStart: NSPoint?
    private var didDrag = false

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layoutPanel() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; timer?.invalidate() }

    private var screen: NSScreen? {
        if let saved = UserDefaults.standard.object(forKey: Self.screenKey) as? NSNumber,
           let found = NSScreen.screens.first(where: { Int($0.displayID ?? 0) == saved.intValue }) { return found }
        let id = UserDefaults.standard.integer(forKey: "overlay_display_id")
        if id == 0 { return NSScreen.main ?? NSScreen.screens.first }
        if id == -1 { return NSScreen.screens.first ?? NSScreen.main }
        return NSScreen.screens.first(where: { Int($0.displayID ?? 0) == id }) ?? NSScreen.main
    }
    private func screen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { a, b in NSIntersectionRect(a.frame, frame).width * NSIntersectionRect(a.frame, frame).height < NSIntersectionRect(b.frame, frame).width * NSIntersectionRect(b.frame, frame).height } ?? screen
    }
    private var presentation: VoiceHUDPresentation { dockMode == .left || dockMode == .right ? .sideRail : .capsule }
    private func size(_ p: VoiceHUDPresentation) -> NSSize { p == .sideRail ? Self.railSize : Self.capsuleSize }
    private func clamped(_ frame: NSRect, to area: NSRect) -> NSRect {
        var result = frame
        result.origin.x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
        result.origin.y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height + Self.topOverlap))
        return result
    }
    private func targetFrame(on screen: NSScreen, for p: VoiceHUDPresentation) -> NSRect {
        let area = screen.visibleFrame, s = size(p)
        let origin: NSPoint
        switch dockMode {
        case .topLeft: origin = NSPoint(x: area.minX + Self.edgeMargin, y: area.maxY - s.height + Self.topOverlap)
        case .topCenter: origin = NSPoint(x: area.midX - s.width / 2, y: area.maxY - s.height + Self.topOverlap)
        case .topRight: origin = NSPoint(x: area.maxX - s.width - Self.edgeMargin, y: area.maxY - s.height + Self.topOverlap)
        case .left: origin = NSPoint(x: area.minX + 4, y: area.midY - s.height / 2)
        case .right: origin = NSPoint(x: area.maxX - s.width - 4, y: area.midY - s.height / 2)
        case .free:
            let x = CGFloat((UserDefaults.standard.object(forKey: Self.normalizedXKey) as? NSNumber)?.doubleValue ?? 0.5)
            let y = CGFloat((UserDefaults.standard.object(forKey: Self.normalizedYKey) as? NSNumber)?.doubleValue ?? 0.82)
            origin = NSPoint(x: area.minX + x * area.width - s.width / 2, y: area.minY + y * area.height - s.height / 2)
        }
        return clamped(NSRect(origin: origin, size: s), to: area)
    }
    private func layoutPanel() {
        guard let panel, let hudView, let screen = screen(for: panel.frame) else { return }
        hudView.setPresentation(presentation); hudView.setPhase(phase); hudView.setRecordingControlsAvailable(controlsReady)
        panel.setFrame(targetFrame(on: screen, for: presentation), display: true)
    }
    private func ensurePanel() {
        guard panel == nil else { return }
        let hud = VoiceHUDContainerView(frame: NSRect(origin: .zero, size: Self.capsuleSize))
        hud.autoresizingMask = [.width, .height]
        hud.onPause = { [weak self] in self?.onPauseButtonPressed?() }
        hud.onMute = { [weak self] in self?.onMuteButtonPressed?() }
        hud.onMenu = { [weak self] in self?.showMenu() }
        hud.onDragBegan = { [weak self] in self?.beginDrag() }
        hud.onDrag = { [weak self] in self?.drag() }
        hud.onDragEnded = { [weak self] in self?.endDrag() }
        hud.onBackgroundClick = { [weak self] in self?.showMenu() }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.capsuleSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false; panel.level = .screenSaver
        panel.ignoresMouseEvents = false; panel.isMovable = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]; panel.isReleasedWhenClosed = false; panel.contentView = hud
        self.panel = panel; hudView = hud; layoutPanel()
    }
    private func beginDrag() { guard let panel else { return }; let mouse = NSEvent.mouseLocation; dragOffset = CGSize(width: mouse.x - panel.frame.minX, height: mouse.y - panel.frame.minY); dragStart = mouse; didDrag = false }
    private func drag() { guard let panel, let dragOffset else { return }; let mouse = NSEvent.mouseLocation; if let dragStart, hypot(mouse.x - dragStart.x, mouse.y - dragStart.y) > 4 { didDrag = true }; panel.setFrameOrigin(NSPoint(x: mouse.x - dragOffset.width, y: mouse.y - dragOffset.height)) }
    private func endDrag() { defer { dragOffset = nil; dragStart = nil }; guard didDrag, let panel, let screen = screen(for: panel.frame) else { return }; let area = screen.visibleFrame; let distances = [abs(area.maxY + Self.topOverlap - panel.frame.maxY), abs(area.minX + 4 - panel.frame.minX), abs(area.maxX - 4 - panel.frame.maxX)]; guard let nearest = distances.min(), nearest <= Self.snapDistance else { dockMode = .free; let clampedFrame = clamped(panel.frame, to: area); panel.setFrame(clampedFrame, display: true); persistFree(clampedFrame, on: screen); return }; if nearest == distances[1] { dockMode = .left } else if nearest == distances[2] { dockMode = .right } else { let ratio = (panel.frame.midX - area.minX) / max(area.width, 1); dockMode = ratio < 0.28 ? .topLeft : ratio > 0.72 ? .topRight : .topCenter }; persistDock(on: screen); layoutPanel() }
    private func persistDock(on screen: NSScreen) { UserDefaults.standard.set(dockMode.rawValue, forKey: Self.dockKey); if let id = screen.displayID { UserDefaults.standard.set(Int(id), forKey: Self.screenKey) } }
    private func persistFree(_ frame: NSRect, on screen: NSScreen) { let area = screen.visibleFrame; guard area.width > 0, area.height > 0 else { return }; UserDefaults.standard.set(Double(min(1, max(0, (frame.midX - area.minX) / area.width))), forKey: Self.normalizedXKey); UserDefaults.standard.set(Double(min(1, max(0, (frame.midY - area.minY) / area.height))), forKey: Self.normalizedYKey); UserDefaults.standard.set(VoiceHUDDock.free.rawValue, forKey: Self.dockKey) }
    private func showMenu() { guard let hudView else { return }; let menu = NSMenu(title: "SISO Voice"); if sessionActive { let item = NSMenuItem(title: "Stop and Transcribe", action: #selector(stopFromMenu), keyEquivalent: ""); item.target = self; menu.addItem(item); menu.addItem(.separator()) }; let reset = NSMenuItem(title: "Move to Top Center", action: #selector(resetPosition), keyEquivalent: ""); reset.target = self; menu.addItem(reset); menu.addItem(.separator()); let hide = NSMenuItem(title: "Hide Voice HUD", action: #selector(hideFromMenu), keyEquivalent: ""); hide.target = self; menu.addItem(hide); let point = dockMode == .left ? NSPoint(x: hudView.bounds.maxX, y: hudView.bounds.midY) : dockMode == .right ? NSPoint(x: hudView.bounds.minX, y: hudView.bounds.midY) : NSPoint(x: hudView.bounds.midX, y: hudView.bounds.minY); menu.popUp(positioning: nil, at: point, in: hudView) }
    @objc private func stopFromMenu() { onStopButtonPressed?() }
    @objc private func resetPosition() { dockMode = .topCenter; if let screen = screen(for: panel?.frame ?? .zero) ?? screen { persistDock(on: screen) }; layoutPanel() }
    @objc private func hideFromMenu() { toggleUserHidden() }
    private func startTimer() { timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshTimer() }; refreshTimer() }
    private func refreshTimer() { hudView?.setElapsed(frozenElapsed + (startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)) }
    private func freezeTimer() { if let startedAt { frozenElapsed += ProcessInfo.processInfo.systemUptime - startedAt; self.startedAt = nil }; timer?.invalidate(); timer = nil; refreshTimer() }
    private func beginSession() { guard !sessionActive else { return }; sessionActive = true; recordingPaused = false; microphoneMuted = false; controlsReady = false; frozenElapsed = 0; startedAt = ProcessInfo.processInfo.systemUptime; hudView?.resetWaveform(); startTimer() }
    private func finishSession() { sessionActive = false; recordingPaused = false; microphoneMuted = false; controlsReady = false; wasTranscribing = false; isJarvisSpeaking = false; isJarvisSending = false; timer?.invalidate(); timer = nil; startedAt = nil; frozenElapsed = 0; hudView?.resetWaveform(); hudView?.setElapsed(0); hudView?.setPaused(false); hudView?.setMuted(false) }
    private func show() { guard !userHidden else { panel?.orderOut(nil); return }; ensurePanel(); layoutPanel(); panel?.orderFrontRegardless() }
    private func setPhase(_ phase: VoiceHUDVisualPhase) { self.phase = phase; hudView?.setPhase(phase) }
    private func markUserDrivenPhase() { isJarvisSpeaking = false; isJarvisSending = false }
    func showInitializing(mode: RecordingTriggerMode, isCommandMode: Bool) { DispatchQueue.main.async { [self] in markUserDrivenPhase(); beginSession(); setPhase(.listening); show() } }
    func showRecording(mode: RecordingTriggerMode, isCommandMode: Bool) { DispatchQueue.main.async { [self] in markUserDrivenPhase(); beginSession(); controlsReady = true; setPhase(.listening); show() } }
    func transitionToRecording(mode: RecordingTriggerMode, isCommandMode: Bool) { showRecording(mode: mode, isCommandMode: isCommandMode) }
    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool) {}
    func setPaused(_ paused: Bool) { DispatchQueue.main.async { [self] in guard sessionActive, controlsReady else { return }; recordingPaused = paused; hudView?.setPaused(paused); if paused { freezeTimer() } else if startedAt == nil { startedAt = ProcessInfo.processInfo.systemUptime; startTimer() } } }
    func setMuted(_ muted: Bool) { DispatchQueue.main.async { [self] in guard sessionActive, controlsReady else { return }; microphoneMuted = muted; hudView?.setMuted(muted); if muted { hudView?.updateAudioLevel(0) } } }
    func updateAudioLevel(_ level: Float) { let value = recordingPaused || microphoneMuted ? 0 : max(0, min(1, level)); if Thread.isMainThread { hudView?.updateAudioLevel(value) } else { DispatchQueue.main.async { [weak self] in self?.hudView?.updateAudioLevel(value) } } }
    func showTranscribing() { DispatchQueue.main.async { [self] in markUserDrivenPhase(); beginSession(); freezeTimer(); wasTranscribing = true; setPhase(.transcribing); show() } }
    func showFailureIndicator() { DispatchQueue.main.async { [self] in markUserDrivenPhase(); beginSession(); freezeTimer(); setPhase(.error); show() }; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.dismiss() } }
    func showError(_ message: String) { showFailureIndicator() }
    func showUpdateAvailable(version: String) {}
    func setJarvisSpeaking(_ speaking: Bool) {
        DispatchQueue.main.async { [self] in
            if speaking {
                isJarvisSending = false
                isJarvisSpeaking = true
                beginSession()
                setPhase(.speaking)
                show()
            } else {
                guard isJarvisSpeaking else { return }
                isJarvisSpeaking = false
                resolveAfterJarvisSpeaking()
            }
        }
    }
    func setJarvisSending(_ sending: Bool) {
        DispatchQueue.main.async { [self] in
            if sending {
                isJarvisSending = true
                beginSession()
                setPhase(.thinking)
                show()
            } else {
                guard isJarvisSending else { return }
                isJarvisSending = false
                resolveAfterJarvisSending()
            }
        }
    }
    func toggleUserHidden() { DispatchQueue.main.async { [self] in userHidden.toggle(); if userHidden { finishSession(); panel?.orderOut(nil) } else if sessionActive { show() } } }
    func dismiss() { DispatchQueue.main.async { [self] in if wasTranscribing { wasTranscribing = false }; finishSession(); setPhase(.idle); panel?.orderOut(nil) } }

    private func resolveAfterJarvisSpeaking() {
        guard !userHidden else { finishSession(); panel?.orderOut(nil); return }
        finishSession()
        setPhase(.idle)
        panel?.orderOut(nil)
    }

    private func resolveAfterJarvisSending() {
        guard !isJarvisSpeaking else { return }
        guard !userHidden else { finishSession(); panel?.orderOut(nil); return }
        finishSession()
        setPhase(.idle)
        panel?.orderOut(nil)
    }
}
