import AppKit
import SwiftUI

@main
enum VoiceMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--demo") {
            VoiceDemo.run()
        } else {
            FreeFlowApp.main()
        }
    }
}

// This entry path never constructs AppDelegate or AppState, reads settings or starts a recorder.
enum VoiceDemo {
    @MainActor
    static func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SISO Voice · Offline demo"
        window.contentView = NSHostingView(rootView: VoiceDemoView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        let delegate = VoiceDemoDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

private struct VoiceDemoView: View {
    @State private var example = 0
    private let samples = [
        ("Ready to try", "Choose an example to see a synthetic dictation. This demo uses no microphone, network, saved history or app context."),
        ("Dictation", "Please move the planning meeting to Thursday at ten and share the updated agenda."),
        ("Cleanup", "Move the planning meeting to Thursday at 10:00 and share the updated agenda."),
        ("Edit", "Thursday, 10:00: planning meeting. Please share the updated agenda.")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("SISO Voice", systemImage: "waveform").font(.largeTitle.bold())
            Text("Offline demo · synthetic examples").font(.subheadline).foregroundStyle(.secondary)
            Text(samples[example].0).font(.title2.bold())
            Text(samples[example].1).font(.title3).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            HStack {
                Button("Next example") { example = example == samples.count - 1 ? 1 : example + 1 }
                    .keyboardShortcut(.defaultAction)
                Button("Reset") { example = 0 }
            }
            Text("Normal dictation requires your own provider key and macOS permissions.").font(.caption).foregroundStyle(.secondary)
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private final class VoiceDemoDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
