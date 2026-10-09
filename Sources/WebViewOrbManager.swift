import AppKit
import WebKit

/// WebViewOrbManager — the 3D JARVIS orb overlay.
///
/// Hosts a Three.js gold point-cloud orb (Resources/orb/orb.html) in a fully
/// transparent, borderless, click-through, always-on-top NSPanel. This is the
/// "beautiful" orb path: the gold-particle-sphere look is a shader aesthetic, so
/// we render it in WebGL and push audio level in from Swift (never re-tap the mic).
///
/// Conforms to `RecordingOverlaySurface` so it's a drop-in for the pill / SwiftUI
/// orb managers. Selected when UserDefaults `overlay_style == 2`.
///
/// Transparency is set at all three layers (renderer alpha 0 in orb.html, the
/// WKWebView below, and the NSPanel) — that triple is what kills the "box".
final class WebViewOrbManager: NSObject, RecordingOverlaySurface {

    // MARK: Protocol callbacks (orb ignores both; kept for interface parity)
    var onStopButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?
    var onOrbTapped: (() -> Void)?

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var pageLoaded = false
    private var pendingJS: [String] = []
    private var screenObserver: NSObjectProtocol?

    /// WKScriptMessageHandler name for the orb's ack/error channel (T1).
    private let orbMessageName = "orb"

    /// On-screen size of the orb panel. ~30% smaller than 280 per Shaan; still
    /// has headroom so the orb's audio expansion + glow shells don't clip.
    private let panelSize: CGFloat = 196

    private var alwaysVisible: Bool {
        (UserDefaults.standard.object(forKey: "orb_always_visible") as? Bool) ?? false
    }

    override init() {
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.repositionPanel() }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        animTimer?.invalidate()
        // T1: remove the orb ack/error handler so it can't leak / duplicate (Codex fix).
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: orbMessageName)
    }

    // MARK: - Geometry (anchor reused from OrbAnchor)

    private var targetScreen: NSScreen? {
        let saved = UserDefaults.standard.integer(forKey: "overlay_display_id")
        switch saved {
        case 0:  return NSScreen.main ?? NSScreen.screens.first
        case -1: return NSScreen.screens.first ?? NSScreen.main
        default: return NSScreen.screens.first(where: { Int($0.displayID ?? 0) == saved })
                    ?? NSScreen.screens.first ?? NSScreen.main
        }
    }

    private var orbFrame: NSRect {
        guard let screen = targetScreen else { return .zero }
        let s = panelSize
        let vf = screen.visibleFrame
        // If Shaan has dragged the orb, honor that custom spot over the anchor.
        if UserDefaults.standard.bool(forKey: "orb_pos_custom") {
            let x = CGFloat(UserDefaults.standard.double(forKey: "orb_pos_x"))
            let y = CGFloat(UserDefaults.standard.double(forKey: "orb_pos_y"))
            return NSRect(x: x, y: y, width: s, height: s)
        }
        let inset: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "orb_offset_x") as? Int ?? 24)
        let insetY: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "orb_offset_y") as? Int ?? 24)
        switch OrbAnchor.current {
        case .webcam:
            // Centered below the Mac camera (notch / top-center) — Shaan's pick.
            return NSRect(x: vf.midX - s / 2, y: vf.maxY - s - insetY, width: s, height: s)
        case .topRight:
            return NSRect(x: vf.maxX - s - inset, y: vf.maxY - s - insetY, width: s, height: s)
        case .topLeft:
            return NSRect(x: vf.minX + inset, y: vf.maxY - s - insetY, width: s, height: s)
        case .bottomRight:
            // Visible orb fills ~center 60% of the panel, so the panel's own
            // transparent margin (~20% each side ≈ 39px) already adds to the gap.
            // Shaan: bottom gap is good (~thumbs width), right gap too tight →
            // pull LEFT. Bottom panel edge sits ~10px above screen bottom; right
            // panel edge ~30px in from screen right → visible orb ends up with a
            // comfortable, roughly-even gap on both sides.
            let rightGap: CGFloat = 30
            let bottomGap: CGFloat = 10
            return NSRect(x: screen.frame.maxX - s - rightGap, y: screen.frame.minY + bottomGap, width: s, height: s)
        case .bottomLeft:
            return NSRect(x: vf.minX + inset, y: vf.minY + insetY, width: s, height: s)
        }
    }

    // MARK: - Panel + WebView (all three transparency layers)

    private func ensurePanel() {
        guard panel == nil else { return }

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // T1 ack/error channel: orb.html posts {seq,type:'ack'|'error',msg} back here.
        // Registered on a fresh controller; removed in deinit (avoid leak/duplicate handlers).
        let ucc = WKUserContentController()
        ucc.add(self, name: orbMessageName)
        config.userContentController = ucc
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize), configuration: config)
        // WKWebView is opaque by default — this is the layer everyone forgets.
        wv.setValue(false, forKey: "drawsBackground")
        wv.layer?.backgroundColor = NSColor.clear.cgColor
        wv.navigationDelegate = self
        webView = wv

        if let url = orbHTMLURL() {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelSize, height: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.level = .screenSaver
        // Drag-to-place: the orb accepts mouse events so it can be picked up and
        // moved anywhere. (Trade-off vs pure click-through, but Shaan wants to
        // place it himself.) A pan recognizer moves the panel + persists the spot.
        p.ignoresMouseEvents = false
        // NOTE: do NOT also set isMovableByWindowBackground — it fights the pan
        // recognizer and causes the laggy "moves less than the mouse" feel.
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = wv
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleOrbPan(_:)))
        wv.addGestureRecognizer(pan)
        p.setFrame(orbFrame, display: true)
        panel = p
    }

    // Drag the orb 1:1 with the cursor. Track absolute screen mouse position and
    // the grab offset so the orb follows the pointer exactly (no compounding /
    // no fighting window auto-move). Persist where it's dropped.
    private var dragGrabOffset: CGSize?
    @objc private func handleOrbPan(_ g: NSPanGestureRecognizer) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation   // absolute screen coords (bottom-left origin)
        switch g.state {
        case .began:
            // Offset from the panel's origin to where the cursor grabbed it.
            dragGrabOffset = CGSize(width: mouse.x - panel.frame.origin.x,
                                    height: mouse.y - panel.frame.origin.y)
        case .changed:
            let off = dragGrabOffset ?? .zero
            panel.setFrameOrigin(NSPoint(x: mouse.x - off.width, y: mouse.y - off.height))
        case .ended, .cancelled:
            let o = panel.frame.origin
            UserDefaults.standard.set(Double(o.x), forKey: "orb_pos_x")
            UserDefaults.standard.set(Double(o.y), forKey: "orb_pos_y")
            UserDefaults.standard.set(true, forKey: "orb_pos_custom")
            dragGrabOffset = nil
        default:
            break
        }
    }

    private func orbHTMLURL() -> URL? {
        // Resources/orb/orb.html — copied into the app bundle Resources by the Makefile.
        if let bundled = Bundle.main.url(forResource: "orb", withExtension: "html", subdirectory: "orb") {
            return bundled
        }
        if let bundled = Bundle.main.url(forResource: "orb", withExtension: "html") {
            return bundled
        }
        return nil
    }

    private func showPanel() {
        ensurePanel()
        panel?.setFrame(orbFrame, display: true)
        panel?.orderFrontRegardless()
        pushVisibility(true)
        startAnimClock()       // Swift drives the animation (WKWebView suspends rAF when occluded)
    }

    private func repositionPanel() {
        guard let panel else { return }
        panel.setFrame(orbFrame, display: true)
    }

    // MARK: - Animation clock
    //
    // WKWebView SUSPENDS requestAnimationFrame when its view is occluded / the window
    // isn't active — which is ALWAYS true for our borderless non-activating overlay
    // panel. That froze the orb in the live app (rAF fired once then stopped). So Swift
    // is the clock: a ~30fps timer calls the orb's deterministic step(dt) over the
    // bridge. The orb's internal rAF loop stays as a harmless fallback. Started when the
    // panel is shown, stopped when hidden (battery-safe — replaces the bad idle-throttle).
    private var animTimer: Timer?
    private func startAnimClock() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.runJS("window.__orb && window.__orb.step(33)")
        }
        RunLoop.main.add(t, forMode: .common)   // .common so it ticks during drags/menus
        animTimer = t
    }
    private func stopAnimClock() { animTimer?.invalidate(); animTimer = nil }

    // MARK: - JS bridge

    private func runJS(_ js: String) {
        guard pageLoaded, let webView else { pendingJS.append(js); return }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // T1 typed bus: every push goes through the single __orbDispatch inbox with a
    // monotonic seq (orb.html drops stale state + queues transient events). All of
    // T4/T5 call THESE narrow methods — they never edit this manager's structure.
    private var orbSeq: Int = 0
    private func dispatch(_ type: String, payloadJSON: String = "{}") {
        orbSeq += 1
        let msg = "{seq:\(orbSeq),type:'\(type)',payload:\(payloadJSON),ts:0}"
        runJS("window.__orbDispatch && window.__orbDispatch(\(msg))")
    }

    /// Set a phase via the typed bus (back-compat shim still exists in orb.html).
    private func setPhase(_ phase: String) {
        dispatch("setState", payloadJSON: "{phase:'\(phase)'}")
    }

    /// Fire a transient one-shot event (ingest burst, flare, strike). T5 uses this.
    /// `extraJSON` is optional comma-prefixed fields, e.g. ",amp:0.8,ttl:1.5".
    func pushOrbEvent(_ name: String, extraJSON: String = "") {
        dispatch("event", payloadJSON: "{type:'\(name)'\(extraJSON)}")
    }

    /// Tell the orb whether it's visible (T4 pauses the render loop when hidden).
    func pushVisibility(_ visible: Bool) {
        dispatch("setState", payloadJSON: "{visible:\(visible)}")
    }

    // MARK: - RecordingOverlaySurface

    func showInitializing(mode: RecordingTriggerMode, isCommandMode: Bool) {
        DispatchQueue.main.async { self.showPanel(); self.setPhase("listening") }
    }

    func showRecording(mode: RecordingTriggerMode, isCommandMode: Bool) {
        DispatchQueue.main.async { self.showPanel(); self.setPhase("listening") }
    }

    func transitionToRecording(mode: RecordingTriggerMode, isCommandMode: Bool) {
        DispatchQueue.main.async { self.showPanel(); self.setPhase("listening") }
    }

    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool) { /* no-op */ }

    func updateAudioLevel(_ level: Float) {
        let clamped = max(0, min(1, level))
        runJS("window.setAudioLevel && window.setAudioLevel(\(clamped))")
    }

    // T5: track the transcribing→done transition so dismiss() can fire an ingest burst
    // (the transcript "lands" into the orb). Behind the manager only; no god-file edits.
    private var wasTranscribing = false

    func showTranscribing() {
        DispatchQueue.main.async { self.showPanel(); self.wasTranscribing = true; self.setPhase("transcribing") }
    }

    func showFailureIndicator() {
        DispatchQueue.main.async { self.showPanel(); self.setPhase("error") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.resolveAfterError()
        }
    }

    func showError(_ message: String) { showFailureIndicator() }

    func showUpdateAvailable(version: String) { /* ignored; orb stays idle */ }

    func dismiss() {
        DispatchQueue.main.async {
            // T5: if we were transcribing, the transcript just landed → fire an INWARD
            // ingest burst (absorption) before settling to idle.
            if self.wasTranscribing {
                self.wasTranscribing = false
                self.pushOrbEvent("memory_save", extraJSON: ",amp:1.0,ttl:1.2")
            }
            if self.alwaysVisible {
                self.showPanel()
                self.setPhase("idle")
            } else {
                self.setPhase("idle")
                self.pushVisibility(false)
                self.stopAnimClock()         // stop the Swift clock when hidden (battery)
                self.panel?.orderOut(nil)
            }
        }
    }

    private func resolveAfterError() {
        if alwaysVisible {
            setPhase("idle")
        } else {
            pushVisibility(false)
            stopAnimClock()
            panel?.orderOut(nil)
        }
    }
}

extension WebViewOrbManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        let queued = pendingJS
        pendingJS.removeAll()
        for js in queued { webView.evaluateJavaScript(js, completionHandler: nil) }
        setPhase("idle")
        // Start the animation clock the moment the page is live, regardless of which
        // show-path ran first. (Path-independent — fixes the orb staying frozen at boot.)
        startAnimClock()
    }
}

// T1 ack/error channel: orb.html posts {seq, type:'ack'|'error', msg} here. We only
// log errors (the orb degrades to its CSS fallback on its own). Handler is removed in deinit.
extension WebViewOrbManager: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == orbMessageName,
              let body = message.body as? [String: Any] else { return }
        if (body["type"] as? String) == "error" {
            NSLog("[orb] error: \(body["msg"] ?? "?")")
        }
    }
}
