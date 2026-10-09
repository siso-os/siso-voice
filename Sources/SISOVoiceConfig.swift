import Foundation

/// SISO Voice — local configuration constants for the fork's customizations.
/// Kept in one isolated file so the behavior toggles live outside the
/// freeflow god-files (AppState / SettingsView) and survive upstream churn.
enum SISOVoiceConfig {
    /// Persist every recording to durable audio storage for re-transcribe and
    /// failure recovery. Completed audio is pruned after `audioRetentionDays`.
    static let textOnlyNoAudio = false

    /// Keep audio long enough to retry a failed transcription, then retain only
    /// the transcript and metadata once both transcript fields are complete.
    static let audioRetentionDays = 7

    /// Hard kill switch for SISO Voice -> Herdr/JARVIS sends. Leave voice
    /// transcription local; do not wake agent panes or model routes from the UI.
    static let jarvisHerdrBridgeEnabled = false

    /// The local NDJSON outbox the spine drainer tails.
    static let spineOutboxFileName = "voice-outbox.ndjson"
}

extension Notification.Name {
    /// Open the SISO Voice main window (Aqua-style dashboard).
    static let showMainWindow = Notification.Name("showMainWindow")
    /// Toggle the right-edge slide-out drawer (SISO Internal app stream).
    static let toggleSidebar = Notification.Name("toggleSidebar")
}
