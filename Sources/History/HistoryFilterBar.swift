//
//  HistoryFilterBar.swift
//  SISO Voice (freeflow fork) — History page
//
//  App-filter pill row: a horizontally scrolling strip of toggleable pills, one
//  per top app seen in history (capped at 6), plus an "All" reset pill. Pills
//  are bare + hairline-styled to match the dense History aesthetic (NOT cards).
//
//  macOS 13+.
//

import SwiftUI

/// A single toggleable filter pill.
struct HistoryFilterPill: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = Capsule(style: .continuous)
        Button(action: action) {
            Text(label)
                .sisoText(.pill,
                          color: isActive ? SISOTheme.Colors.cardWhite
                                           : SISOTheme.Colors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, SISOTheme.Metrics.s3)
                .padding(.vertical, SISOTheme.Metrics.s1 + 2)
                .background(
                    shape.fill(isActive ? SISOTheme.Colors.accent
                                        : (hovering ? SISOTheme.Colors.canvasInset
                                                    : Color.clear))
                )
                .overlay(shape.stroke(SISOTheme.Colors.hairline,
                                      lineWidth: isActive ? 0 : 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The filter strip. Shows nothing when there are fewer than two apps to choose
/// between (a filter would be pointless).
struct HistoryFilterBar: View {
    let apps: [String]                  // ordered, already top-N
    @Binding var selected: Set<String>

    var body: some View {
        if apps.count >= 2 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SISOTheme.Metrics.s2) {
                    HistoryFilterPill(label: "All", isActive: selected.isEmpty) {
                        selected.removeAll()
                    }
                    ForEach(apps, id: \.self) { app in
                        HistoryFilterPill(label: app, isActive: selected.contains(app)) {
                            if selected.contains(app) { selected.remove(app) }
                            else { selected.insert(app) }
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    /// Top-N app names by frequency across history (default 6).
    static func topApps(_ history: [PipelineHistoryItem], limit: Int = 6) -> [String] {
        var counts: [String: Int] = [:]
        for item in history {
            guard let app = item.contextAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !app.isEmpty else { continue }
            counts[app, default: 0] += 1
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }
}
