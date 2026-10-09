//
//  DictionaryStore.swift
//  SISO Voice (freeflow fork) — Dictionary & Replacements (§3.4)
//
//  Page-owned persisted store for custom vocabulary terms. JSON-backed via
//  @AppStorage under key `siso.dictionary.terms`. No AppState contact.
//
//  NOTE: these terms feed the Groq transcription `prompt` param for biasing.
//        That wiring is a separate downstream task — this store only persists.
//

import SwiftUI
import Foundation

// MARK: - Model

/// A single custom-vocabulary term (a name or piece of jargon — e.g. "SISO").
struct DictionaryTerm: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    let addedAt: Date

    init(id: UUID = UUID(), text: String, addedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.addedAt = addedAt
    }
}

// MARK: - Store

/// Persisted list of `DictionaryTerm`. Every mutation re-encodes the full array
/// back to UserDefaults synchronously (drag-reorder deferred to v1.1).
final class DictionaryStore: ObservableObject {

    /// UserDefaults key (also the canonical @AppStorage key for this page).
    static let storageKey = "siso.dictionary.terms"

    @AppStorage(DictionaryStore.storageKey) private var raw: String = "[]"

    @Published private(set) var terms: [DictionaryTerm] = []

    init() {
        self.terms = Self.decode(raw)
    }

    // MARK: Mutations

    /// Append a trimmed term if non-empty and not already present (case-insensitive).
    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !terms.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        terms.append(DictionaryTerm(text: trimmed))
        persist()
    }

    /// Replace the text of an existing term (trimmed; ignored if empty).
    func update(_ id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = terms.firstIndex(where: { $0.id == id }) else { return }
        terms[idx].text = trimmed
        persist()
    }

    /// Remove a term by id.
    func remove(_ id: UUID) {
        terms.removeAll { $0.id == id }
        persist()
    }

    /// True if a term with this text already exists (case-insensitive).
    func contains(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return terms.contains { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    // MARK: Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(terms),
           let json = String(data: data, encoding: .utf8) {
            raw = json
        }
    }

    private static func decode(_ json: String) -> [DictionaryTerm] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([DictionaryTerm].self, from: data) else {
            return []
        }
        return decoded
    }
}
