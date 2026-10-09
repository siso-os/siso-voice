//
//  ShareCardExport.swift
//  SISO Voice (freeflow fork) — Stats Share-Card (UI v2 §3.2)
//
//  All AppKit / export plumbing for the share card, isolated here:
//    • copy   → text summary onto NSPasteboard
//    • png    → render the SwiftUI ticket to an NSImage @2x via ImageRenderer
//    • save   → write that PNG to ~/Downloads/siso-voice-stats.png
//    • share  → NSSharingServicePicker on the rendered image
//
//  Namespaced `ShareCardExport`. Target: Swift 6.1 / SwiftUI on macOS 13+.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@MainActor
enum ShareCardExport {

    /// Fixed render width of the exported ticket (matches on-screen ticket).
    static let renderWidth: CGFloat = 720

    // MARK: - PNG render (ImageRenderer @2x)

    /// Render the share-card ticket to an `NSImage` at 2× scale.
    ///
    /// Uses SwiftUI's `ImageRenderer` (macOS 13+). We size the renderer's
    /// proposed width to `width`, set `scale = 2` for a crisp @2x bitmap, and
    /// pull the `nsImage` (already AppKit-native on macOS).
    static func image(for stats: ShareCardStats,
                      name: String = "shaan",
                      width: CGFloat = renderWidth) -> NSImage? {
        let ticket = ShareCardTicket(stats: stats, name: name, width: width)
            .padding(SISOTheme.Metrics.s6)
            .background(SISOTheme.Colors.canvas)
        let renderer = ImageRenderer(content: ticket)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width + SISOTheme.Metrics.s6 * 2,
                                                  height: nil)
        return renderer.nsImage
    }

    /// PNG `Data` for the rendered ticket, or `nil` if rendering/encoding fails.
    static func pngData(for stats: ShareCardStats,
                        name: String = "shaan",
                        width: CGFloat = renderWidth) -> Data? {
        guard let image = image(for: stats, name: name, width: width) else { return nil }
        return pngData(from: image)
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Copy

    /// Build a shareable plain-text summary of the stats.
    static func summaryText(_ stats: ShareCardStats, name: String = "shaan") -> String {
        guard !stats.isEmpty else {
            return "SISO Voice — \(name) has no dictation stats yet."
        }
        var lines: [String] = []
        lines.append("SISO Voice — \(name)")
        lines.append("\(stats.totalWordsFormatted) words dictated • \(stats.levelTitleLine)")
        lines.append("WPM \(stats.wpmFormatted) · Top App \(stats.topAppFormatted) · Streak \(stats.streakFormatted) · Time Saved \(stats.timeSavedFormatted)")
        return lines.joined(separator: "\n")
    }

    /// Write the text summary to the general pasteboard.
    static func copySummary(_ stats: ShareCardStats, name: String = "shaan") {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(summaryText(stats, name: name), forType: .string)
    }

    // MARK: - Save (Downloads)

    /// Default destination: ~/Downloads/siso-voice-stats.png
    static var defaultSaveURL: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("siso-voice-stats.png")
    }

    /// Render @2x PNG and write it to ~/Downloads/siso-voice-stats.png.
    /// - Returns: the written file URL, or `nil` on failure.
    @discardableResult
    static func savePNG(for stats: ShareCardStats, name: String = "shaan") -> URL? {
        guard let data = pngData(for: stats, name: name) else { return nil }
        let url = defaultSaveURL
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Share (NSSharingServicePicker)

    /// Present the system share sheet for the rendered PNG, anchored to a view.
    static func share(_ stats: ShareCardStats,
                      name: String = "shaan",
                      relativeTo rect: NSRect,
                      of view: NSView) {
        guard let image = image(for: stats, name: name) else { return }
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }
}
