//
//  SISOContainers.swift
//  SISO Voice (freeflow fork) — Shared component library
//
//  Container & layout primitives: SISOCard, SISOSectionLabel, SISORow,
//  SISOFlowLayout, and SISOEmptyState (thin alias over MainWindowEmptyState).
//
//  Built entirely on SISOTheme tokens. Pure SwiftUI, macOS 13+.
//

import SwiftUI

// MARK: - SISOCard

/// shadcn `Card` (`rounded-xl border bg-card`). A white card surface with the
/// signature hairline + bloom, internally padded by `Metrics.s4`.
struct SISOCard<Content: View>: View {
    var cornerRadius: CGFloat = SISOTheme.Metrics.cardRadius
    var padding: CGFloat = SISOTheme.Metrics.s4
    @ViewBuilder var content: Content

    /// - Parameters:
    ///   - cornerRadius: corner radius (default `Metrics.cardRadius` = 16).
    ///   - padding: internal padding (default `Metrics.s4` = 16).
    ///   - content: card body.
    init(cornerRadius: CGFloat = SISOTheme.Metrics.cardRadius,
         padding: CGFloat = SISOTheme.Metrics.s4,
         @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .sisoCard(cornerRadius: cornerRadius)
    }
}

// MARK: - SISOSectionLabel

/// A form-section eyebrow / `CardDescription`: uppercased, tracked, muted.
struct SISOSectionLabel: View {
    let text: String

    /// - Parameter text: label text (rendered uppercased).
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .sisoText(.micro, color: SISOTheme.Colors.textMuted)
            .kerning(0.8)
    }
}

// MARK: - SISORow

/// A dense settings/list row: optional SF icon + label/sublabel + trailing
/// control slot, separated from siblings by inset hairlines (caller-applied).
struct SISORow<Trailing: View>: View {
    let icon: String?
    let label: String
    let sublabel: String?
    @ViewBuilder var trailing: Trailing

    /// - Parameters:
    ///   - icon: optional SF Symbol name (rendered in an 18pt frame).
    ///   - label: primary row label.
    ///   - sublabel: optional secondary line.
    ///   - trailing: trailing control slot (switch, select, button, …).
    init(icon: String? = nil,
         label: String,
         sublabel: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.label = label
        self.sublabel = sublabel
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: SISOTheme.Metrics.s3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(SISOTheme.Colors.textSecondary)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .sisoText(.label, color: SISOTheme.Colors.textPrimary)
                if let sublabel {
                    Text(sublabel)
                        .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                }
            }
            Spacer(minLength: SISOTheme.Metrics.s3)
            trailing
        }
        .padding(.vertical, SISOTheme.Metrics.s3)
        .padding(.horizontal, SISOTheme.Metrics.s4)
    }
}

extension SISORow where Trailing == EmptyView {
    /// Convenience initializer for a row with no trailing control.
    init(icon: String? = nil, label: String, sublabel: String? = nil) {
        self.init(icon: icon, label: label, sublabel: sublabel) { EmptyView() }
    }
}

// MARK: - SISOEmptyState

/// Thin alias over the existing `MainWindowEmptyState` so pages can refer to a
/// `SISO`-prefixed name. Does NOT redefine the view — reuses it as-is.
struct SISOEmptyState: View {
    let icon: String
    let title: String
    let message: String

    /// - Parameters mirror `MainWindowEmptyState(icon:title:message:)`.
    init(icon: String, title: String, message: String) {
        self.icon = icon
        self.title = title
        self.message = message
    }

    var body: some View {
        MainWindowEmptyState(icon: icon, title: title, message: message)
    }
}

// MARK: - SISOFlowLayout

/// A minimal wrapping `Layout` for chip rows: lays subviews left-to-right,
/// wrapping to a new line when the proposed width is exceeded.
struct SISOFlowLayout: Layout {
    var spacing: CGFloat = SISOTheme.Metrics.s2
    var lineSpacing: CGFloat = SISOTheme.Metrics.s2

    /// - Parameters:
    ///   - spacing: horizontal gap between items (default `Metrics.s2` = 8).
    ///   - lineSpacing: vertical gap between wrapped lines (default `Metrics.s2`).
    init(spacing: CGFloat = SISOTheme.Metrics.s2,
         lineSpacing: CGFloat = SISOTheme.Metrics.s2) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } +
            CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: min(width, maxWidth.isFinite ? maxWidth : width),
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, width: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty && projected > maxWidth {
                rows.append(current)
                current = Row()
            }
            let newWidth = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.items.append((index, size.width))
            current.width = newWidth
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

#if DEBUG
#Preview("Containers") {
    VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
        SISOSectionLabel("General")
        SISOCard {
            VStack(spacing: 0) {
                SISORow(icon: "mic.fill", label: "Microphone", sublabel: "Built-in") {
                    Text("On").sisoText(.caption, color: SISOTheme.Colors.textMuted)
                }
                SISOHairline().padding(.horizontal, SISOTheme.Metrics.s4)
                SISORow(icon: "waveform", label: "Input level")
            }
        }
        SISOFlowLayout {
            ForEach(["alpha", "beta", "gamma", "delta", "epsilon"], id: \.self) { t in
                Text(t).sisoText(.caption).padding(6).background(SISOTheme.Colors.canvasInset)
            }
        }
        SISOEmptyState(icon: "tray", title: "Nothing here", message: "Records will appear once you dictate.")
    }
    .padding(SISOTheme.Metrics.s6)
    .frame(width: 360)
    .background(SISOTheme.Colors.canvas)
}
#endif
