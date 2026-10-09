import AppKit
import QuartzCore

enum VoiceHUDPresentation {
    case capsule
    case sideRail
}

enum VoiceHUDVisualPhase {
    case idle
    case listening
    case transcribing
    case speaking
    case thinking
    case error
}

enum VoiceHUDDock: String {
    case free
    case topLeft
    case topCenter
    case topRight
    case left
    case right
}

/// A single-layer, audio-level history trace. Unlike the legacy waveform, this view does not
/// create one SwiftUI spring per bar; all samples are combined into one path and redrawn at most
/// 30 times per second.
final class VoiceHUDWaveformView: NSView {
    enum Orientation {
        case horizontal
        case vertical
    }

    private let traceLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private var history = Array(repeating: CGFloat.zero, count: 40)
    private var smoothedLevel: CGFloat = 0
    private var lastPathUpdate: TimeInterval = 0
    private(set) var orientation: Orientation = .horizontal

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        for shape in [glowLayer, traceLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            layer?.addSublayer(shape)
        }
        glowLayer.lineWidth = 2.4
        traceLayer.lineWidth = 1.0
        setPhase(.idle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        traceLayer.frame = bounds
        glowLayer.frame = bounds
        rebuildPath()
    }

    func setOrientation(_ nextOrientation: Orientation) {
        guard orientation != nextOrientation else { return }
        orientation = nextOrientation
        rebuildPath()
    }

    func push(audioLevel rawLevel: Float) {
        let input = CGFloat(max(0, min(1, rawLevel)))
        let coefficient: CGFloat = input > smoothedLevel ? 0.42 : 0.16
        smoothedLevel += (input - smoothedLevel) * coefficient

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPathUpdate >= (1.0 / 30.0) else { return }
        lastPathUpdate = now

        history.removeFirst()
        history.append(smoothedLevel)
        rebuildPath()
    }

    func reset() {
        history = Array(repeating: 0, count: history.count)
        smoothedLevel = 0
        rebuildPath()
    }

    func setPhase(_ phase: VoiceHUDVisualPhase) {
        let color: NSColor
        let opacity: Float
        switch phase {
        case .idle:
            color = NSColor(srgbRed: 0.66, green: 0.52, blue: 1.0, alpha: 1)
            opacity = 0.24
        case .listening:
            color = NSColor(srgbRed: 0.72, green: 0.39, blue: 1.0, alpha: 1)
            opacity = 0.78
        case .transcribing:
            color = NSColor(srgbRed: 0.94, green: 0.35, blue: 0.92, alpha: 1)
            opacity = 0.72
        case .speaking:
            color = NSColor(srgbRed: 0.35, green: 0.72, blue: 1.0, alpha: 1)
            opacity = 0.82
        case .thinking:
            color = NSColor(srgbRed: 0.53, green: 0.48, blue: 1.0, alpha: 1)
            opacity = 0.66
        case .error:
            color = NSColor(srgbRed: 1.0, green: 0.32, blue: 0.42, alpha: 1)
            opacity = 0.88
        }

        traceLayer.strokeColor = color.cgColor
        traceLayer.opacity = opacity
        glowLayer.strokeColor = color.withAlphaComponent(0.28).cgColor
        glowLayer.opacity = opacity
    }

    private func rebuildPath() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path = CGMutablePath()

        switch orientation {
        case .horizontal:
            let count = min(history.count, max(14, Int(bounds.width / 3.1)))
            let first = history.count - count
            let step = bounds.width / CGFloat(max(1, count - 1))
            let centerY = bounds.midY
            let maximumExtent = max(1, bounds.height * 0.32)

            for index in 0..<count {
                let level = sqrt(max(0, history[first + index]))
                let extent = max(0.45, level * maximumExtent)
                let x = CGFloat(index) * step
                path.move(to: CGPoint(x: x, y: centerY - extent))
                path.addLine(to: CGPoint(x: x, y: centerY + extent))
            }

        case .vertical:
            let count = min(history.count, max(12, Int(bounds.height / 3.0)))
            let first = history.count - count
            let step = bounds.height / CGFloat(max(1, count - 1))
            let centerX = bounds.midX
            let maximumExtent = max(1, bounds.width * 0.34)

            for index in 0..<count {
                let level = sqrt(max(0, history[first + index]))
                let extent = max(0.45, level * maximumExtent)
                let y = CGFloat(index) * step
                path.move(to: CGPoint(x: centerX - extent, y: y))
                path.addLine(to: CGPoint(x: centerX + extent, y: y))
            }
        }

        traceLayer.path = path
        glowLayer.path = path
    }
}

final class VoiceHUDIconButton: NSButton {
    var handler: (() -> Void)?
    private var isVisuallyActive = false

    init(symbolName: String, accessibilityLabel: String, prominent: Bool = false) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
        target = self
        action = #selector(invokeHandler)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.white.withAlphaComponent(prominent ? 0.075 : 0.001).cgColor
        layer?.borderWidth = prominent ? 0.75 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        contentTintColor = NSColor.white.withAlphaComponent(0.72)

        let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(configuration)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        contentTintColor = NSColor.white.withAlphaComponent(0.96)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @objc private func invokeHandler() {
        handler?()
    }

    func setSymbol(_ symbolName: String, accessibilityLabel: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(configuration)
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
    }

    func setVisuallyActive(_ active: Bool) {
        isVisuallyActive = active
        updateAppearance()
    }

    private func updateAppearance() {
        if isVisuallyActive {
            layer?.backgroundColor = NSColor(srgbRed: 0.58, green: 0.34, blue: 0.92, alpha: 0.22).cgColor
            contentTintColor = NSColor.white.withAlphaComponent(0.94)
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(tag == 1 ? 0.075 : 0.001).cgColor
            contentTintColor = NSColor.white.withAlphaComponent(0.72)
        }
    }
}

/// Native glass shell shared by the capsule and side rail.
final class VoiceHUDContainerView: NSView {
    var onPause: (() -> Void)?
    var onMute: (() -> Void)?
    var onMenu: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDrag: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onBackgroundClick: (() -> Void)?

    private let materialView = NSVisualEffectView()
    private let tintView = NSView()
    private let borderLayer = CAShapeLayer()
    private let highlightLayer = CAGradientLayer()
    private let waveformView = VoiceHUDWaveformView(frame: .zero)
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let pauseButton = VoiceHUDIconButton(
        symbolName: "pause.fill",
        accessibilityLabel: "Pause recording",
        prominent: true
    )
    private let muteButton = VoiceHUDIconButton(
        symbolName: "mic.fill",
        accessibilityLabel: "Mute microphone"
    )
    private let menuButton = VoiceHUDIconButton(
        symbolName: "chevron.down",
        accessibilityLabel: "Open voice controls"
    )
    private(set) var presentation: VoiceHUDPresentation = .capsule
    private(set) var visualPhase: VoiceHUDVisualPhase = .idle
    private var recordingControlsAvailable = false
    private var mouseDownLocation: NSPoint?
    private var dragged = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        materialView.material = .hudWindow
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor(
            srgbRed: 0.035,
            green: 0.037,
            blue: 0.055,
            alpha: 0.68
        ).cgColor

        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        timerLabel.textColor = NSColor.white.withAlphaComponent(0.52)
        timerLabel.alignment = .center
        timerLabel.lineBreakMode = .byClipping

        pauseButton.tag = 1
        pauseButton.handler = { [weak self] in self?.onPause?() }
        muteButton.handler = { [weak self] in self?.onMute?() }
        menuButton.handler = { [weak self] in self?.onMenu?() }

        addSubview(materialView)
        addSubview(tintView)
        addSubview(waveformView)
        addSubview(timerLabel)
        addSubview(pauseButton)
        addSubview(muteButton)
        addSubview(menuButton)

        borderLayer.fillColor = nil
        borderLayer.lineWidth = 0.8
        layer?.addSublayer(borderLayer)

        highlightLayer.startPoint = CGPoint(x: 0, y: 0.5)
        highlightLayer.endPoint = CGPoint(x: 1, y: 0.5)
        highlightLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.20).cgColor,
            NSColor.clear.cgColor,
        ]
        layer?.addSublayer(highlightLayer)

        setPresentation(.capsule)
        setPhase(.idle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        for control in [pauseButton, muteButton, menuButton] where !control.isHidden {
            let localPoint = convert(point, to: control)
            if control.bounds.contains(localPoint) { return control }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        dragged = false
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = mouseDownLocation {
            let current = NSEvent.mouseLocation
            if hypot(current.x - start.x, current.y - start.y) > 4 { dragged = true }
        }
        onDrag?()
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
        if !dragged { onBackgroundClick?() }
        mouseDownLocation = nil
    }

    override func layout() {
        super.layout()

        let shell = bounds.insetBy(dx: 4, dy: 4)
        let radius: CGFloat = presentation == .sideRail ? 21 : shell.height / 2

        materialView.frame = shell
        tintView.frame = shell
        materialView.layer?.cornerRadius = radius
        tintView.layer?.cornerRadius = radius
        materialView.layer?.masksToBounds = true
        tintView.layer?.masksToBounds = true

        borderLayer.frame = bounds
        borderLayer.path = CGPath(roundedRect: shell, cornerWidth: radius, cornerHeight: radius, transform: nil)

        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.34
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowPath = CGPath(roundedRect: shell, cornerWidth: radius, cornerHeight: radius, transform: nil)

        highlightLayer.isHidden = false
        highlightLayer.frame = NSRect(
            x: shell.minX + 16,
            y: shell.maxY - 1.5,
            width: max(0, shell.width - 32),
            height: 1
        )

        switch presentation {
        case .capsule:
            let centerY = shell.midY
            let menuFrame = NSRect(x: shell.maxX - 30, y: centerY - 12, width: 24, height: 24)
            let muteFrame = NSRect(x: menuFrame.minX - 26, y: centerY - 12, width: 24, height: 24)
            let pauseFrame = NSRect(x: muteFrame.minX - 26, y: centerY - 12, width: 24, height: 24)
            let timerFrame = NSRect(x: pauseFrame.minX - 38, y: centerY - 7, width: 34, height: 14)
            let waveX = shell.minX + 8
            waveformView.frame = NSRect(
                x: waveX,
                y: centerY - 8,
                width: max(36, timerFrame.minX - waveX - 6),
                height: 16
            )
            timerLabel.frame = timerFrame
            pauseButton.frame = pauseFrame
            muteButton.frame = muteFrame
            menuButton.frame = menuFrame

        case .sideRail:
            waveformView.frame = NSRect(x: shell.midX - 8, y: shell.minY + 95, width: 16, height: 47)
            timerLabel.frame = NSRect(x: shell.minX + 4, y: shell.minY + 77, width: shell.width - 8, height: 14)
            pauseButton.frame = NSRect(x: shell.midX - 12, y: shell.minY + 52, width: 24, height: 24)
            muteButton.frame = NSRect(x: shell.midX - 12, y: shell.minY + 27, width: 24, height: 24)
            menuButton.frame = NSRect(x: shell.midX - 12, y: shell.minY + 3, width: 24, height: 24)
        }
    }

    func setPresentation(_ nextPresentation: VoiceHUDPresentation) {
        presentation = nextPresentation
        waveformView.isHidden = false
        timerLabel.isHidden = false
        pauseButton.isHidden = false
        muteButton.isHidden = false
        menuButton.isHidden = false
        waveformView.setOrientation(nextPresentation == .sideRail ? .vertical : .horizontal)
        needsLayout = true
    }

    func setPhase(_ phase: VoiceHUDVisualPhase) {
        visualPhase = phase
        waveformView.setPhase(phase)

        let borderColor: NSColor
        switch phase {
        case .idle:
            borderColor = NSColor.white.withAlphaComponent(0.11)
        case .listening:
            borderColor = NSColor(srgbRed: 0.76, green: 0.47, blue: 1.0, alpha: 0.25)
        case .transcribing:
            borderColor = NSColor(srgbRed: 0.95, green: 0.42, blue: 0.93, alpha: 0.25)
        case .speaking:
            borderColor = NSColor(srgbRed: 0.40, green: 0.72, blue: 1.0, alpha: 0.22)
        case .thinking:
            borderColor = NSColor(srgbRed: 0.57, green: 0.51, blue: 1.0, alpha: 0.20)
        case .error:
            borderColor = NSColor(srgbRed: 1.0, green: 0.35, blue: 0.42, alpha: 0.32)
        }
        borderLayer.strokeColor = borderColor.cgColor

        let isIdle = phase == .idle
        materialView.alphaValue = 0.76
        tintView.layer?.backgroundColor = NSColor(
            srgbRed: 0.035,
            green: 0.037,
            blue: 0.055,
            alpha: isIdle ? 0.52 : 0.68
        ).cgColor
        updateRecordingControlAvailability()
    }

    func setRecordingControlsAvailable(_ available: Bool) {
        recordingControlsAvailable = available
        updateRecordingControlAvailability()
    }

    private func updateRecordingControlAvailability() {
        let controlsEnabled = visualPhase == .listening && recordingControlsAvailable
        pauseButton.isEnabled = controlsEnabled
        muteButton.isEnabled = controlsEnabled
        pauseButton.alphaValue = controlsEnabled ? 1 : 0.38
        muteButton.alphaValue = controlsEnabled ? 1 : 0.38
    }

    func updateAudioLevel(_ level: Float) {
        waveformView.push(audioLevel: level)
    }

    func resetWaveform() {
        waveformView.reset()
    }

    func setElapsed(_ elapsed: TimeInterval) {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        timerLabel.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func setPaused(_ paused: Bool) {
        pauseButton.setSymbol(
            paused ? "play.fill" : "pause.fill",
            accessibilityLabel: paused ? "Resume recording" : "Pause recording"
        )
        pauseButton.setVisuallyActive(paused)
        waveformView.alphaValue = paused ? 0.28 : 1
    }

    func setMuted(_ muted: Bool) {
        muteButton.setSymbol(
            muted ? "mic.slash.fill" : "mic.fill",
            accessibilityLabel: muted ? "Unmute microphone" : "Mute microphone"
        )
        muteButton.setVisuallyActive(muted)
    }
}
