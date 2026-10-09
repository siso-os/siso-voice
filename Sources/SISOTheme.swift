//
//  SISOTheme.swift
//  SISO Voice (freeflow fork)
//
//  Self-contained design-token system matching the Aqua Voice aesthetic.
//  No dependencies on any other freeflow source file. Pure SwiftUI + AppKit.
//
//  Every public symbol is namespaced under `SISOTheme` or prefixed `siso`
//  so it cannot collide with freeflow's existing types.
//
//  Target: Swift 6.1 / SwiftUI on macOS 13+.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Hex Color Initializer

extension Color {
    /// Initialize a `Color` from a hex string. Accepts "#RRGGBB", "RRGGBB",
    /// "#RGB", or "#RRGGBBAA". Falls back to opaque black on a malformed string.
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)

        let r, g, b, a: Double
        switch raw.count {
        case 3: // RGB (12-bit)
            r = Double((value >> 8) & 0xF) / 15.0
            g = Double((value >> 4) & 0xF) / 15.0
            b = Double(value & 0xF) / 15.0
            a = 1.0
        case 6: // RRGGBB (24-bit)
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        case 8: // RRGGBBAA (32-bit)
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        default:
            r = 0; g = 0; b = 0; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - SISOTheme Namespace

/// Canonical design tokens for the SISO Voice UI. All values are derived from
/// the extracted Aqua Voice design spec.
enum SISOTheme {

    // MARK: Colors

    /// Color tokens. Use as `SISOTheme.Colors.cardWhite` etc.
    enum Colors {
        // Surfaces
        static let canvas        = Color(hex: "#F8F8F8")  // warm-gray app background
        static let canvasInset   = Color(hex: "#F4F5F7")  // inset / recessed panels
        static let cardWhite     = Color(hex: "#FFFFFF")  // card fill

        // The signature hairline stroke (used at 0.5px width everywhere)
        static let hairline      = Color(hex: "#E5E7E0")

        // Text
        static let textPrimary   = Color(hex: "#292C3D")  // near-black slate
        static let textSecondary = Color(hex: "#3E4150")
        static let textMuted      = Color(hex: "#8B8F86")  // sage-gray (warm, not cool)

        // Brand blue gradient stops
        static let brandBlueLight = Color(hex: "#67BEFF")
        static let brandBlueDeep  = Color(hex: "#2563EB")

        // Accents / semantic
        static let accent        = Color(hex: "#3B82F6")  // toggle-on / primary accent
        static let destructive   = Color(hex: "#DC2626")  // delete / error red
        static let gold          = Color(hex: "#FFD45A")  // PRO badge gold

        // Shadow tints used by `sisoCard`
        static let bloomBlue     = Color(hex: "#4992FF")  // soft-blue bloom tint
    }

    /// The brand blue gradient (light → deep), top-leading to bottom-trailing.
    static let brandGradient = LinearGradient(
        colors: [Colors.brandBlueLight, Colors.brandBlueDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Metrics

    /// Layout metrics. All `CGFloat`.
    enum Metrics {
        static let sidebarWidth: CGFloat  = 160
        static let cardRadius: CGFloat    = 16
        static let controlRadius: CGFloat = 8
        static let hairline: CGFloat      = 0.5

        // Spacing grid (base unit = 4pt)
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s6: CGFloat = 24
    }

    // MARK: Typography

    /// Custom font family names. `Font.custom(_:size:)` auto-falls-back to the
    /// system font when the family isn't registered with the app bundle.
    enum FontFamily {
        static let primary = "PP Neue Montreal" // workhorse UI typeface
        static let mono    = "Geist Mono"        // numbers / stats
    }

    /// Semantic type roles mapped to point sizes from the design scale.
    enum TextRole {
        case greeting       // 32
        case sectionHeading // 22
        case cardTitle      // 14
        case label          // 14
        case body           // 13
        case caption        // 12
        case pill           // 11
        case micro          // 10

        var size: CGFloat {
            switch self {
            case .greeting:       return 32
            case .sectionHeading: return 22
            case .cardTitle, .label: return 14
            case .body:           return 13
            case .caption:        return 12
            case .pill:           return 11
            case .micro:          return 10
            }
        }

        /// Default weight per role. Medium (500) is the workhorse.
        var weight: Font.Weight {
            switch self {
            case .greeting:       return .semibold
            case .sectionHeading: return .medium
            case .cardTitle:      return .medium
            case .label:          return .medium
            case .body:           return .regular
            case .caption:        return .regular
            case .pill:           return .medium
            case .micro:          return .medium
            }
        }
    }

    /// Build the PP Neue Montreal font for a semantic role.
    /// Falls back to the system font automatically via `Font.custom`.
    static func font(_ role: TextRole) -> Font {
        Font.custom(FontFamily.primary, size: role.size).weight(role.weight)
    }

    /// PP Neue Montreal at an explicit size + weight (Medium by default).
    static func font(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Font.custom(FontFamily.primary, size: size).weight(weight)
    }

    /// Geist Mono at an explicit size (for numbers / stats / timers).
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(FontFamily.mono, size: size).weight(weight)
    }
}

// MARK: - Card Modifier

/// The signature SISO Voice card surface: white fill, 16pt corners, a 0.5px
/// #E5E7E0 hairline stroke, a thin white top-edge highlight (approximating an
/// inset highlight, since SwiftUI lacks true inset shadows), and the
/// soft-blue-bloom drop shadow.
struct SISOCardModifier: ViewModifier {
    var cornerRadius: CGFloat = SISOTheme.Metrics.cardRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background(
                shape.fill(SISOTheme.Colors.cardWhite)
            )
            // Inset top-highlight: a thin white gradient hugging the top edge,
            // clipped to the card shape.
            .overlay(
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.9),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            )
            // Hairline stroke — THE signature 0.5px edge.
            .overlay(
                shape.stroke(SISOTheme.Colors.hairline,
                             lineWidth: SISOTheme.Metrics.hairline)
            )
            .clipShape(shape)
            // Soft-blue bloom + tighter neutral contact shadow.
            .shadow(color: SISOTheme.Colors.bloomBlue.opacity(0.07), radius: 7, x: 0, y: 7)
            .shadow(color: Color.black.opacity(0.03), radius: 3.5, x: 0, y: 1.75)
    }
}

// MARK: - Hairline Divider

/// A 0.5px #E5E7E0 divider line. Defaults to horizontal (full width).
struct SISOHairlineModifier: ViewModifier {
    var axis: Axis = .horizontal

    func body(content: Content) -> some View {
        content.overlay(alignment: axis == .horizontal ? .bottom : .trailing) {
            Rectangle()
                .fill(SISOTheme.Colors.hairline)
                .frame(
                    width: axis == .vertical ? SISOTheme.Metrics.hairline : nil,
                    height: axis == .horizontal ? SISOTheme.Metrics.hairline : nil
                )
        }
    }
}

// MARK: - View Extensions (siso-prefixed)

extension View {
    /// Apply the signature SISO Voice card surface (fill, hairline, highlight, bloom).
    func sisoCard(cornerRadius: CGFloat = SISOTheme.Metrics.cardRadius) -> some View {
        modifier(SISOCardModifier(cornerRadius: cornerRadius))
    }

    /// Attach a 0.5px #E5E7E0 hairline divider to the bottom (or trailing) edge.
    func sisoHairline(_ axis: Axis = .horizontal) -> some View {
        modifier(SISOHairlineModifier(axis: axis))
    }

    /// Apply a SISO semantic text style (font + primary text color).
    func sisoText(_ role: SISOTheme.TextRole,
                  color: Color = SISOTheme.Colors.textPrimary) -> some View {
        font(SISOTheme.font(role)).foregroundColor(color)
    }
}

// MARK: - Standalone Hairline View

/// A standalone hairline rule you can drop into a stack as a divider.
struct SISOHairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(SISOTheme.Colors.hairline)
            .frame(
                width: axis == .vertical ? SISOTheme.Metrics.hairline : nil,
                height: axis == .horizontal ? SISOTheme.Metrics.hairline : nil
            )
    }
}
