import AppKit
import ApplicationServices

@MainActor
final class DictationUndoController {
    static let shared = DictationUndoController()

    private struct Insertion {
        let text: String
        let targetPID: pid_t
        let focusedElement: AXUIElement
        let originalValue: String
        let originalRange: CFRange
        let expectedValue: String
        let expectedCaret: Int
        let recordedAt: Date
    }

    private var insertion: Insertion?
    private let lifetime: TimeInterval = 120

    private init() {}

    /// Call immediately before inserting text into the target app.
    func recordInsertion(text: String, targetPID: pid_t) {
        guard !text.isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            insertion = nil
            return
        }

        let app = AXUIElementCreateApplication(targetPID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = copyElement(app, attribute: kAXFocusedUIElementAttribute as CFString),
              let value = copyString(focused, attribute: kAXValueAttribute as CFString),
              let range = copyRange(focused, attribute: kAXSelectedTextRangeAttribute as CFString),
              range.location >= 0,
              range.length >= 0 else {
            insertion = nil
            return
        }

        let nsValue = value as NSString
        let selected = NSRange(location: range.location, length: range.length)
        guard NSMaxRange(selected) <= nsValue.length else {
            insertion = nil
            return
        }
        let inserted = text as NSString
        let expected = nsValue.replacingCharacters(in: selected, with: text)
        insertion = Insertion(
            text: text,
            targetPID: targetPID,
            focusedElement: focused,
            originalValue: value,
            originalRange: range,
            expectedValue: expected,
            expectedCaret: range.location + inserted.length,
            recordedAt: Date()
        )
    }

    @discardableResult
    func undoLastInsertion() -> Bool {
        guard let recorded = insertion else { return false }
        guard Date().timeIntervalSince(recorded.recordedAt) <= lifetime else {
            insertion = nil
            return false
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == recorded.targetPID else { return false }

        let app = AXUIElementCreateApplication(recorded.targetPID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = copyElement(app, attribute: kAXFocusedUIElementAttribute as CFString),
              CFEqual(focused, recorded.focusedElement),
              let value = copyString(focused, attribute: kAXValueAttribute as CFString),
              value == recorded.expectedValue,
              let range = copyRange(focused, attribute: kAXSelectedTextRangeAttribute as CFString),
              range.location == recorded.expectedCaret,
              range.length == 0 else { return false }

        // Repeat the full-state proof immediately before restoring the snapshot.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == recorded.targetPID,
              let latestFocused = copyElement(app, attribute: kAXFocusedUIElementAttribute as CFString),
              CFEqual(latestFocused, recorded.focusedElement),
              let latestValue = copyString(latestFocused, attribute: kAXValueAttribute as CFString),
              latestValue == recorded.expectedValue,
              let latestRange = copyRange(latestFocused, attribute: kAXSelectedTextRangeAttribute as CFString),
              latestRange.location == recorded.expectedCaret,
              latestRange.length == 0 else { return false }

        var valueIsSettable = DarwinBoolean(false)
        var rangeIsSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &valueIsSettable) == .success,
              valueIsSettable.boolValue,
              AXUIElementIsAttributeSettable(focused, kAXSelectedTextRangeAttribute as CFString, &rangeIsSettable) == .success,
              rangeIsSettable.boolValue,
              let restoredRange = makeAXRange(recorded.originalRange) else { return false }

        guard AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, recorded.originalValue as CFString) == .success else {
            return false
        }
        guard AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, restoredRange) == .success else {
            insertion = nil
            return false
        }
        insertion = nil
        return true
    }

    private func copyElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func copyString(_ element: AXUIElement, attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    private func copyRange(_ element: AXUIElement, attribute: CFString) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private func makeAXRange(_ range: CFRange) -> AXValue? {
        var copy = range
        return AXValueCreate(.cfRange, &copy)
    }
}
