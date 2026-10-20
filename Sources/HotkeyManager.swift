import Cocoa

final class HotkeyManager {
    private let backend = GlobalShortcutBackend()
    private var configuration = ShortcutConfiguration(
        hold: .defaultHold,
        toggle: .defaultToggle
    )
    private var inputState = ShortcutInputState()

    var onShortcutEvent: ((ShortcutEvent) -> Void)?
    var onEscapeKeyPressed: (() -> Bool)?
    var onUndoDictation: (() -> Void)?
    private var undoKeyDown = false

    var currentPressedModifiers: ShortcutModifiers {
        inputState.currentModifiers
    }

    var hasPressedShortcutInputs: Bool {
        inputState.hasPressedShortcutInputs(configuration: configuration)
    }

    func start(configuration: ShortcutConfiguration) throws {
        stop()
        self.configuration = configuration
        backend.onInputEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? .passthrough
        }
        backend.onEscapeKeyPressed = { [weak self] in
            self?.onEscapeKeyPressed?() ?? false
        }
        do {
            try backend.start()
        } catch {
            backend.onInputEvent = nil
            backend.onEscapeKeyPressed = nil
            inputState = ShortcutInputState()
            throw error
        }
    }

    func stop() {
        backend.stop()
        backend.onInputEvent = nil
        backend.onEscapeKeyPressed = nil
        inputState = ShortcutInputState()
        undoKeyDown = false
    }

    deinit {
        stop()
    }

    private func handleInputEvent(_ event: ShortcutInputEvent) -> ShortcutConsumeDecision {
        if case .keyChanged(let keyCode, let isDown, let isRepeat) = event, keyCode == 6 {
            if undoKeyDown {
                if !isDown { undoKeyDown = false }
                return .consume
            }
            let reservedByConfiguration = [configuration.hold, configuration.toggle, configuration.copyAgain].contains {
                $0.kind == .key && $0.keyCode == keyCode && $0.modifiers == [.command, .option]
            }
            if isDown, !isRepeat, !reservedByConfiguration, inputState.currentModifiers == [.command, .option] {
                undoKeyDown = true
                onUndoDictation?()
                return .consume
            }
        }
        let result = ShortcutMatcher.reduce(
            state: inputState,
            event: event,
            configuration: configuration
        )
        inputState = result.state
        for event in result.emittedEvents {
            onShortcutEvent?(event)
        }
        return result.consumeDecision
    }
}
