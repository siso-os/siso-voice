//
//  ShareCardTicket.swift
//  SISO Voice (freeflow fork) — Stats Share-Card (UI v2 §3.2)
//
//  The exportable hero: a dashed-border "ticket" carrying the brand chip,
//  a static glossy SISOOrb top-right, the huge mono total-word number, the
//  SISO-themed level progress bar, and a 4-column footer. Standalone (no page
//  chrome) so `ImageRenderer` can render it at a fixed 720pt width.
//
//  Departure from spec §3.2: the frame is a hand-rolled DASHED stroke + bloom
//  shadow — NOT `.sisoCard()` (whose stroke is solid). All colors are existing
//  SISOTheme tokens; no new literals.
//
//  Namespaced `ShareCard*`. Target: Swift 6.1 / SwiftUI on macOS 13+.
//

import SwiftUI

// MARK: - Ticket

/// The exportable share-card hero. Fixed-width layout so it renders identically
/// on screen and in the exported PNG.
struct ShareCardTicket: View {
    let stats: ShareCardStats
    /// User display name shown on the ticket (e.g. "shaan").
    var name: String = "shaan"
    /// Layout width in points (720 = export width).
    var width: CGFloat = 720

    private var dateChip: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {
            header
            heroNumber
            levelBar
            SISOHairline()
            footer
        }
        .padding(SISOTheme.Metrics.s6 + SISOTheme.Metrics.s2) // 32pt internal margin
        .frame(width: width, alignment: .leading)
        .background(ticketBackground)
        .overlay(ticketBorder)
        .clipShape(RoundedRectangle(cornerRadius: SISOTheme.Metrics.cardRadius + 4, style: .continuous))
        // Soft brand bloom — the "screenshot-ready" lift.
        .shadow(color: SISOTheme.Colors.bloomBlue.opacity(0.12), radius: 18, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: Background + dashed frame

    private var ticketBackground: some View {
        RoundedRectangle(cornerRadius: SISOTheme.Metrics.cardRadius + 4, style: .continuous)
            .fill(SISOTheme.Colors.cardWhite)
            .overlay(
                // Faint brand wash from the top-left corner toward the orb.
                RoundedRectangle(cornerRadius: SISOTheme.Metrics.cardRadius + 4, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [SISOTheme.Colors.bloomBlue.opacity(0.06), Color.clear],
                            center: .topTrailing,
                            startRadius: 0,
                            endRadius: width * 0.7
                        )
                    )
            )
    }

    private var ticketBorder: some View {
        RoundedRectangle(cornerRadius: SISOTheme.Metrics.cardRadius + 4, style: .continuous)
            .strokeBorder(
                SISOTheme.Colors.brandBlueLight.opacity(0.65),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
            )
    }

    // MARK: Header — name + date chip + PRO pill

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                Text(name)
                    .font(SISOTheme.font(size: 30, weight: .semibold))
                    .foregroundColor(SISOTheme.Colors.textPrimary)
                HStack(spacing: SISOTheme.Metrics.s2) {
                    chip(dateChip, mono: true)
                    proPill
                }
            }
            Spacer(minLength: SISOTheme.Metrics.s4)
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SISOTheme.Colors.textMuted)
                .padding(.trailing, SISOTheme.Metrics.s1)
        }
    }

    private func chip(_ text: String, mono: Bool) -> some View {
        Text(text)
            .font(mono ? SISOTheme.mono(size: 12, weight: .medium) : SISOTheme.font(.caption))
            .foregroundColor(SISOTheme.Colors.textSecondary)
            .padding(.horizontal, SISOTheme.Metrics.s3)
            .padding(.vertical, SISOTheme.Metrics.s1 + 2)
            .background(Capsule().fill(SISOTheme.Colors.canvasInset))
            .overlay(Capsule().stroke(SISOTheme.Colors.hairline, lineWidth: 1))
    }

    // SISO-branded PRO-style pill (replaces Aqua's PRO).
    private var proPill: some View {
        Text("SISO VOICE")
            .font(SISOTheme.mono(size: 10, weight: .medium))
            .kerning(0.8)
            .foregroundColor(SISOTheme.Colors.textPrimary)
            .padding(.horizontal, SISOTheme.Metrics.s3)
            .padding(.vertical, SISOTheme.Metrics.s1 + 2)
            .background(Capsule().fill(SISOTheme.Colors.gold.opacity(0.9)))
    }

    // MARK: Hero number

    private var heroNumber: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s1) {
            SISOSectionLabel("Total Words")
            Text(stats.totalWordsFormatted)
                .font(SISOTheme.mono(size: 72, weight: .medium))
                .foregroundColor(SISOTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)   // 7+ digit numbers scale down to fit
                .fixedSize(horizontal: false, vertical: true)
            Text(saveLine)
                .sisoText(.body, color: SISOTheme.Colors.textMuted)
        }
    }

    private var saveLine: String {
        stats.isEmpty
            ? "Start dictating to build your stats."
            : "SISO Voice has saved you \(stats.timeSavedFormatted) of typing."
    }

    // MARK: Level bar

    private var levelBar: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s2) {
            HStack {
                Text(stats.levelTitleLine)
                    .sisoText(.label, color: SISOTheme.Colors.textPrimary)
                Spacer()
                Text(stats.levelCaption)
                    .font(SISOTheme.mono(size: 11, weight: .regular))
                    .foregroundColor(SISOTheme.Colors.textMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SISOTheme.Colors.canvasInset)
                    Capsule()
                        .fill(SISOTheme.brandGradient)
                        .frame(width: max(0, geo.size.width * stats.level.progress))
                }
            }
            .frame(height: 10)
        }
    }

    // MARK: Footer — 4-column mini-stats

    private var footer: some View {
        HStack(spacing: 0) {
            footerCell(value: stats.wpmFormatted, label: "WPM")
            divider
            footerCell(value: stats.topAppFormatted, label: "Top App")
            divider
            footerCell(value: stats.streakFormatted, label: "Streak")
            divider
            footerCell(value: stats.timeSavedFormatted, label: "Time Saved")
        }
    }

    private func footerCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s1) {
            Text(value)
                .font(SISOTheme.mono(size: 18, weight: .medium))
                .foregroundColor(SISOTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
            Text(label.uppercased())
                .sisoText(.micro, color: SISOTheme.Colors.textMuted)
                .kerning(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        SISOHairline(axis: .vertical)
            .frame(height: 32)
            .padding(.horizontal, SISOTheme.Metrics.s3)
    }
}

#if DEBUG
#Preview("Share Card Ticket") {
    let history = ShareCardPreviewData.sample
    return ShareCardTicket(stats: ShareCardStats.make(from: history))
        .padding(SISOTheme.Metrics.s6)
        .frame(width: 720)
        .background(SISOTheme.Colors.canvas)
}
#endif
