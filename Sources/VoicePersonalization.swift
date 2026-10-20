//
//  VoicePersonalization.swift
//  SISO Voice — local dictation modes, vocabulary, replacements and snippets.
//

import Foundation

enum VoiceMode: String, CaseIterable, Identifiable, Codable {
    case standard
    case verbatim
    case message
    case email
    case code
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default"
        case .verbatim: return "Verbatim"
        case .message: return "Message"
        case .email: return "Email"
        case .code: return "Code"
        case .agent: return "Agent prompt"
        }
    }

    /// Instructions for the transcription cleanup stage. Agent mode never sends.
    var instructions: String {
        switch self {
        case .standard: return ""
        case .verbatim:
            return "Preserve the speaker's wording, order, and tone. Add only the punctuation needed for readability. Do not rewrite or summarize."
        case .message:
            return "Write a concise, natural message in the speaker's voice. Keep the meaning and tone; add light punctuation and paragraph breaks where useful."
        case .email:
            return "Format the speaker's words as a clear, professional email. Preserve their intent and tone, use readable paragraphs, and do not invent a recipient, subject, or facts."
        case .code:
            return "Transcribe code, identifiers, commands, and technical terms accurately. Preserve spoken symbols and structure as text; do not execute commands or invent code."
        case .agent:
            return "Turn the speaker's words into a clear instruction for an agent while preserving intent and constraints. Do not execute, send, or submit anything; the user reviews and deliberately sends it."
        }
    }
}

struct VoiceModeMapping: Codable, Identifiable, Equatable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var mode: VoiceMode
}

struct VoiceSnippet: Codable, Identifiable, Equatable {
    var id: UUID
    var trigger: String
    var content: String

    init(id: UUID = UUID(), trigger: String, content: String) {
        self.id = id
        self.trigger = trigger
        self.content = content
    }
}

enum VoicePersonalization {
    static let mappingsStorageKey = "siso.voice.modeMappings"
    static let snippetsStorageKey = "siso.voice.snippets"
    static let reviewDraftKey = "siso.voice.reviewDraft"
    static let draftMinimumWordsKey = "siso.voice.draftMinimumWords"
    static let agentPaneKey = "siso.voice.agentPane"
    static let agentReadBackKey = "siso.voice.agentReadBack"

    private static let defaults: [String: VoiceMode] = [
        "com.apple.MobileSMS": .message,
        "com.apple.mail": .email,
        "com.apple.iChat": .message,
        "com.tinyspeck.slackmacgap": .message,
        "com.apple.dt.Xcode": .code,
        "com.microsoft.VSCode": .code,
        "com.googlecode.iterm2": .code,
        "com.apple.Terminal": .code
    ]

    static func mode(forBundleIdentifier bundleIdentifier: String?) -> VoiceMode {
        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else { return .standard }
        if let override = loadMappings().first(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }) { return override.mode }
        return defaults[bundleIdentifier] ?? .standard
    }

    /// An explicit leading `<mode> mode:` / `<mode> mode ` phrase wins. The
    /// equivalent `[mode] <mode>:` form is also accepted. Unknown text is intact.
    static func resolve(_ text: String, bundleIdentifier: String?) -> (text: String, mode: VoiceMode) {
        let leadingTrimmed = text.drop(while: { $0.isWhitespace })
        let directive = "[mode]"
        let fallback = mode(forBundleIdentifier: bundleIdentifier)
        let isTagged = leadingTrimmed.lowercased().hasPrefix(directive)
        let body = isTagged
            ? leadingTrimmed.dropFirst(directive.count).drop(while: { $0.isWhitespace })
            : leadingTrimmed[...]
        guard let nameEnd = body.firstIndex(where: { $0.isWhitespace || $0 == ":" }),
              let selectedMode = VoiceMode(rawValue: String(body[..<nameEnd]).lowercased()) else {
            return (text, fallback)
        }
        var remainder = body[nameEnd...]
        if isTagged {
            if remainder.first == ":" {
                remainder = remainder.dropFirst()
            } else if remainder.first?.isWhitespace != true {
                return (text, fallback)
            }
        } else {
            guard remainder.first?.isWhitespace == true else { return (text, fallback) }
            remainder = remainder.drop(while: { $0.isWhitespace })
            guard remainder.lowercased().hasPrefix("mode") else { return (text, fallback) }
            remainder = remainder.dropFirst("mode".count)
            guard remainder.first == ":" || remainder.first?.isWhitespace == true else {
                return (text, fallback)
            }
            if remainder.first == ":" { remainder = remainder.dropFirst() }
        }
        remainder = remainder.drop(while: { $0.isWhitespace })
        return (String(remainder), selectedMode)
    }

    static func loadMappings() -> [VoiceModeMapping] {
        decode([VoiceModeMapping].self, key: mappingsStorageKey, default: [])
    }

    static func saveMappings(_ mappings: [VoiceModeMapping]) {
        encode(mappings, key: mappingsStorageKey)
    }

    static func loadSnippets() -> [VoiceSnippet] {
        decode([VoiceSnippet].self, key: snippetsStorageKey, default: [])
    }

    static func saveSnippets(_ snippets: [VoiceSnippet]) {
        encode(snippets, key: snippetsStorageKey)
    }

    /// Expands matches from the original input only, so inserted text is never rescanned.
    static func expandSnippets(in text: String) -> String {
        let snippets = loadSnippets()
            .filter { !$0.trigger.isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }
        guard !snippets.isEmpty else { return text }
        return replacingMatches(in: text, entries: snippets.map { ($0.trigger, $0.content, false) })
    }

    /// Applies enabled rules using the schema owned by ReplacementStore.
    static func applyReplacements(to text: String) -> String {
        let rules = decode([LocalReplacementRule].self, key: "siso.replacements.rules", default: [])
            .filter { $0.enabled && !$0.from.isEmpty }
        return replacingMatches(in: text, entries: rules.map { ($0.from, $0.to, $0.caseSensitive) })
    }

    /// Reads only the `text` field from DictionaryStore's persisted JSON records.
    static func customVocabulary() -> [String] {
        decode([LocalDictionaryTerm].self, key: "siso.dictionary.terms", default: [])
            .map(\.text).filter { !$0.isEmpty }
    }

    private struct LocalDictionaryTerm: Decodable { let text: String }
    private struct LocalReplacementRule: Decodable {
        let from: String
        let to: String
        let enabled: Bool
        let caseSensitive: Bool
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, default fallback: T) -> T {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(type, from: data) else { return fallback }
        return value
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: key)
    }

    private static func replacingMatches(in text: String, entries: [(String, String, Bool)]) -> String {
        var output = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            var match: (range: Range<String.Index>, replacement: String)?
            for (trigger, replacement, caseSensitive) in entries {
                var searchStart = cursor
                var range: Range<String.Index>?
                while searchStart < text.endIndex,
                      let candidate = text.range(of: trigger,
                                                 options: caseSensitive ? [] : [.caseInsensitive],
                                                 range: searchStart..<text.endIndex) {
                    if isPhraseBoundary(in: text, range: candidate) {
                        range = candidate
                        break
                    }
                    searchStart = text.index(after: candidate.lowerBound)
                }
                guard let range else { continue }
                if match == nil || range.lowerBound < match!.range.lowerBound ||
                    (range.lowerBound == match!.range.lowerBound && text.distance(from: range.lowerBound, to: range.upperBound) > text.distance(from: match!.range.lowerBound, to: match!.range.upperBound)) {
                    match = (range, replacement)
                }
            }
            guard let match else {
                output.append(contentsOf: text[cursor...])
                break
            }
            output.append(contentsOf: text[cursor..<match.range.lowerBound])
            output.append(contentsOf: match.replacement)
            cursor = match.range.upperBound
        }
        return output
    }

    private static func isPhraseBoundary(in text: String, range: Range<String.Index>) -> Bool {
        let word: (Character) -> Bool = {
            $0 == "_" || $0.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
        let leftOK = range.lowerBound == text.startIndex || !word(text[text.index(before: range.lowerBound)])
        let rightOK = range.upperBound == text.endIndex || !word(text[range.upperBound])
        return leftOK && rightOK
    }
}
