import Foundation

/// Compatibility shim for the removed persisted JARVIS mode.
///
/// JARVIS sends are no longer bound to a keyboard shortcut. Right Option is
/// reserved for SISO Voice's tap-to-toggle dictation action. This type remains
/// so older call sites can clear stale state, but it never stores or returns an
/// armed mode.
enum JarvisMode {
    static let storageKey = "jarvis_mode_enabled"

    /// Posted whenever the toggle flips, so the orb / menu can update.
    static let didChange = Notification.Name("jarvisModeDidChange")

    static var isEnabled: Bool {
        UserDefaults.standard.removeObject(forKey: storageKey)
        return false
    }

    @discardableResult
    static func toggle() -> Bool {
        set(false)
        return false
    }

    static func set(_: Bool) {
        UserDefaults.standard.removeObject(forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["enabled": false])
    }
}
