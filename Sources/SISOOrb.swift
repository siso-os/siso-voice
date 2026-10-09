//
//  SISOOrb.swift
//  freeflow
//
//  A polished, audio-reactive "listening orb": a glossy glass-marble sphere in
//  SISO blue that pulses with the user's voice. Pure SwiftUI — no Metal, no
//  images, no external dependencies. Compiles under Swift 6.1 / SwiftUI macOS 13+.
//
//  Everything is namespaced under the `SISO`/`SISOOrb` prefix so it never
//  collides with freeflow's existing types (e.g. WaveformView,
//  RecordingOverlayState). This file references no other freeflow types: the
//  caller passes in the normalized mic level via `audioLevel`.
//

import SwiftUI

// MARK: - Palette

/// Extracted Aqua-orb color spec for the SISO listening orb. Kept private to
/// this file so it can never shadow or be shadowed by freeflow's own colors.
private enum SISOOrbPalette {
    /// Outer bloom / glow color: rgba(32, 85, 160).
    static let glow = Color(.sRGB, red: 32 / 255, green: 85 / 255, blue: 160 / 255, opacity: 1.0)

    /// Sphere body radial gradient: center → edge.
    static let bodyCenter = Color(.sRGB, red: 39 / 255, green: 77 / 255, blue: 133 / 255, opacity: 0.85)
    static let bodyEdge = Color(.sRGB, red: 15 / 255, green: 101 / 255, blue: 157 / 255, opacity: 0.70)

    /// Diagonal sheen overlay stops (135°).
    static let sheenTop = Color(.sRGB, red: 20 / 255, green: 50 / 255, blue: 110 / 255, opacity: 0.90)
    static let sheenMid = Color(.sRGB, red: 40 / 255, green: 100 / 255, blue: 180 / 255, opacity: 0.90)
    static let sheenBottom = Color(.sRGB, red: 18 / 255, green: 65 / 255, blue: 140 / 255, opacity: 0.90)

    /// Tight pale-blue rim: rgba(179, 217, 255, 0.5).
    static let rim = Color(.sRGB, red: 179 / 255, green: 217 / 255, blue: 255 / 255, opacity: 0.50)
}

// MARK: - Orb

/// A glossy, audio-reactive SISO-blue sphere.
///
/// Layered back-to-front: outer bloom → sphere body + diagonal sheen →
/// top-left specular highlight → pale rim. The whole orb scales and the bloom
/// swells with `audioLevel`, animated with a lively-but-not-jittery spring.
public struct SISOOrb: View {
    /// Normalized mic level in 0...1.
    private let audioLevel: Float
    /// Base diameter of the orb in points.
    private let size: CGFloat

    /// - Parameters:
    ///   - audioLevel: Normalized mic level (0...1). Clamped internally.
    ///   - size: Base diameter in points. Defaults to 28.
    ///   - phase: Accepted for caller convenience and intentionally ignored;
    ///            the orb reacts purely to `audioLevel`.
    public init(audioLevel: Float, size: CGFloat = 28, phase: Double = 0) {
        self.audioLevel = audioLevel
        self.size = size
        _ = phase // reserved for future use; intentionally unused
    }

    /// audioLevel clamped to a sane 0...1 so a noisy caller can't blow up scale.
    private var level: CGFloat {
        CGFloat(min(max(audioLevel, 0), 1))
    }

    public var body: some View {
        ZStack {
            bloom
            sphereBody
            specularHighlight
            rim
        }
        .frame(width: size, height: size)
        // The orb itself gently swells with the voice level.
        .scaleEffect(1.0 + level * 0.18)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: audioLevel)
    }

    // MARK: Layer 1 — soft outer bloom / glow

    private var bloom: some View {
        Circle()
            .fill(SISOOrbPalette.glow)
            // Base 0.4 opacity, rising with level (up to ~0.7).
            .opacity(0.40 + Double(level) * 0.30)
            // Slightly larger than the orb, swelling with level.
            .scaleEffect(1.18 + level * 0.45)
            // Blur scales with size so the glow stays soft at any diameter.
            .blur(radius: size * (0.22 + level * 0.18))
    }

    // MARK: Layer 2 — sphere body + diagonal sheen

    private var sphereBody: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        SISOOrbPalette.bodyCenter,
                        SISOOrbPalette.bodyEdge
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.5
                )
            )
            .overlay(
                // Diagonal 135° sheen, blended for a glassy depth.
                LinearGradient(
                    gradient: Gradient(colors: [
                        SISOOrbPalette.sheenTop,
                        SISOOrbPalette.sheenMid,
                        SISOOrbPalette.sheenBottom
                    ]),
                    startPoint: .topLeading,     // 135° axis: top-left → bottom-right
                    endPoint: .bottomTrailing
                )
                .blendMode(.overlay)
                .clipShape(Circle())
            )
    }

    // MARK: Layer 3 — top-left specular highlight

    private var specularHighlight: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0.50),
                        Color.white.opacity(0.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.28
                )
            )
            // Sized as a small glint and offset to the upper-left (~30% / 30%).
            .frame(width: size * 0.55, height: size * 0.55)
            .offset(x: -size * 0.20, y: -size * 0.20)
            .blur(radius: size * 0.02)
    }

    // MARK: Layer 4 — tight pale-blue rim (+ thin highlight arc)

    private var rim: some View {
        Circle()
            .strokeBorder(SISOOrbPalette.rim, lineWidth: max(0.8, size * 0.03))
            .overlay(
                // Thin brighter highlight arc along the upper-left edge.
                Circle()
                    .trim(from: 0.55, to: 0.80)
                    .stroke(
                        Color.white.opacity(0.45),
                        style: StrokeStyle(lineWidth: max(0.6, size * 0.025), lineCap: .round)
                    )
                    .blur(radius: size * 0.01)
            )
    }
}

// MARK: - Preview harness

/// A tiny self-driving demo that animates `audioLevel` with a sine wave so the
/// orb can be eyeballed without a live mic. Uses `TimelineView` (macOS 13+).
public struct SISOOrbPreviewHarness: View {
    private let size: CGFloat

    public init(size: CGFloat = 120) {
        self.size = size
    }

    public var body: some View {
        TimelineView(.animation) { context in
            // Map wall-clock time to a 0...1 sine sweep at ~0.7 Hz.
            let t = context.date.timeIntervalSinceReferenceDate
            let wave = (sin(t * 2 * .pi * 0.7) + 1) / 2          // 0...1
            // A little secondary bounce so it reads as voice, not a metronome.
            let flutter = (sin(t * 2 * .pi * 3.3) + 1) / 2 * 0.25
            let level = Float(min(1.0, wave * 0.8 + flutter))

            ZStack {
                Color.black.opacity(0.92)
                SISOOrb(audioLevel: level, size: size)
            }
            .frame(width: size * 2.2, height: size * 2.2)
        }
    }
}

#if DEBUG
#Preview("SISO Orb") {
    SISOOrbPreviewHarness()
}
#endif
