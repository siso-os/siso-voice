//
//  ContributionHeatmap.swift
//  SISO Voice (freeflow fork) — Instructions & Account page (§3.5)
//
//  A GitHub-style dictation-activity heatmap: a 7-row LazyHGrid of day cells
//  colored by per-day dictation count, plus a legend and a hover tooltip.
//  Presentational only — takes pre-bucketed [(day:Date,count:Int)].
//
//  Color ramp is built ENTIRELY from existing tokens (brandBlueLight →
//  brandBlueDeep opacity buckets). NO new colors.
//

import SwiftUI

// MARK: - ContributionHeatmap

struct ContributionHeatmap: View {
    /// One entry per calendar day, oldest first. `count` = dictations that day.
    let days: [(day: Date, count: Int)]

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    /// Which hovered cell is showing a tooltip.
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
            grid
            legend
        }
    }

    // MARK: Grid (7 rows × N week columns)

    private var grid: some View {
        let rows = Array(repeating: GridItem(.fixed(cell), spacing: gap), count: 7)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, spacing: gap) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, entry in
                    cellView(entry: entry, index: index)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cellView(entry: (day: Date, count: Int), index: Int) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(InstructionsHeatmap.color(for: entry.count))
            .frame(width: cell, height: cell)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(SISOTheme.Colors.hairline, lineWidth: 0.5)
            )
            .help(tooltip(entry))   // native hover tooltip: count + date
            .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
    }

    private func tooltip(_ entry: (day: Date, count: Int)) -> String {
        let n = entry.count
        let unit = n == 1 ? "dictation" : "dictations"
        return "\(n) \(unit) · \(InstructionsHeatmap.dateLabel(entry.day))"
    }

    // MARK: Legend (Less → More)

    private var legend: some View {
        HStack(spacing: SISOTheme.Metrics.s2) {
            Text("Less")
                .sisoText(.micro, color: SISOTheme.Colors.textMuted)
            ForEach(0..<InstructionsHeatmap.bucketCount, id: \.self) { bucket in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(InstructionsHeatmap.colorForBucket(bucket))
                    .frame(width: cell, height: cell)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .stroke(SISOTheme.Colors.hairline, lineWidth: 0.5)
                    )
            }
            Text("More")
                .sisoText(.micro, color: SISOTheme.Colors.textMuted)
        }
    }
}

// MARK: - InstructionsHeatmap (bucketing + ramp)

/// Pure helpers for the heatmap: 5-bucket count→color ramp built from the
/// existing brand-blue tokens, plus date labeling. No new colors.
enum InstructionsHeatmap {

    /// Bucket 0 (empty) + 4 intensity buckets = 5 total.
    static let bucketCount = 5

    /// Map a daily dictation count into [0, 4].
    ///   0 → 0 (empty), 1–2 → 1, 3–5 → 2, 6–9 → 3, 10+ → 4.
    static func bucket(for count: Int) -> Int {
        switch count {
        case ..<1:    return 0
        case 1...2:   return 1
        case 3...5:   return 2
        case 6...9:   return 3
        default:      return 4
        }
    }

    /// Color for a raw count.
    static func color(for count: Int) -> Color { colorForBucket(bucket(for: count)) }

    /// Color for a bucket index. Empty = canvasInset; 1–4 interpolate opacity on
    /// the brand-blue light→deep stops (existing tokens only).
    static func colorForBucket(_ bucket: Int) -> Color {
        switch bucket {
        case 0:  return SISOTheme.Colors.canvasInset
        case 1:  return SISOTheme.Colors.brandBlueLight.opacity(0.45)
        case 2:  return SISOTheme.Colors.brandBlueLight.opacity(0.85)
        case 3:  return SISOTheme.Colors.brandBlueDeep.opacity(0.7)
        default: return SISOTheme.Colors.brandBlueDeep
        }
    }

    static func dateLabel(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

#if DEBUG
#Preview("Heatmap") {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let sample: [(day: Date, count: Int)] = (0..<(7 * 17)).reversed().map { offset in
        let day = cal.date(byAdding: .day, value: -offset, to: today)!
        return (day, Int.random(in: 0...12))
    }
    return ContributionHeatmap(days: sample)
        .padding(SISOTheme.Metrics.s6)
        .frame(width: 620)
        .background(SISOTheme.Colors.canvas)
}
#endif
