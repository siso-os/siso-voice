//
//  SISOChips.swift
//  SISO Voice (freeflow fork) — Shared component library
//
//  Badge-family primitives: SISOKeycapChip, SISOStatPill, SISOValidationPill.
//  Built entirely on SISOTheme tokens. Pure SwiftUI, macOS 13+.
//

import SwiftUI

// MARK: - SISOKeycapChip

/// A `kbd`-style chip: tokenizes a display string like "⌘ ⇧ D" on spaces into
/// individual keycap capsules. Never wraps (assumes ≤3 caps).
struct SISOKeycapChip: View {
    let keys: [String]

    /// - Parameter displayName: a space-separated shortcut string (e.g. "⌘ ⇧ D").
    init(_ displayName: String) {
        self.keys = displayName
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// - Parameter keys: pre-tokenized keycap strings.
    init(keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: SISOTheme.Metrics.s1) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(SISOTheme.mono(size: 12, weight: .medium))
                    .foregroundColor(SISOTheme.Colors.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(SISOTheme.Colors.canvasInset)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(SISOTheme.Colors.hairline, lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - SISOStatPill

/// A compact stat `Card` + optional `Badge` delta: a big mono value, a muted
/// caption label, and an optional accent delta pill. Expands to fill width.
struct SISOStatPill: View {
    let value: String
    let label: String
    let delta: String?

    /// - Parameters:
    ///   - value: the headline figure (rendered in Geist Mono 22).
    ///   - label: the caption beneath the value.
    ///   - delta: optional change indicator (e.g. "+12%").
    init(value: String, label: String, delta: String? = nil) {
        self.value = value
        self.label = label
        self.delta = delta
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s1) {
            HStack(alignment: .firstTextBaseline, spacing: SISOTheme.Metrics.s2) {
                Text(value)
                    .font(SISOTheme.mono(size: 22, weight: .medium))
                    .foregroundColor(SISOTheme.Colors.textPrimary)
                if let delta {
                    Text(delta)
                        .sisoText(.pill, color: SISOTheme.Colors.accent)
                        .padding(.horizontal, SISOTheme.Metrics.s2)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(SISOTheme.Colors.accent.opacity(0.12))
                        )
                }
            }
            Text(label)
                .sisoText(.caption, color: SISOTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SISOTheme.Metrics.s4)
        .sisoCard(cornerRadius: 12)
    }
}

// MARK: - SISOValidationPill

/// A destructive `Badge`: an error message with a leading `xmark.circle.fill`,
/// rendered in the destructive color.
struct SISOValidationPill: View {
    let message: String

    /// - Parameter message: the validation/error text.
    init(_ message: String) { self.message = message }

    var body: some View {
        Label {
            Text(message).sisoText(.caption, color: SISOTheme.Colors.destructive)
        } icon: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(SISOTheme.Colors.destructive)
        }
    }
}

#if DEBUG
#Preview("Chips") {
    VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
        SISOKeycapChip("⌘ ⇧ D")
        HStack(spacing: SISOTheme.Metrics.s3) {
            SISOStatPill(value: "1,204", label: "Words", delta: "+12%")
            SISOStatPill(value: "37", label: "Sessions")
        }
        SISOValidationPill("Term cannot be empty")
    }
    .padding(SISOTheme.Metrics.s6)
    .frame(width: 360)
    .background(SISOTheme.Colors.canvas)
}
#endif
