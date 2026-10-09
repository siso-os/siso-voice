//
//  ReplacementStore.swift
//  SISO Voice (freeflow fork) — Dictionary & Replacements (§3.4)
//
//  Page-owned persisted store for find→replace rules. JSON-backed via
//  @AppStorage under key `siso.replacements.rules`. No AppState contact.
//
//  NOTE: rules are applied post-transcription. That wiring is a separate
//        downstream task — this store only persists.
//

import SwiftUI
import Foundation

// MARK: - Model

/// A single find→replace rule. `caseSensitive` is persisted for the downstream
/// pipeline; this page exposes `enabled` toggling only (per spec).
struct ReplacementRule: Codable, Identifiable, Equatable {
    let id: UUID
    var from: String
    var to: String
    var enabled: Bool
    var caseSensitive: Bool
    let addedAt: Date

    init(id: UUID = UUID(),
         from: String,
         to: String,
         enabled: Bool = true,
         caseSensitive: Bool = false,
         addedAt: Date = Date()) {
        self.id = id
        self.from = from
        self.to = to
        self.enabled = enabled
        self.caseSensitive = caseSensitive
        self.addedAt = addedAt
    }
}

// MARK: - Store

/// Persisted list of `ReplacementRule`. Every mutation re-encodes the full
/// array back to UserDefaults synchronously (drag-reorder deferred to v1.1).
final class ReplacementStore: ObservableObject {

    /// UserDefaults key (also the canonical @AppStorage key for this page).
    static let storageKey = "siso.replacements.rules"

    @AppStorage(ReplacementStore.storageKey) private var raw: String = "[]"

    @Published private(set) var rules: [ReplacementRule] = []

    init() {
        self.rules = Self.decode(raw)
    }

    // MARK: Mutations

    /// Append a rule if `from` is non-empty (trimmed). `to` may be empty (deletion).
    func add(from: String, to: String) {
        let trimmedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFrom.isEmpty else { return }
        rules.append(ReplacementRule(from: trimmedFrom,
                                     to: to.trimmingCharacters(in: .whitespacesAndNewlines)))
        persist()
    }

    /// Replace the from/to text of an existing rule (ignored if `from` empties).
    func update(_ id: UUID, from: String, to: String) {
        let trimmedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFrom.isEmpty,
              let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].from = trimmedFrom
        rules[idx].to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// Flip a rule's enabled flag; persists instantly.
    func toggle(_ id: UUID) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].enabled.toggle()
        persist()
    }

    /// Remove a rule by id.
    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    // MARK: Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(rules),
           let json = String(data: data, encoding: .utf8) {
            raw = json
        }
    }

    private static func decode(_ json: String) -> [ReplacementRule] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ReplacementRule].self, from: data) else {
            return []
        }
        return decoded
    }
}
