//
//  SISOButtons.swift
//  SISO Voice (freeflow fork) — Shared component library
//
//  Action primitives: SISOButton (primary / secondary / ghost), SISOSearchField,
//  SISOInlineEditor. Built entirely on SISOTheme tokens. Pure SwiftUI, macOS 13+.
//

import SwiftUI

// MARK: - SISOButton

/// A shadcn `Button` with three variants (default / secondary / ghost),
/// implemented as a custom `ButtonStyle`. Height 32, radius 8.
struct SISOButton: View {
    enum Variant { case primary, secondary, ghost }

    let title: String
    let variant: Variant
    let action: () -> Void

    /// - Parameters:
    ///   - title: button label text.
    ///   - variant: `.primary` (accent fill), `.secondary` (inset fill),
    ///     or `.ghost` (clear → inset on hover).
    ///   - action: tap handler.
    init(_ title: String,
         variant: Variant = .primary,
         action: @escaping () -> Void) {
        self.title = title
        self.variant = variant
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(SISOButtonStyle(variant: variant))
    }
}

/// The custom `ButtonStyle` backing `SISOButton`.
struct SISOButtonStyle: ButtonStyle {
    var variant: SISOButton.Variant
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius,
                                     style: .continuous)
        configuration.label
            .sisoText(.label, color: foreground)
            .padding(.horizontal, SISOTheme.Metrics.s4)
            .frame(height: 32)
            .background(shape.fill(background(pressed: configuration.isPressed)))
            .overlay(
                shape.stroke(SISOTheme.Colors.hairline,
                             lineWidth: variant == .secondary ? 1 : 0)
            )
            .clipShape(shape)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch variant {
        case .primary:   return SISOTheme.Colors.cardWhite
        case .secondary: return SISOTheme.Colors.textPrimary
        case .ghost:     return SISOTheme.Colors.textSecondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary:   return SISOTheme.Colors.accent
        case .secondary: return SISOTheme.Colors.canvasInset
        case .ghost:     return (hovering || pressed) ? SISOTheme.Colors.canvasInset : Color.clear
        }
    }
}

// MARK: - SISOSearchField

/// A shadcn `Input` styled as search: leading magnifier, trailing clear button,
/// h36, hairline border, accent focus ring.
struct SISOSearchField: View {
    @Binding var text: String
    var placeholder: String
    @FocusState private var focused: Bool

    /// - Parameters:
    ///   - text: bound query text.
    ///   - placeholder: empty-state prompt (default "Search").
    init(text: Binding<String>, placeholder: String = "Search") {
        self._text = text
        self.placeholder = placeholder
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius,
                                     style: .continuous)
        HStack(spacing: SISOTheme.Metrics.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SISOTheme.Colors.textMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(SISOTheme.font(.body))
                .foregroundColor(SISOTheme.Colors.textPrimary)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(SISOTheme.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, SISOTheme.Metrics.s3)
        .frame(height: 36)
        .background(shape.fill(SISOTheme.Colors.cardWhite))
        .overlay(
            shape.stroke(focused ? SISOTheme.Colors.accent : SISOTheme.Colors.hairline,
                         lineWidth: 1)
        )
        .overlay(
            shape.stroke(SISOTheme.Colors.accent.opacity(focused ? 0.18 : 0),
                         lineWidth: 3)
        )
        .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

// MARK: - SISOInlineEditor

/// An expanding inline-edit row: one field (a single term) or two fields (a
/// rule: from → to), each with the search-field chrome, plus Save (primary)
/// and Cancel (ghost) buttons.
struct SISOInlineEditor: View {
    @Binding var primary: String
    @Binding var secondary: String
    let twoFields: Bool
    let primaryPlaceholder: String
    let secondaryPlaceholder: String
    let onSave: () -> Void
    let onCancel: () -> Void

    /// Single-field editor (e.g. a dictionary term).
    init(text: Binding<String>,
         placeholder: String = "Term",
         onSave: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self._primary = text
        self._secondary = .constant("")
        self.twoFields = false
        self.primaryPlaceholder = placeholder
        self.secondaryPlaceholder = ""
        self.onSave = onSave
        self.onCancel = onCancel
    }

    /// Two-field editor (e.g. a replacement rule: from → to).
    init(from: Binding<String>,
         to: Binding<String>,
         fromPlaceholder: String = "From",
         toPlaceholder: String = "To",
         onSave: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self._primary = from
        self._secondary = to
        self.twoFields = true
        self.primaryPlaceholder = fromPlaceholder
        self.secondaryPlaceholder = toPlaceholder
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(spacing: SISOTheme.Metrics.s2) {
            SISOSearchField(text: $primary, placeholder: primaryPlaceholder)
            if twoFields {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SISOTheme.Colors.textMuted)
                SISOSearchField(text: $secondary, placeholder: secondaryPlaceholder)
            }
            SISOButton("Save", variant: .primary, action: onSave)
            SISOButton("Cancel", variant: .ghost, action: onCancel)
        }
    }
}

#if DEBUG
private struct SISOButtonsPreviewHost: View {
    @State private var query = ""
    @State private var term = "agentic"
    @State private var dummy = ""
    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
            HStack(spacing: SISOTheme.Metrics.s3) {
                SISOButton("Primary") {}
                SISOButton("Secondary", variant: .secondary) {}
                SISOButton("Ghost", variant: .ghost) {}
            }
            SISOSearchField(text: $query)
            SISOInlineEditor(text: $term, onSave: {}, onCancel: {})
            SISOInlineEditor(from: $term, to: $dummy, onSave: {}, onCancel: {})
        }
        .padding(SISOTheme.Metrics.s6)
        .frame(width: 480)
        .background(SISOTheme.Colors.canvas)
    }
}

#Preview("Buttons & Fields") { SISOButtonsPreviewHost() }
#endif
