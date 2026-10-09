//
//  DictionaryReplacementsComponents.swift
//  SISO Voice (freeflow fork) — Dictionary & Replacements (§3.4)
//
//  Page-local presentational pieces: DictionaryTermRow, ReplacementRuleRow,
//  DictionarySuggestionChip, DictionaryCountBadge. Composed from Shared §2
//  primitives + SISOTheme tokens. Pure SwiftUI, macOS 13+.
//

import SwiftUI

// MARK: - DictionaryCountBadge

/// A small count pill shown beside a section title (e.g. "12"). Page-local
/// because the Shared `CountBadge` primitive was not built in Phase 1.
struct DictionaryCountBadge: View {
    let count: Int

    init(_ count: Int) { self.count = count }

    var body: some View {
        Text("\(count)")
            .font(SISOTheme.mono(size: 11, weight: .medium))
            .foregroundColor(SISOTheme.Colors.textMuted)
            .padding(.horizontal, SISOTheme.Metrics.s2)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(SISOTheme.Colors.canvasInset)
            )
    }
}

// MARK: - DictionarySuggestionChip

/// A tappable suggestion chip (a common term not yet in the dictionary). Adds
/// the term on tap; the parent removes it from the suggestion row afterward.
struct DictionarySuggestionChip: View {
    let text: String
    let onTap: () -> Void

    init(_ text: String, onTap: @escaping () -> Void) {
        self.text = text
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: SISOTheme.Metrics.s1) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(SISOTheme.Colors.textMuted)
                Text(text)
                    .sisoText(.caption, color: SISOTheme.Colors.textSecondary)
            }
            .padding(.horizontal, SISOTheme.Metrics.s3)
            .padding(.vertical, SISOTheme.Metrics.s1 + 2)
            .background(
                Capsule().fill(SISOTheme.Colors.cardWhite)
            )
            .overlay(
                Capsule().stroke(SISOTheme.Colors.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - DictionaryTermRow

/// A dictionary-term list row: the term text + trailing edit/delete buttons.
/// Editing is hoisted to the parent (which swaps in a `SISOInlineEditor`).
struct DictionaryTermRow: View {
    let term: DictionaryTerm
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: SISOTheme.Metrics.s3) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SISOTheme.Colors.textMuted)
                .frame(width: 18, height: 18)
            Text(term.text)
                .sisoText(.body, color: SISOTheme.Colors.textPrimary)
            Spacer(minLength: SISOTheme.Metrics.s3)
            DictionaryRowActions(onEdit: onEdit, onDelete: onDelete)
        }
        .padding(.vertical, SISOTheme.Metrics.s3)
        .padding(.horizontal, SISOTheme.Metrics.s4)
    }
}

// MARK: - ReplacementRuleRow

/// A replacement-rule list row: from → to, an enable toggle, and edit/delete.
/// Disabled rules render at 0.55 opacity (per spec).
struct ReplacementRuleRow: View {
    let rule: ReplacementRule
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: SISOTheme.Metrics.s3) {
            HStack(spacing: SISOTheme.Metrics.s2) {
                Text(rule.from)
                    .sisoText(.body, color: SISOTheme.Colors.textPrimary)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(SISOTheme.Colors.textMuted)
                Text(rule.to.isEmpty ? "—" : rule.to)
                    .sisoText(.body, color: rule.to.isEmpty
                              ? SISOTheme.Colors.textMuted
                              : SISOTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .opacity(rule.enabled ? 1 : 0.55)

            Spacer(minLength: SISOTheme.Metrics.s3)

            SISOSwitch(isOn: Binding(get: { rule.enabled }, set: { _ in onToggle() }))
            DictionaryRowActions(onEdit: onEdit, onDelete: onDelete)
        }
        .padding(.vertical, SISOTheme.Metrics.s3)
        .padding(.horizontal, SISOTheme.Metrics.s4)
    }
}

// MARK: - DictionaryRowActions (shared trailing edit/delete pair)

/// Hover-light edit + delete icon buttons used by both rows.
private struct DictionaryRowActions: View {
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: SISOTheme.Metrics.s2) {
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SISOTheme.Colors.textMuted)
                    .padding(SISOTheme.Metrics.s1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SISOTheme.Colors.destructive)
                    .padding(SISOTheme.Metrics.s1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
    }
}

#if DEBUG
#Preview("Dictionary Components") {
    VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
        HStack(spacing: SISOTheme.Metrics.s2) {
            SISOSectionLabel("Terms")
            DictionaryCountBadge(3)
        }
        SISOCard {
            VStack(spacing: 0) {
                DictionaryTermRow(term: DictionaryTerm(text: "JARVIS"), onEdit: {}, onDelete: {})
                SISOHairline().padding(.horizontal, SISOTheme.Metrics.s4)
                DictionaryTermRow(term: DictionaryTerm(text: "cmux"), onEdit: {}, onDelete: {})
            }
        }
        SISOFlowLayout {
            DictionarySuggestionChip("SISO") {}
            DictionarySuggestionChip("Bifrost") {}
            DictionarySuggestionChip("MiniMax") {}
        }
        SISOCard {
            VStack(spacing: 0) {
                ReplacementRuleRow(rule: ReplacementRule(from: "teh", to: "the"),
                                   onToggle: {}, onEdit: {}, onDelete: {})
                SISOHairline().padding(.horizontal, SISOTheme.Metrics.s4)
                ReplacementRuleRow(rule: ReplacementRule(from: "wip", to: "work in progress", enabled: false),
                                   onToggle: {}, onEdit: {}, onDelete: {})
            }
        }
    }
    .padding(SISOTheme.Metrics.s6)
    .frame(width: 460)
    .background(SISOTheme.Colors.canvas)
}
#endif
