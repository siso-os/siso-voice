//
//  InstructionsStore.swift
//  SISO Voice (freeflow fork) — Instructions & Account page (§3.5)
//
//  Persistence for the cleanup-LLM system prompt. @AppStorage-backed, page-owned,
//  no AppState import. Pure SwiftUI/Foundation, macOS 13+.
//
//  IN-CODE NOTE: the persisted prompt feeds the dictation *cleanup pass*, which
//  downstream routes through Bifrost → MiniMax. This store ONLY persists the
//  text — the cleanup-pass read-wiring (PostProcessingService / AppState) is a
//  SEPARATE task and is intentionally not touched here.
//

import SwiftUI

// MARK: - InstructionsStore

/// @AppStorage-backed store for the cleanup-LLM system prompt. The single source
/// of truth is UserDefaults key `siso.cleanup.instructions`; a sibling ISO key
/// records the last-modified timestamp for the "Saved · just now" affordance.
@MainActor
final class InstructionsStore: ObservableObject {

    /// UserDefaults key for the persisted cleanup-LLM system prompt.
    static let instructionsKey = "siso.cleanup.instructions"
    /// UserDefaults key for the ISO-8601 last-modified timestamp.
    static let lastModifiedKey = "siso.cleanup.instructions_last_modified"
    /// UserDefaults key for the cleanup model label.
    static let modelKey = "siso.cleanup.instructions_model"

    /// The bundled default cleanup prompt. Mirrors the shipping default so
    /// Reset-to-default restores the as-shipped behavior.
    static let defaultInstructions = PostProcessingService.defaultSystemPrompt

    /// Default model label shown on the editor badge.
    static let defaultModel = "MiniMax-M2.7"

    /// The persisted (saved) prompt. Writing this updates UserDefaults + stamps
    /// the last-modified timestamp.
    @Published private(set) var saved: String
    /// ISO-8601 timestamp of the last save, or empty if never saved.
    @Published private(set) var lastModifiedISO: String
    /// Model label (e.g. "MiniMax-M2.7").
    @Published private(set) var model: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.instructionsKey)
        self.saved = (stored?.isEmpty == false) ? stored! : Self.defaultInstructions
        self.lastModifiedISO = defaults.string(forKey: Self.lastModifiedKey) ?? ""
        self.model = defaults.string(forKey: Self.modelKey) ?? Self.defaultModel
    }

    /// Persist `text` as the new saved prompt and stamp the modified time.
    func save(_ text: String) {
        saved = text
        defaults.set(text, forKey: Self.instructionsKey)
        let iso = Self.isoFormatter.string(from: Date())
        lastModifiedISO = iso
        defaults.set(iso, forKey: Self.lastModifiedKey)
    }

    /// True when `draft` differs from the persisted prompt (drives the dirty dot).
    func isDirty(_ draft: String) -> Bool { draft != saved }

    /// True when the persisted prompt is the bundled default.
    var isDefault: Bool { saved == Self.defaultInstructions }

    /// A human-relative "Saved · …" suffix, or nil when never saved.
    var savedRelative: String? {
        guard !lastModifiedISO.isEmpty,
              let date = Self.isoFormatter.date(from: lastModifiedISO) else { return nil }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}

// MARK: - Supported tokens (hint chips)

/// Static list of tokens the cleanup prompt may reference. Surfaced as hint
/// chips in the editor; purely informational (no substitution happens here).
enum InstructionsTokens {
    static let all: [String] = [
        "{transcript}",
        "{app_name}",
        "{window_title}",
        "{selection}",
        "{vocabulary}",
    ]
}
