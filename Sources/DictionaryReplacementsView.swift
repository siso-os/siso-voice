//
//  DictionaryReplacementsView.swift
//  SISO Voice (freeflow fork) — Dictionary & Replacements (§3.4)
//
//  Segmented two-tab page: Dictionary (custom vocabulary terms) + Replacements
//  (find→replace rules). Owns DictionaryStore + ReplacementStore directly; makes
//  NO contact with AppState. Rendered by MainWindowView's `dictionary` case
//  (switch-wiring is a separate task — this file only exposes the view).
//
//  Downstream wiring is out of scope:
//    • dictionary terms bias the Groq transcription `prompt` param,
//    • replacement rules apply post-transcription.
//  The pipeline reads these stores later — do not touch pipeline files here.
//

import SwiftUI

struct DictionaryReplacementsView: View {
    /// History feeds *suggestion chips only* (distinct `customVocabulary`
    /// fragments). Dictionary terms themselves come from `DictionaryStore`.
    let history: [PipelineHistoryItem]

    init(history: [PipelineHistoryItem]) {
        self.history = history
    }

    @StateObject private var dictionary = DictionaryStore()
    @StateObject private var replacements = ReplacementStore()

    @State private var tab = "dictionary"

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {
            MainWindowHeader(title: "Dictionary", onRefresh: nil)

            SISOSegmented(selection: $tab, options: [
                ("dictionary", "Dictionary"),
                ("replacements", "Replacements")
            ])
            .frame(maxWidth: 320)

            ScrollView {
                Group {
                    if tab == "dictionary" {
                        DictionarySection(store: dictionary, history: history)
                    } else {
                        ReplacementsSection(store: replacements)
                    }
                }
                .padding(.bottom, SISOTheme.Metrics.s6)
            }
        }
        .padding(SISOTheme.Metrics.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SISOTheme.Colors.canvas)
    }
}

// MARK: - Dictionary Section

private struct DictionarySection: View {
    @ObservedObject var store: DictionaryStore
    let history: [PipelineHistoryItem]

    @State private var isAdding = false
    @State private var draftText = ""
    @State private var editingID: UUID? = nil
    @State private var editText = ""
    @State private var query = ""

    /// Distinct `customVocabulary` fragments from history, split on newline/comma,
    /// minus terms already in the store. The only use of `customVocabulary`.
    private var suggestions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in history {
            let fragments = item.customVocabulary
                .split(whereSeparator: { $0 == "\n" || $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for frag in fragments where !frag.isEmpty {
                let key = frag.lowercased()
                if seen.contains(key) { continue }
                if store.contains(frag) { continue }
                seen.insert(key)
                out.append(frag)
            }
        }
        return out
    }

    private var filteredTerms: [DictionaryTerm] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.terms }
        return store.terms.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {

            // Header: title + count + Add button.
            HStack {
                SISOSectionLabel("Custom terms")
                DictionaryCountBadge(store.terms.count)
                Spacer()
                if !isAdding {
                    SISOButton("+ Add", variant: .primary) {
                        draftText = ""
                        isAdding = true
                    }
                }
            }

            // Search appears only past 8 terms.
            if store.terms.count > 8 {
                SISOSearchField(text: $query, placeholder: "Search terms")
            }

            // Inline add editor.
            if isAdding {
                SISOInlineEditor(
                    text: $draftText,
                    placeholder: "New term (e.g. SISO, JARVIS, cmux)",
                    onSave: {
                        store.add(draftText)
                        draftText = ""
                        isAdding = false
                    },
                    onCancel: {
                        draftText = ""
                        isAdding = false
                    }
                )
            }

            // Term list (or empty state).
            if store.terms.isEmpty {
                SISOEmptyState(
                    icon: "text.book.closed",
                    title: "No custom terms yet",
                    message: "Add names and jargon so transcription spells them right."
                )
            } else {
                SISOCard {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredTerms.enumerated()), id: \.element.id) { index, term in
                            if index > 0 {
                                SISOHairline().padding(.horizontal, SISOTheme.Metrics.s4)
                            }
                            if editingID == term.id {
                                SISOInlineEditor(
                                    text: $editText,
                                    placeholder: "Term",
                                    onSave: {
                                        store.update(term.id, text: editText)
                                        editingID = nil
                                    },
                                    onCancel: { editingID = nil }
                                )
                                .padding(.vertical, SISOTheme.Metrics.s2)
                                .padding(.horizontal, SISOTheme.Metrics.s4)
                            } else {
                                DictionaryTermRow(
                                    term: term,
                                    onEdit: {
                                        editText = term.text
                                        editingID = term.id
                                    },
                                    onDelete: { store.remove(term.id) }
                                )
                            }
                        }
                    }
                }
            }

            // Suggestion chips.
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: SISOTheme.Metrics.s2) {
                    SISOSectionLabel("Suggestions from history")
                    SISOFlowLayout {
                        ForEach(suggestions.prefix(24), id: \.self) { suggestion in
                            DictionarySuggestionChip(suggestion) {
                                store.add(suggestion)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Replacements Section

private struct ReplacementsSection: View {
    @ObservedObject var store: ReplacementStore

    @State private var isAdding = false
    @State private var draftFrom = ""
    @State private var draftTo = ""
    @State private var editingID: UUID? = nil
    @State private var editFrom = ""
    @State private var editTo = ""
    @State private var query = ""

    private var filteredRules: [ReplacementRule] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.rules }
        return store.rules.filter {
            $0.from.localizedCaseInsensitiveContains(trimmed) ||
            $0.to.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {

            HStack {
                SISOSectionLabel("Replacement rules")
                DictionaryCountBadge(store.rules.count)
                Spacer()
                if !isAdding {
                    SISOButton("+ Add", variant: .primary) {
                        draftFrom = ""
                        draftTo = ""
                        isAdding = true
                    }
                }
            }

            // Search appears only past 8 rules.
            if store.rules.count > 8 {
                SISOSearchField(text: $query, placeholder: "Search rules")
            }

            // Inline add editor (two-field: from → to).
            if isAdding {
                SISOInlineEditor(
                    from: $draftFrom,
                    to: $draftTo,
                    fromPlaceholder: "From",
                    toPlaceholder: "To",
                    onSave: {
                        store.add(from: draftFrom, to: draftTo)
                        draftFrom = ""
                        draftTo = ""
                        isAdding = false
                    },
                    onCancel: {
                        draftFrom = ""
                        draftTo = ""
                        isAdding = false
                    }
                )
            }

            if store.rules.isEmpty {
                SISOEmptyState(
                    icon: "arrow.left.arrow.right",
                    title: "No replacement rules yet",
                    message: "Rewrite words automatically after transcription (e.g. teh → the)."
                )
            } else {
                SISOCard {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredRules.enumerated()), id: \.element.id) { index, rule in
                            if index > 0 {
                                SISOHairline().padding(.horizontal, SISOTheme.Metrics.s4)
                            }
                            if editingID == rule.id {
                                SISOInlineEditor(
                                    from: $editFrom,
                                    to: $editTo,
                                    fromPlaceholder: "From",
                                    toPlaceholder: "To",
                                    onSave: {
                                        store.update(rule.id, from: editFrom, to: editTo)
                                        editingID = nil
                                    },
                                    onCancel: { editingID = nil }
                                )
                                .padding(.vertical, SISOTheme.Metrics.s2)
                                .padding(.horizontal, SISOTheme.Metrics.s4)
                            } else {
                                ReplacementRuleRow(
                                    rule: rule,
                                    onToggle: { store.toggle(rule.id) },
                                    onEdit: {
                                        editFrom = rule.from
                                        editTo = rule.to
                                        editingID = rule.id
                                    },
                                    onDelete: { store.remove(rule.id) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("Dictionary & Replacements") {
    DictionaryReplacementsView(history: [])
        .frame(width: 720, height: 640)
}
#endif
