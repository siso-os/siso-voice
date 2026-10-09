//
//  SISOControls.swift
//  SISO Voice (freeflow fork) — Shared component library
//
//  Interactive controls: SISOSwitch, SISOToggleRow, SISOSelect, SISOSegmented.
//  Built entirely on SISOTheme tokens. Pure SwiftUI, macOS 13+.
//

import SwiftUI

// MARK: - SISOSwitch

/// A hand-built toggle (NOT a system `Toggle` restyle): a 36×20 capsule track
/// that fills `accent` when on / `hairline` when off, with a 16pt white thumb
/// that slides + shadows. Animates `.easeInOut(0.18)`.
struct SISOSwitch: View {
    @Binding var isOn: Bool

    /// - Parameter isOn: the toggle state binding.
    init(isOn: Binding<Bool>) { self._isOn = isOn }

    var body: some View {
        Capsule()
            .fill(isOn ? SISOTheme.Colors.accent : SISOTheme.Colors.hairline)
            .frame(width: 36, height: 20)
            .overlay(
                Circle()
                    .fill(SISOTheme.Colors.cardWhite)
                    .frame(width: 16, height: 16)
                    .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
                    .offset(x: isOn ? 8 : -8)
            )
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { isOn.toggle() }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - SISOToggleRow

/// A `SISORow` with a trailing `SISOSwitch`. Composes the two primitives.
struct SISOToggleRow: View {
    let icon: String?
    let label: String
    let sublabel: String?
    @Binding var isOn: Bool

    /// - Parameters:
    ///   - icon: optional SF Symbol name.
    ///   - label: primary label.
    ///   - sublabel: optional secondary line.
    ///   - isOn: toggle state binding.
    init(icon: String? = nil,
         label: String,
         sublabel: String? = nil,
         isOn: Binding<Bool>) {
        self.icon = icon
        self.label = label
        self.sublabel = sublabel
        self._isOn = isOn
    }

    var body: some View {
        SISORow(icon: icon, label: label, sublabel: sublabel) {
            SISOSwitch(isOn: $isOn)
        }
    }
}

// MARK: - SISOSelect

/// A shadcn `Select` trigger built on `Menu`: an input-shaped label showing the
/// current selection's label plus a `chevron.up.chevron.down`. Generic over an
/// ordered list of `(value, label)` pairs; bound to `Binding<String>`.
struct SISOSelect: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String

    /// - Parameters:
    ///   - selection: bound selected `value`.
    ///   - options: ordered `(value, label)` pairs.
    init(selection: Binding<String>, options: [(value: String, label: String)]) {
        self._selection = selection
        self.options = options
    }

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? selection
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: SISOTheme.Metrics.s2) {
                Text(currentLabel)
                    .sisoText(.body, color: SISOTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: SISOTheme.Metrics.s2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SISOTheme.Colors.textMuted)
                    .opacity(0.5)
            }
            .padding(.horizontal, SISOTheme.Metrics.s3)
            .padding(.vertical, SISOTheme.Metrics.s2)
            .background(
                RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius, style: .continuous)
                    .fill(SISOTheme.Colors.cardWhite)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius, style: .continuous)
                    .stroke(SISOTheme.Colors.hairline, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - SISOSegmented

/// A shadcn `Tabs`/`TabsList` segmented control: pills on a `canvasInset` track
/// with a 3pt inset; the active pill gets a `cardWhite` fill + light shadow.
struct SISOSegmented: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String

    /// - Parameters:
    ///   - selection: bound selected `value`.
    ///   - options: ordered `(value, label)` pairs.
    init(selection: Binding<String>, options: [(value: String, label: String)]) {
        self._selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let active = option.value == selection
                Text(option.label)
                    .sisoText(.label,
                              color: active ? SISOTheme.Colors.textPrimary
                                            : SISOTheme.Colors.textMuted)
                    .padding(.vertical, SISOTheme.Metrics.s1 + 2)
                    .padding(.horizontal, SISOTheme.Metrics.s3)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: SISOTheme.Metrics.cardRadius - 3,
                                         style: .continuous)
                            .fill(active ? SISOTheme.Colors.cardWhite : Color.clear)
                            .shadow(color: active ? Color.black.opacity(0.06) : .clear,
                                    radius: 2, x: 0, y: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.16)) { selection = option.value }
                    }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: SISOTheme.Metrics.cardRadius, style: .continuous)
                .fill(SISOTheme.Colors.canvasInset)
        )
    }
}

#if DEBUG
private struct SISOControlsPreviewHost: View {
    @State private var on = true
    @State private var off = false
    @State private var sel = "natural"
    @State private var seg = "week"
    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
            HStack(spacing: SISOTheme.Metrics.s4) {
                SISOSwitch(isOn: $on)
                SISOSwitch(isOn: $off)
            }
            SISOToggleRow(icon: "bolt.fill", label: "Auto-clean", sublabel: "Run cleanup pass", isOn: $on)
            SISOSelect(selection: $sel, options: [("natural", "Natural"), ("verbatim", "Verbatim")])
                .frame(width: 200)
            SISOSegmented(selection: $seg, options: [("day", "Day"), ("week", "Week"), ("month", "Month")])
                .frame(width: 280)
        }
        .padding(SISOTheme.Metrics.s6)
        .background(SISOTheme.Colors.canvas)
    }
}

#Preview("Controls") { SISOControlsPreviewHost() }
#endif
