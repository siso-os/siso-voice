import AppKit
import OSLog
import WebKit

private let edgeDockLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.siso.voice", category: "EdgeDock")

// MARK: - DockTab

/// The two destinations the dock can show, as in-panel tabs.
enum DockTab: Int {
    case internalWeb = 0
    case jarvis      = 1
}

// MARK: - EdgeDockController
//
// System-wide right-edge dock: a thin 7pt bar that hovers at the RIGHT screen
// edge, vertically centered (~100pt tall). Mouse-enter expands it into a slim
// flyout with two ICONS: SISO Internal (server) and JARVIS (chat bubble). Click
// either to open ONE draggable floating panel with an in-panel segmented tab bar
// (Internal | JARVIS), pre-selected to the tapped destination. Mouse-leave (with
// delay) collapses the bar back.
//
// This is the single right-edge surface — the old per-destination floating chips
// (SidebarDrawerManager) were removed.
//
// Controlled by UserDefaults "edge_dock_enabled" (default true).
// Internal URL: UserDefaults "edge_dock_internal_url" (default = lifelock mac-mini).
//
// All NSPanel work is on the main thread (@MainActor on the class).
//

@MainActor
final class EdgeDockController: NSObject {

    // MARK: - Tunables
    private enum K {
        // Idle: a slim clean bar with a single subtle dot — NO icons until hover.
        // Hover: widens into a flyout that reveals the two icons.
        static let barWidth:      CGFloat = 8    // idle: slim bar
        static let barHeight:     CGFloat = 96
        static let flyoutWidth:   CGFloat = 44   // hovered: room for the icons
        static let flyoutHeight:  CGFloat = 132
        static let edgeInset:     CGFloat = 5    // float just off the screen edge, not flush
        static let collapseDelay: TimeInterval = 0.45
        static let animDuration:  TimeInterval = 0.22
        static let panelWidth:    CGFloat = 480
        static let panelHeight:   CGFloat = 640
        static let chromeHeight:  CGFloat = 40
        static let defaultInternalURL = "https://shaans-mac-mini.tail100d11.ts.net/admin/lifelock/daily?section=plan&subtab=morning"
        static let defaultsKeyEnabled     = "edge_dock_enabled"
        static let defaultsKeyInternalURL = "edge_dock_internal_url"
        static let autosavePanel = "EdgeDockPanel"
    }

    // MARK: - State
    private var barPanel: SISOEdgeDockBarPanel?
    private var barView: SISOEdgeDockBarView?

    // Single tabbed panel (replaces the old separate jarvis/internal panels).
    private var dockPanel: SISOEdgeDockFloatingPanel?
    private var dockChrome: EdgeDockTabChrome?
    private var dockBodyContainer: NSView?
    private var internalWebView: WKWebView?      // cached — built once, kept across tab switches
    private var jarvisChatView: SISODrawerAgentChatView?  // cached — keeps scrollback
    private var currentTab: DockTab = .internalWeb

    private var collapseWorkItem: DispatchWorkItem?
    private var isExpanded = false

    private var screenObserver: NSObjectProtocol?

    // MARK: - Public lifecycle

    /// Call once from AppDelegate after setup completes.
    func start() {
        // Register default so absent key reads as true (bool(forKey:) returns false for missing keys).
        UserDefaults.standard.register(defaults: [K.defaultsKeyEnabled: true])
        guard isEnabled else { return }
        buildBar()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.repositionBar() }
    }

    /// Tear down (e.g. when toggle is disabled at runtime).
    func stop() {
        barPanel?.orderOut(nil)
        barPanel = nil
        barView = nil
        collapseWorkItem?.cancel()
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
    }

    /// Toggle on/off at runtime (called from Settings).
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: K.defaultsKeyEnabled)
        if on {
            if barPanel == nil { start() }
        } else {
            stop()
        }
    }

    var isEnabled: Bool {
        let d = UserDefaults.standard
        return (d.object(forKey: K.defaultsKeyEnabled) as? Bool) ?? true
    }

    // MARK: - Bar construction

    private func buildBar() {
        let frame = barFrame(expanded: false)
        let panel = SISOEdgeDockBarPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true   // subtle lift so the rail reads as floating, not painted-on
        panel.level = .statusBar // sit above terminal/other floating windows so it's always seen
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true

        let view = SISOEdgeDockBarView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]   // fill the panel as it animates wider, so hit-rects stay correct
        view.onHoverEnter = { [weak self] in self?.expand() }
        view.onHoverExit  = { [weak self] in self?.scheduleCollapse() }
        view.onCancelCollapse = { [weak self] in self?.cancelCollapse() }
        view.onInternalTapped = { [weak self] in self?.openDock(tab: .internalWeb) }
        view.onJarvisTapped   = { [weak self] in self?.openDock(tab: .jarvis) }

        panel.contentView = view
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()

        os_log(.info, log: edgeDockLog, "EdgeDock bar window created — frame: x=%.1f y=%.1f w=%.1f h=%.1f",
               frame.origin.x, frame.origin.y, frame.size.width, frame.size.height)

        barPanel = panel
        barView = view
    }

    // MARK: - Expand / collapse

    private func expand() {
        cancelCollapse()
        guard !isExpanded else { return }
        isExpanded = true
        barView?.setExpanded(true, animated: true)
        animateBarToFrame(barFrame(expanded: true))
    }

    private func scheduleCollapse() {
        cancelCollapse()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + K.collapseDelay, execute: work)
    }

    private func cancelCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    private func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        barView?.setExpanded(false, animated: true)
        animateBarToFrame(barFrame(expanded: false))
    }

    private func animateBarToFrame(_ target: NSRect) {
        guard let panel = barPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = K.animDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            // After the bar finishes resizing, rebuild the hover tracking area against
            // the FINAL bounds. AppKit doesn't do this for animator-driven frame
            // changes, so without it mouseExited can stop firing and the bar gets
            // stuck expanded — clicks then land in a dead zone until app refresh.
            self?.barView?.rebuildTrackingArea()
        })
    }

    // MARK: - Dock panel (single, tabbed)

    /// Open the dock panel on the given tab. If the panel is already front on the
    /// SAME tab, this toggles it closed (matching the old drawer's toggle feel).
    /// Otherwise it opens / raises and switches to the requested tab.
    func openDock(tab: DockTab) {
        scheduleCollapse()

        // Toggle: same tab already visible → close.
        if let p = dockPanel, p.isVisible, currentTab == tab {
            p.orderOut(nil)
            return
        }

        ensureDockPanel()
        guard let p = dockPanel else { return }
        selectTab(tab)
        restoreOrCenterPanel(p)
        p.makeKeyAndOrderFront(nil)
    }

    private func ensureDockPanel() {
        guard dockPanel == nil else { return }

        let panel = SISOEdgeDockFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: K.panelWidth, height: K.panelHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        panel.isOpaque = true
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.setFrameAutosaveName(K.autosavePanel)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: K.panelWidth, height: K.panelHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        container.layer?.cornerRadius = 12

        // Tab chrome row across the top.
        let chrome = EdgeDockTabChrome(frame: NSRect(x: 0, y: K.panelHeight - K.chromeHeight, width: K.panelWidth, height: K.chromeHeight))
        chrome.autoresizingMask = [.width, .minYMargin]
        chrome.onSelect = { [weak self] tab in self?.selectTab(tab) }
        chrome.onClose  = { [weak panel] in panel?.orderOut(nil) }

        // Body container holds whichever tab's view is active.
        let body = NSView(frame: NSRect(x: 0, y: 0, width: K.panelWidth, height: K.panelHeight - K.chromeHeight))
        body.autoresizingMask = [.width, .height]

        container.addSubview(body)
        container.addSubview(chrome)
        panel.contentView = container

        dockPanel = panel
        dockChrome = chrome
        dockBodyContainer = body
    }

    /// Switch the active tab: build its body lazily (cached), swap it into the body
    /// container, and update the segmented control selection.
    private func selectTab(_ tab: DockTab) {
        guard let body = dockBodyContainer else { return }
        currentTab = tab
        dockChrome?.setSelected(tab)

        let view = bodyView(for: tab)
        if view.superview !== body {
            body.subviews.forEach { $0.removeFromSuperview() }
            view.frame = body.bounds
            view.autoresizingMask = [.width, .height]
            body.addSubview(view)
        }

        if tab == .jarvis { jarvisChatView?.loadConversationHistory() }
    }

    /// Lazily build + cache the body view for a tab. Built once, reused across
    /// switches so the web session and chat scrollback persist.
    private func bodyView(for tab: DockTab) -> NSView {
        switch tab {
        case .internalWeb:
            if let wv = internalWebView { return wv }
            let rawURL = UserDefaults.standard.string(forKey: K.defaultsKeyInternalURL) ?? K.defaultInternalURL
            let url = URL(string: rawURL) ?? URL(string: K.defaultInternalURL)!
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: K.panelWidth, height: K.panelHeight - K.chromeHeight))
            wv.load(URLRequest(url: url))
            wv.wantsLayer = true
            wv.layer?.cornerRadius = 12
            wv.layer?.masksToBounds = true
            internalWebView = wv
            return wv

        case .jarvis:
            if let chat = jarvisChatView { return chat }
            let chat = SISODrawerAgentChatView(frame: NSRect(x: 0, y: 0, width: K.panelWidth, height: K.panelHeight - K.chromeHeight))
            jarvisChatView = chat
            return chat
        }
    }

    private func restoreOrCenterPanel(_ panel: NSWindow) {
        // setFrameAutosaveName handles persistence; only center on first appearance
        // (when the autosaved frame is NSZeroRect / hasn't been set yet).
        if panel.frame.origin == .zero {
            panel.center()
        }
        panel.orderFrontRegardless()
    }

    // MARK: - Geometry

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func barFrame(expanded: Bool) -> NSRect {
        guard let screen = targetScreen() else {
            return NSRect(x: 0, y: 0, width: expanded ? K.flyoutWidth : K.barWidth, height: K.barHeight)
        }
        let vf = screen.visibleFrame   // respect menu bar / dock so the rail is never clipped
        let w: CGFloat = expanded ? K.flyoutWidth : K.barWidth
        let h: CGFloat = expanded ? K.flyoutHeight : K.barHeight
        let x = vf.maxX - w - K.edgeInset  // float just inside the right edge, not flush
        let y = vf.midY - h / 2
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func repositionBar() {
        guard let panel = barPanel else { return }
        panel.setFrame(barFrame(expanded: isExpanded), display: true)
    }
}

// MARK: - SISOEdgeDockBarPanel

final class SISOEdgeDockBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - SISOEdgeDockFloatingPanel

final class SISOEdgeDockFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - SISOEdgeDockBarView
//
// The actual visual bar. Draws as a thin dark rounded pill normally; expands
// to show two SF Symbol icons (Internal / JARVIS) when hovered. Uses an
// NSTrackingArea for hover detection. Mouse events trigger the callbacks so
// EdgeDockController stays in charge of animation timing.
//

final class SISOEdgeDockBarView: NSView {
    // Callbacks
    var onHoverEnter:    (() -> Void)?
    var onHoverExit:     (() -> Void)?
    var onCancelCollapse: (() -> Void)?
    var onInternalTapped: (() -> Void)?
    var onJarvisTapped:  (() -> Void)?

    private var expanded = false
    private var tracking: NSTrackingArea?
    private var hoveringInternal = false
    private var hoveringJarvis = false

    // SF Symbols for the two destinations.
    private static let internalSymbol = "server.rack"
    private static let jarvisSymbol   = "bubble.left.and.bubble.right"

    override var isFlipped: Bool { true }

    // The bar lives on a non-activating panel and is clicked while another app (terminal/
    // browser) is focused. Without this, macOS eats the FIRST click just to surface the
    // panel and the icon tap never fires — the "buttons don't work" bug.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        onCancelCollapse?()
        onHoverEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        hoveringInternal = false
        hoveringJarvis = false
        needsDisplay = true
        onHoverExit?()
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let (ir, jr) = iconRects()
        let wasI = hoveringInternal, wasJ = hoveringJarvis
        // Icons only exist when expanded, so per-icon hot state only tracks then.
        hoveringInternal = expanded && ir.contains(pt)
        hoveringJarvis   = expanded && jr.contains(pt)
        if wasI != hoveringInternal || wasJ != hoveringJarvis { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        // Top half → Internal, bottom half → JARVIS. This holds whether the bar is
        // slim or expanded (the two icon rects ARE the two halves), so we route by
        // position unconditionally. Never `return` into a dead zone on a missed icon:
        // if a stale tracking area ever left `expanded` stuck true, an in-bounds click
        // must still do something — otherwise the bar feels frozen until app refresh.
        if pt.y < bounds.height / 2 { onInternalTapped?() } else { onJarvisTapped?() }
    }

    func setExpanded(_ on: Bool, animated: Bool) {
        expanded = on
        needsDisplay = true
    }

    /// Rebuild the hover tracking area against current bounds. Called by the
    /// controller once the bar's resize animation completes — AppKit won't re-run
    /// updateTrackingAreas for animator-driven frame changes, so the hover rect
    /// would otherwise stay sized to the old bounds and mouseExited could stop
    /// firing, leaving the bar stuck expanded.
    func rebuildTrackingArea() {
        updateTrackingAreas()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if !expanded {
            // IDLE: a slim clean bar with a single subtle dot. No icons.
            let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
            let bar = NSBezierPath(roundedRect: inset, xRadius: inset.width / 2, yRadius: inset.width / 2)
            NSColor(calibratedWhite: 0.20, alpha: 0.55).setFill()
            bar.fill()

            // Centered dot — the "clean notification" indicator.
            let dotSize: CGFloat = 5
            let dot = NSRect(
                x: bounds.midX - dotSize / 2,
                y: bounds.midY - dotSize / 2,
                width: dotSize, height: dotSize
            )
            NSColor(calibratedWhite: 0.95, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return
        }

        // HOVERED: a clean rounded card revealing the two icons.
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        let card = NSBezierPath(roundedRect: inset, xRadius: 13, yRadius: 13)
        NSColor(calibratedWhite: 0.12, alpha: 0.97).setFill()
        card.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
        card.lineWidth = 1
        card.stroke()

        let (ir, jr) = iconRects()
        drawIcon(Self.internalSymbol, in: ir, hot: hoveringInternal)
        drawIcon(Self.jarvisSymbol,   in: jr, hot: hoveringJarvis)
    }

    /// Draw a white-tinted SF Symbol centered in `rect`. Reuses the tinted
    /// template-image pattern from the old SISODrawerChipView.
    private func drawIcon(_ symbolName: String, in rect: NSRect, hot: Bool) {
        guard let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: symbolName
        ) else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: hot ? .semibold : .regular)
        let img = symbol.withSymbolConfiguration(config) ?? symbol
        img.isTemplate = true

        let tint = hot
            ? NSColor(calibratedWhite: 1.0, alpha: 1)
            : NSColor(calibratedWhite: 0.78, alpha: 1)

        let tinted = NSImage(size: img.size, flipped: false) { drawRect in
            tint.set()
            img.draw(in: drawRect)
            drawRect.fill(using: .sourceAtop)
            return true
        }

        let size = tinted.size
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    // Half-height rects for the two icon rows (isFlipped = top-down).
    private func iconRects() -> (NSRect, NSRect) {
        let half = bounds.height / 2
        let internalRect = NSRect(x: 0, y: 0,    width: bounds.width, height: half)
        let jarvisRect   = NSRect(x: 0, y: half, width: bounds.width, height: half)
        return (internalRect, jarvisRect)
    }
}

// MARK: - EdgeDockTabChrome (AppKit)
//
// Slim titlebar row for the dock panel: a segmented control (Internal | JARVIS)
// on the left + a ghost close button on the right. Hand-rolled AppKit to match
// the rest of the dock (no SwiftUI).
//

final class EdgeDockTabChrome: NSView {
    var onSelect: ((DockTab) -> Void)?
    var onClose: (() -> Void)?

    private let segmented = NSSegmentedControl()
    private let closeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        segmented.segmentStyle = .texturedRounded
        segmented.trackingMode = .selectOne
        segmented.segmentCount = 2
        segmented.setLabel("Internal", forSegment: 0)
        segmented.setLabel("JARVIS", forSegment: 1)
        segmented.setImage(NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Internal"), forSegment: 0)
        segmented.setImage(NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "JARVIS"), forSegment: 1)
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(segmentChanged(_:))
        segmented.translatesAutoresizingMaskIntoConstraints = false

        closeButton.title = "✕"
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        closeButton.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        closeButton.target = self
        closeButton.action = #selector(closeTapped(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(segmented)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            segmented.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    func setSelected(_ tab: DockTab) {
        segmented.selectedSegment = tab.rawValue
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        guard let tab = DockTab(rawValue: sender.selectedSegment) else { return }
        onSelect?(tab)
    }

    @objc private func closeTapped(_ sender: NSButton) {
        onClose?()
    }
}
