import AppKit
import CoreGraphics

/// BackgroundSampler — reads the screen pixels DIRECTLY BEHIND the orb panel and reports their
/// average luminance (0 = black bg, 1 = white bg). This drives the orb's background-awareness:
/// over a light background the orb fades in a subtle dark backing disc so its additive glow has
/// something to sit on; over a dark background the backing stays fully transparent.
///
/// Capture uses CGWindowListCreateImage with `.optionOnScreenBelowWindow` keyed on the orb's own
/// window number, so it grabs ONLY what's underneath the orb — the orb never samples itself (no
/// feedback loop). Same API the app already uses in AppContextService; TCC screen-recording grant
/// is shared. Runs on a background queue, throttled; the renderer reads the last value lock-free-ish
/// via an atomic Float behind a tiny lock.
final class BackgroundSampler {

    /// Latest average luminance behind the orb, 0...1. Read by the renderer each frame.
    var luminance: Float {
        lock.lock(); defer { lock.unlock() }
        return _luminance
    }

    private var _luminance: Float = 0
    private let lock = NSLock()

    /// Closure the sampler calls to learn the orb's current screen rect + window number.
    /// (origin in screen points, bottom-left; windowNumber for below-window capture.)
    private let frameProvider: () -> (rect: CGRect, windowNumber: Int)?

    /// Called on the MAIN queue after each sample with the new smoothed luminance (0…1).
    var onUpdate: ((Float) -> Void)?

    private let queue = DispatchQueue(label: "com.siso.voice.bgsampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let intervalMs: Int
    private var paused = false

    // 500ms (was 150ms): each tick does a CGWindowListCreateImage screen capture, which is
    // expensive (window-server round-trip + decode). The backing-disc luminance only needs to
    // track slow background changes (scrolling onto a light page), so 2/sec is plenty and cuts
    // the capture rate ~3×. Combined with pausing while the orb is hidden/idle (setPaused),
    // this is the dominant fix for the orb's idle CPU burn.
    init(intervalMs: Int = 500, frameProvider: @escaping () -> (rect: CGRect, windowNumber: Int)?) {
        self.intervalMs = intervalMs
        self.frameProvider = frameProvider
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(intervalMs),
                   repeating: .milliseconds(intervalMs), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self, !self.paused else { return }
            self.sampleOnce()
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Suspend/resume sampling without tearing down the timer. The renderer calls this so the
    /// expensive screen capture stops entirely while the orb is hidden or its render loop is
    /// paused — there is no backing disc to drive when nothing is on screen. Cheaper and safer
    /// than start/stop churn (no timer reallocation, no missed-resume races).
    func setPaused(_ value: Bool) {
        queue.async { [weak self] in self?.paused = value }
    }

    private func sampleOnce() {
        // Without Screen Recording permission, CGWindowListCreateImage still "succeeds" but returns
        // a blank/desktop-only image (and the OS logs "Failed capture in SLWindowListCreateImage"
        // every call). A blank image reads as luminance 0 — indistinguishable from a real black
        // screen — so failure-counting can't catch it. Preflight the permission instead: if it's
        // not granted, this feature can never work, so stop the timer entirely. This is the same
        // gate AppContextService already uses for its screenshot capture.
        guard CGPreflightScreenCaptureAccess() else {
            timer?.cancel()
            timer = nil
            return
        }

        guard let info = frameProvider() else { return }
        let rect = info.rect
        guard rect.width > 1, rect.height > 1 else { return }

        // Capture only what is on screen BELOW the orb window → excludes the orb itself.
        // CGWindowListCreateImage takes a rect in flipped (top-left origin) global display space;
        // NSWindow.frame is bottom-left origin. Convert against the primary screen height.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let flipped = CGRect(x: rect.origin.x,
                             y: primaryHeight - rect.origin.y - rect.height,
                             width: rect.width, height: rect.height)

        guard let image = CGWindowListCreateImage(
            flipped,
            .optionOnScreenBelowWindow,
            CGWindowID(info.windowNumber),
            [.nominalResolution, .boundsIgnoreFraming]
        ) else { return }

        let lum = Self.averageLuminance(of: image)
        guard lum >= 0 else { return }   // capture produced no usable pixels; keep last value

        lock.lock()
        // Smooth so a fast scroll across a light/dark boundary doesn't make the backing flicker.
        _luminance += (lum - _luminance) * 0.35
        let smoothed = _luminance
        lock.unlock()

        if let cb = onUpdate {
            DispatchQueue.main.async { cb(smoothed) }
        }
    }

    /// Downscale the capture to a small box and average perceived luminance. Returns -1 on failure.
    private static func averageLuminance(of image: CGImage) -> Float {
        let w = 8, h = 8
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var acc: Float = 0
        let count = w * h
        for i in 0..<count {
            let o = i * 4
            let r = Float(pixels[o]) / 255
            let g = Float(pixels[o + 1]) / 255
            let b = Float(pixels[o + 2]) / 255
            acc += 0.299 * r + 0.587 * g + 0.114 * b
        }
        return acc / Float(count)
    }
}
