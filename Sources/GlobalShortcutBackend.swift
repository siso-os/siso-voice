import Cocoa
import os.log

private let shortcutLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Shortcuts")

enum GlobalShortcutBackendError: LocalizedError {
    case eventTapUnavailable
    case eventTapRunLoopSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            return "Global shortcut monitoring could not start. \(AppName.displayName) requires keyboard monitoring permission for global shortcuts."
        case .eventTapRunLoopSourceUnavailable:
            return "Global shortcut monitoring could not start because the event tap run loop source could not be created."
        }
    }
}

final class GlobalShortcutBackend {
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var fnKeyIsDown = false
    private var watchdogTimer: Timer?

    var onInputEvent: ((ShortcutInputEvent) -> ShortcutConsumeDecision)?
    var onEscapeKeyPressed: (() -> Bool)?

    func start() throws {
        stop()
        try installEventTap()
        // Trusted physical-Fn state is authored ONLY by real Fn flagsChanged events
        // (handleFlagsChanged) and cleared on reset. Do NOT seed it from the live global
        // `.function` flag here: that flag is raised by macOS for arrow/F/nav keys, the
        // globe/dictation gesture, and other apps' Fn use, so seeding from it can latch
        // fnKeyIsDown TRUE with no physical Fn held — after which every keyDown re-inserts
        // Fn into the pressed set and spuriously fires the Fn hold shortcut ("orb activates
        // when I'm typing, not when I press Fn"). Start conservatively down; the next real
        // Fn press re-arms it correctly.
        fnKeyIsDown = false
        startWatchdog()
    }

    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        tearDownEventTap()
        notifyBackendReset()
    }

    /// macOS disables a session event tap on timeout/user-input by delivering ONE
    /// disabled event to the callback (handled in handleEventTap). But if the run loop
    /// is momentarily busy and misses servicing that event, the tap stays dead with no
    /// further events to trigger re-enable — the "push-to-talk worked once then went
    /// permanently deaf" bug. This watchdog independently polls the tap's enabled state
    /// and re-arms it (or fully reinstalls if the port was invalidated), so recovery
    /// never depends on the dead callback firing.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.ensureTapEnabled()
        }
        // .common so it keeps firing during menu tracking / modal run-loop modes.
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func ensureTapEnabled() {
        // This 2s watchdog re-arms the tap after macOS disables it (common under heavy
        // input). NEVER re-seed fnKeyIsDown from the live `.function` flag here — that
        // silently latches it TRUE whenever the ambient flag happens to be raised (arrow
        // keys, globe gesture, other apps), and every keyDown after that re-inserts Fn
        // into the pressed set → phantom Fn hold. Clear to false on re-arm; a genuine Fn
        // flagsChanged sets it back the instant the user actually holds Fn.
        guard let tap = eventTap else {
            // Port was lost entirely — reinstall from scratch.
            try? installEventTap()
            fnKeyIsDown = false
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            fnKeyIsDown = false
            // If re-enabling didn't take (port invalidated), rebuild it.
            if !CGEvent.tapIsEnabled(tap: tap) {
                tearDownEventTap()
                try? installEventTap()
                fnKeyIsDown = false
            }
        }
    }

    deinit {
        stop()
    }

    private func installEventTap() throws {
        let eventMask = [
            CGEventType.flagsChanged,
            CGEventType.keyDown,
            CGEventType.keyUp
        ].reduce(CGEventMask(0)) { partialResult, eventType in
            partialResult | (CGEventMask(1) << eventType.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let backend = Unmanaged<GlobalShortcutBackend>.fromOpaque(userInfo).takeUnretainedValue()
            return backend.handleEventTap(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            os_log(.error, log: shortcutLog, "Failed to install global shortcut event tap")
            throw GlobalShortcutBackendError.eventTapUnavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            os_log(.error, log: shortcutLog, "Failed to create run loop source for global shortcut event tap")
            throw GlobalShortcutBackendError.eventTapRunLoopSourceUnavailable
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        eventTapRunLoopSource = source
    }

    private func tearDownEventTap() {
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTapRunLoopSource = nil
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
    }

    private func notifyBackendReset() {
        fnKeyIsDown = false
        _ = onInputEvent?(.backendReset)
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            notifyBackendReset()
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                // Leave fnKeyIsDown cleared by notifyBackendReset(); do not re-seed from
                // the ambient `.function` flag (it latches a phantom Fn hold — see start()).
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged, .keyDown, .keyUp:
            guard let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }

            let shouldConsume: Bool
            switch type {
            case .flagsChanged:
                shouldConsume = handleFlagsChanged(nsEvent)
            case .keyDown:
                shouldConsume = handleKeyDown(nsEvent)
            case .keyUp:
                shouldConsume = handleKeyUp(nsEvent)
            default:
                shouldConsume = false
            }

            return shouldConsume ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        guard ShortcutBinding.modifierKeyCodes.contains(event.keyCode),
              let isDown = ModifierKeyEventState.isKeyDown(for: event) else {
            return false
        }

        if event.keyCode == ModifierKeyEventState.fnKeyCode {
            fnKeyIsDown = isDown
        }

        return onInputEvent?(.modifierChanged(keyCode: event.keyCode, isDown: isDown)) == .consume
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            guard !event.isARepeat else { return false }
            return onEscapeKeyPressed?() ?? false
        }

        guard !ShortcutBinding.modifierKeyCodes.contains(event.keyCode) else { return false }
        let snapshotDecision = onInputEvent?(
            .modifierSnapshot(ModifierKeyEventState.pressedModifierKeyCodes(
                for: event,
                trustedFunctionKeyIsDown: fnKeyIsDown
            ))
        ) ?? .passthrough
        let keyDecision = onInputEvent?(
            .keyChanged(keyCode: event.keyCode, isDown: true, isRepeat: event.isARepeat)
        ) ?? .passthrough
        return snapshotDecision == .consume || keyDecision == .consume
    }

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard !ShortcutBinding.modifierKeyCodes.contains(event.keyCode) else { return false }
        let snapshotDecision = onInputEvent?(
            .modifierSnapshot(ModifierKeyEventState.pressedModifierKeyCodes(
                for: event,
                trustedFunctionKeyIsDown: fnKeyIsDown
            ))
        ) ?? .passthrough
        let keyDecision = onInputEvent?(
            .keyChanged(keyCode: event.keyCode, isDown: false, isRepeat: false)
        ) ?? .passthrough
        return snapshotDecision == .consume || keyDecision == .consume
    }
}
