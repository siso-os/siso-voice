//
//  JarvisOrb.swift
//  freeflow
//
//  The JARVIS-style floating overlay orb for SISO Voice. A richer evolution of
//  `SISOOrb`: a layered, glowing sphere that breathes dim when idle and comes
//  alive on the user's voice during dictation, shows an orbital ring while
//  transcribing, and pulses red on error.
//
//  Pure SwiftUI — no Metal, no images, no external dependencies. macOS 13+.
//
//  8-layer back-to-front stack:
//    1. outer aura        — large soft bloom, swells with audio / breathing
//    2. mid bloom         — tighter inner glow ring
//    3. sphere body       — radial gradient marble
//    4. core swirl        — animated Canvas energy (listening) / ring sweep
//    5. diagonal sheen    — 135° glassy depth overlay
//    6. specular          — top-left glint
//    7. rim               — pale-blue edge + highlight arc
//    8. orbital ring      — transcribing only; rotating dashed orbit
//
//  Everything is namespaced under `Jarvis*` / `Orb*` so it never collides with
//  freeflow's existing types. References no other freeflow types except
//  `SISOTheme` color tokens.
//

import SwiftUI

// MARK: - Phase

/// The orb's high-level visual state. Mapped from `OverlayPhase` by the
/// `OrbOverlayManager` (see OrbOverlay.swift):
/// `.initializing`/`.recording` → `.listening`; `.transcribing` →
/// `.transcribing`; `.feedback` → `.error`.
public enum OrbPhase: Equatable {
    /// Resident dim breathing state — no voice activity.
    case idle
    /// Live dictation — orb reacts to `audioLevel`.
    case listening
    /// Post-recording processing — orbital ring, audio reactivity off.
    case transcribing
    /// Transient failure — red pulse that should resolve back to `.idle`.
    case error
}

// MARK: - Palette

/// Color spec for the JARVIS orb. Built on `SISOTheme` brand-blue tokens so it
/// shares the app's palette, plus an error-red derived from `destructive`.
/// Kept private to this file so it can never shadow freeflow's own colors.
private enum JarvisOrbPalette {
    static let brandLight = SISOTheme.Colors.brandBlueLight   // #67BEFF
    static let brandDeep  = SISOTheme.Colors.brandBlueDeep    // #2563EB
    static let bloom      = SISOTheme.Colors.bloomBlue        // #4992FF
    static let accent     = SISOTheme.Colors.accent           // #3B82F6
    static let errorRed   = SISOTheme.Colors.destructive      // #DC2626

    /// Sphere body radial gradient, center → edge.
    static let bodyCenter = Color(.sRGB, red: 0x4F / 255, green: 0x9A / 255, blue: 0xFF / 255, opacity: 0.92)
    static let bodyEdge   = Color(.sRGB, red: 0x16 / 255, green: 0x3C / 255, blue: 0x8C / 255, opacity: 0.85)

    /// Diagonal 135° sheen stops.
    static let sheenTop    = Color(.sRGB, red: 0xBF / 255, green: 0xDE / 255, blue: 0xFF / 255, opacity: 0.55)
    static let sheenMid    = Color(.sRGB, red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, opacity: 0.18)
    static let sheenBottom = Color(.sRGB, red: 0x10 / 255, green: 0x2A / 255, blue: 0x5E / 255, opacity: 0.45)

    /// Pale rim.
    static let rim = Color(.sRGB, red: 0xB3 / 255, green: 0xD9 / 255, blue: 0xFF / 255, opacity: 0.55)

    /// Tint for the current phase's glow + core swirl.
    static func glow(for phase: OrbPhase) -> Color {
        switch phase {
        case .error: return errorRed
        default:     return bloom
        }
    }
}

// MARK: - Audio smoothing filter

/// Asymmetric one-pole smoothing filter. Reacts fast on rising audio (attack)
/// and decays slowly on falling audio (release) so the orb leaps to life on a
/// voice onset but settles gently — never jittery. Reference-type so the value
/// persists across `TimelineView` re-evaluations.
private final class OrbAudioSmoother {
    /// Fast attack — rise quickly toward a louder level.
    private let attack: Float = 0.55
    /// Slow release — decay gently when audio drops.
    private let release: Float = 0.12

    private(set) var value: Float = 0

    /// Feed a new normalized level (0...1) and return the smoothed value.
    @discardableResult
    func process(_ target: Float) -> Float {
        let clamped = min(max(target, 0), 1)
        let k = clamped > value ? attack : release
        value += (clamped - value) * k
        return value
    }

    func reset() { value = 0 }
}

// MARK: - Orb

/// The layered, animated JARVIS orb.
///
/// Drives a single `TimelineView(.animation)` whose cadence branches by phase:
/// idle uses a calm 20fps breathing cadence; all other phases run
/// display-linked for fluid audio reactivity and ring motion.
public struct JarvisOrb: View {
    private let audioLevel: Float
    private let phase: OrbPhase
    private let coreDiameter: CGFloat

    /// - Parameters:
    ///   - audioLevel: Normalized mic level (0...1). Clamped + smoothed internally.
    ///   - phase: Visual state (idle / listening / transcribing / error).
    ///   - coreDiameter: Diameter of the sphere body in points. Default 64.
    public init(audioLevel: Float, phase: OrbPhase, coreDiameter: CGFloat = 64) {
        self.audioLevel = audioLevel
        self.phase = phase
        self.coreDiameter = coreDiameter
    }

    /// Persistent smoothing filter — survives TimelineView re-evals via @StateObject-free
    /// reference held in @State (filter is a class, identity is stable).
    @State private var smoother = OrbAudioSmoother()

    /// Idle-breathing frequency: one full breath every ~5.5s.
    private static let breatheHz: Double = 0.18

    public var body: some View {
        TimelineView(.animation(minimumInterval: cadence, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let smoothed = stepSmoother()
            content(time: t, smoothed: smoothed)
        }
        // The whole orb scales with the smoothed voice level while listening.
        .frame(width: coreDiameter, height: coreDiameter)
    }

    /// TimelineView cadence by phase: calm 20fps for idle breathing,
    /// display-linked (nil interval) otherwise for fluid reactivity.
    private var cadence: Double? {
        switch phase {
        case .idle: return 1.0 / 20.0
        default:    return nil
        }
    }

    /// Advance the smoothing filter once per frame. In non-listening phases the
    /// audio target is zero so the orb decays out of reactivity.
    private func stepSmoother() -> Float {
        let target: Float = (phase == .listening) ? audioLevel : 0
        return smoother.process(target)
    }

    // MARK: Composed content

    @ViewBuilder
    private func content(time t: TimeInterval, smoothed: Float) -> some View {
        let breathe = (sin(t * 2 * .pi * Self.breatheHz) + 1) / 2   // 0...1
        let level = CGFloat(min(max(smoothed, 0), 1))

        // Idle breathes a small amount; listening scales with the smoothed level.
        let bodyScale: CGFloat = {
            switch phase {
            case .idle:        return 1.0 + CGFloat(breathe) * 0.04
            case .listening:   return 1.0 + level * 0.18
            case .transcribing: return 1.0
            case .error:       return 1.0
            }
        }()

        // Error pulses on a faster sine so it reads as an alert.
        let errorPulse = (sin(t * 2 * .pi * 1.2) + 1) / 2

        ZStack {
            outerAura(time: t, level: level, breathe: breathe, errorPulse: errorPulse)
            midBloom(level: level, breathe: breathe, errorPulse: errorPulse)
            sphereBody
            coreSwirl(time: t, level: level)
            diagonalSheen
            specular
            rim
            if phase == .transcribing {
                orbitalRing(time: t)
            }
        }
        .scaleEffect(bodyScale)
        .animation(.spring(response: 0.16, dampingFraction: 0.7), value: level)
    }

    // MARK: Layer 1 — outer aura

    private func outerAura(time t: TimeInterval, level: CGFloat, breathe: Double, errorPulse: Double) -> some View {
        let glow = JarvisOrbPalette.glow(for: phase)
        let opacity: Double
        let scale: CGFloat
        switch phase {
        case .idle:
            opacity = 0.18 + breathe * 0.10
            scale = 1.35 + CGFloat(breathe) * 0.06
        case .listening:
            opacity = 0.32 + Double(level) * 0.40
            scale = 1.45 + level * 0.55
        case .transcribing:
            opacity = 0.26
            scale = 1.45
        case .error:
            opacity = 0.30 + errorPulse * 0.40
            scale = 1.45 + CGFloat(errorPulse) * 0.12
        }
        return Circle()
            .fill(glow)
            .opacity(opacity)
            .scaleEffect(scale)
            .blur(radius: coreDiameter * (0.30 + level * 0.18))
    }

    // MARK: Layer 2 — mid bloom

    private func midBloom(level: CGFloat, breathe: Double, errorPulse: Double) -> some View {
        let glow = JarvisOrbPalette.glow(for: phase)
        let opacity: Double
        switch phase {
        case .idle:        opacity = 0.22 + breathe * 0.10
        case .listening:   opacity = 0.35 + Double(level) * 0.35
        case .transcribing: opacity = 0.30
        case .error:       opacity = 0.35 + errorPulse * 0.30
        }
        return Circle()
            .fill(glow)
            .opacity(opacity)
            .scaleEffect(1.12 + level * 0.20)
            .blur(radius: coreDiameter * 0.16)
    }

    // MARK: Layer 3 — sphere body

    private var sphereBody: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: phase == .error
                        ? [JarvisOrbPalette.errorRed.opacity(0.95),
                           JarvisOrbPalette.errorRed.opacity(0.55)]
                        : [JarvisOrbPalette.bodyCenter, JarvisOrbPalette.bodyEdge]),
                    center: UnitPoint(x: 0.38, y: 0.34),
                    startRadius: 0,
                    endRadius: coreDiameter * 0.62
                )
            )
    }

    // MARK: Layer 4 — core swirl (Canvas energy)

    /// Animated energy at the orb's core. While listening, two offset arcs sweep
    /// and brighten with the voice level; otherwise a faint resting glint.
    private func coreSwirl(time t: TimeInterval, level: CGFloat) -> some View {
        let intensity: CGFloat
        switch phase {
        case .listening:   intensity = 0.35 + level * 0.65
        case .idle:        intensity = 0.18
        case .transcribing: intensity = 0.22
        case .error:       intensity = 0.0
        }
        let glow = JarvisOrbPalette.glow(for: phase)
        return Canvas { ctx, size in
            guard intensity > 0.01 else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) * 0.5
            // Two counter-rotating arcs whose radius/phase shift with time.
            for i in 0..<2 {
                let speed = (i == 0) ? 0.9 : -1.4
                let base = t * speed
                let arcR = r * (0.30 + 0.12 * CGFloat(i)) * (0.85 + 0.30 * sin(base))
                var path = Path()
                let start = Angle(radians: base.truncatingRemainder(dividingBy: 2 * .pi))
                path.addArc(center: c, radius: arcR,
                            startAngle: start,
                            endAngle: start + .degrees(150),
                            clockwise: false)
                ctx.stroke(
                    path,
                    with: .color(glow.opacity(Double(intensity) * (i == 0 ? 0.55 : 0.35))),
                    style: StrokeStyle(lineWidth: r * 0.10, lineCap: .round)
                )
            }
            // Bright pinpoint core.
            let coreR = r * (0.10 + 0.10 * intensity)
            let coreRect = CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)
            ctx.fill(Path(ellipseIn: coreRect),
                     with: .color(Color.white.opacity(Double(intensity) * 0.6)))
        }
        .blur(radius: coreDiameter * 0.015)
        .clipShape(Circle())
    }

    // MARK: Layer 5 — diagonal sheen

    private var diagonalSheen: some View {
        Circle()
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        JarvisOrbPalette.sheenTop,
                        JarvisOrbPalette.sheenMid,
                        JarvisOrbPalette.sheenBottom
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .blendMode(.overlay)
            .clipShape(Circle())
    }

    // MARK: Layer 6 — specular highlight

    private var specular: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0.65),
                        Color.white.opacity(0.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: coreDiameter * 0.26
                )
            )
            .frame(width: coreDiameter * 0.5, height: coreDiameter * 0.5)
            .offset(x: -coreDiameter * 0.18, y: -coreDiameter * 0.20)
            .blur(radius: coreDiameter * 0.02)
    }

    // MARK: Layer 7 — rim

    private var rim: some View {
        Circle()
            .strokeBorder(JarvisOrbPalette.rim, lineWidth: max(0.8, coreDiameter * 0.025))
            .overlay(
                Circle()
                    .trim(from: 0.55, to: 0.82)
                    .stroke(
                        Color.white.opacity(0.45),
                        style: StrokeStyle(lineWidth: max(0.6, coreDiameter * 0.02), lineCap: .round)
                    )
                    .blur(radius: coreDiameter * 0.01)
            )
    }

    // MARK: Layer 8 — orbital ring (transcribing only)

    private func orbitalRing(time t: TimeInterval) -> some View {
        let rotation = Angle(degrees: (t * 90).truncatingRemainder(dividingBy: 360))
        return Circle()
            .trim(from: 0.0, to: 0.7)
            .stroke(
                JarvisOrbPalette.brandLight.opacity(0.85),
                style: StrokeStyle(lineWidth: max(1.2, coreDiameter * 0.03),
                                   lineCap: .round,
                                   dash: [coreDiameter * 0.04, coreDiameter * 0.08])
            )
            .frame(width: coreDiameter * 1.28, height: coreDiameter * 1.28)
            .rotationEffect(rotation)
            .blur(radius: 0.3)
    }
}

// MARK: - Preview harness

#if DEBUG
/// Self-driving preview that cycles all four phases and feeds a synthetic sine
/// "voice" while listening, so the orb can be eyeballed without a live mic.
private struct JarvisOrbPreviewHarness: View {
    @State private var phaseIndex = 0
    private let phases: [OrbPhase] = [.idle, .listening, .transcribing, .error]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let wave = (sin(t * 2 * .pi * 0.8) + 1) / 2
            let flutter = (sin(t * 2 * .pi * 3.3) + 1) / 2 * 0.25
            let level = Float(min(1.0, wave * 0.8 + flutter))
            let phase = phases[phaseIndex]

            VStack(spacing: 16) {
                ZStack {
                    Color.black.opacity(0.95)
                    JarvisOrb(
                        audioLevel: phase == .listening ? level : 0,
                        phase: phase,
                        coreDiameter: 80
                    )
                }
                .frame(width: 240, height: 240)
                Text(label(for: phase))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(24)
            .background(Color.black)
            .onTapGesture { phaseIndex = (phaseIndex + 1) % phases.count }
        }
    }

    private func label(for phase: OrbPhase) -> String {
        switch phase {
        case .idle:         return "idle — tap to cycle"
        case .listening:    return "listening — tap to cycle"
        case .transcribing: return "transcribing — tap to cycle"
        case .error:        return "error — tap to cycle"
        }
    }
}

#Preview("JARVIS Orb — phases") {
    JarvisOrbPreviewHarness()
}
#endif
