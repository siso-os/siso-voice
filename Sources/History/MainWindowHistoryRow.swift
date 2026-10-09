//
//  MainWindowHistoryRow.swift
//  SISO Voice (freeflow fork) — History page
//
//  A dense, bare history row: relative time + app chip + intent tag on the meta
//  line, the transcript text below (truncated until tapped to expand), and
//  trailing copy + re-use ghost-icon actions. Hover/selection lifts the row
//  with a `cardWhite` fill + 8pt radius (0.12s). NOT a card.
//
//  macOS 13+.
//

import SwiftUI
import AppKit

/// Notification posted by the re-use action; `object` is the transcript string.
/// The app observes this to paste the text. Defined here (single source) and
/// referenced by the page.
extension Notification.Name {
    static let sisoReuseTranscript = Notification.Name("sisoReuseTranscript")
}

// MARK: - App chip

/// Small app badge: app icon (from the bundle identifier via NSWorkspace, else
/// a generic SF fallback) + name.
struct HistoryAppChip: View {
    let appName: String
    let bundleIdentifier: String?

    private var icon: NSImage? {
        guard let bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        HStack(spacing: SISOTheme.Metrics.s1) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SISOTheme.Colors.textMuted)
            }
            Text(appName)
                .sisoText(.caption, color: SISOTheme.Colors.textMuted)
                .lineLimit(1)
        }
    }
}

// MARK: - Intent tag

/// A muted capsule surfacing the pipeline intent (dictation / command).
struct HistoryIntentTag: View {
    let intent: PipelineHistoryItemIntent

    private var label: String {
        switch intent {
        case .dictation:        return "Dictation"
        case .commandAutomatic: return "Command"
        case .commandManual:    return "Command"
        }
    }

    var body: some View {
        Text(label)
            .sisoText(.micro, color: SISOTheme.Colors.textMuted)
            .kerning(0.5)
            .padding(.horizontal, SISOTheme.Metrics.s2)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous).fill(SISOTheme.Colors.canvasInset)
            )
    }
}

// MARK: - Ghost icon button

private struct HistoryIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = SISOTheme.Colors.textMuted
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(tint)
                .padding(SISOTheme.Metrics.s2)
                .background(
                    RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius,
                                     style: .continuous)
                        .fill(hovering ? SISOTheme.Colors.canvasInset : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct HistoryRetryButton: View {
    let isRetrying: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if isRetrying {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SISOTheme.Colors.textMuted)
                }
            }
            .padding(SISOTheme.Metrics.s2)
            .background(
                RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius,
                                 style: .continuous)
                    .fill(hovering && !isDisabled ? SISOTheme.Colors.canvasInset : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
        .help("Re-transcribe")
    }
}

// MARK: - Row

struct MainWindowHistoryRow: View {
    let item: PipelineHistoryItem
    let isSelected: Bool
    let now: Date
    var isRetrying = false
    var onRetry: (() -> Void)?

    @State private var didCopy = false
    @State private var expanded = false
    @State private var hovering = false

    private var text: String { HistoryText.display(item) }
    private var transcriptMeta: String {
        let duration = item.audioDurationSeconds.map(Self.formatDuration) ?? "--:--"
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return "\(duration) · \(words) \(words == 1 ? "word" : "words")"
    }

    var body: some View {
        HStack(alignment: .top, spacing: SISOTheme.Metrics.s3) {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s1) {
                // Meta line
                HStack(spacing: SISOTheme.Metrics.s2) {
                    Text(HistoryText.relative(item.timestamp, relativeTo: now))
                        .font(SISOTheme.mono(size: 11))
                        .foregroundColor(SISOTheme.Colors.textMuted)
                    if let app = item.contextAppName, !app.isEmpty {
                        Text("·").sisoText(.caption, color: SISOTheme.Colors.textMuted)
                        HistoryAppChip(appName: app,
                                       bundleIdentifier: item.contextBundleIdentifier)
                    }
                    HistoryIntentTag(intent: item.intent)
                    Text("·").sisoText(.caption, color: SISOTheme.Colors.textMuted)
                    Text(transcriptMeta)
                        .font(SISOTheme.mono(size: 11))
                        .foregroundColor(SISOTheme.Colors.textMuted)
                }
                // Transcript
                Text(text)
                    .sisoText(.body, color: SISOTheme.Colors.textPrimary)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: expanded)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            }

            HStack(spacing: 0) {
                HistoryIconButton(systemName: didCopy ? "checkmark" : "doc.on.doc",
                                  help: "Copy",
                                  tint: didCopy ? SISOTheme.Colors.accent
                                                : SISOTheme.Colors.textMuted,
                                  action: copy)
                HistoryIconButton(systemName: "arrow.uturn.left",
                                  help: "Re-use",
                                  action: reuse)
                if item.audioFileName != nil {
                    HistoryRetryButton(
                        isRetrying: isRetrying,
                        isDisabled: isRetrying || onRetry == nil,
                        action: { onRetry?() }
                    )
                }
            }
            .opacity(hovering || isSelected ? 1 : 0.35)
        }
        .padding(.horizontal, SISOTheme.Metrics.s4)
        .padding(.vertical, SISOTheme.Metrics.s3)
        .background(
            RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius, style: .continuous)
                .fill(hovering || isSelected ? SISOTheme.Colors.cardWhite : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius, style: .continuous)
                .stroke(isSelected ? SISOTheme.Colors.accent.opacity(0.4) : Color.clear,
                        lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .onHover { hovering = $0 }
    }

    // MARK: Actions

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
    }

    func reuse() {
        copy()
        NotificationCenter.default.post(name: .sisoReuseTranscript, object: text)
    }

    private static func formatDuration(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
