import AppKit
import SwiftUI

/// Presents an explicit, editable review step before sending dictated text to a Herdr agent.
@MainActor
enum VoiceAgentDelivery {
    static func present(_ text: String) {
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        AgentDeliveryPanel.shared.present(draft)
    }
}

@MainActor
private final class AgentDeliveryPanel {
    static let shared = AgentDeliveryPanel()

    private var panel: NSPanel?
    private var state: AgentDeliveryState?
    private let speech = NSSpeechSynthesizer()

    func present(_ text: String) {
        let savedPane = UserDefaults.standard.string(forKey: "siso.voice.agentPane") ?? ""
        let state = AgentDeliveryState(text: text, selectedPane: savedPane)
        self.state = state
        let panel = ensurePanel()
        panel.contentView = NSHostingView(rootView: AgentDeliveryEditor(state: state,
            onSend: { [weak self] in self?.send(state) },
            onCancel: { [weak self] in self?.panel?.orderOut(nil) }))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        state.loadPanes()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Review message for agent"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 460, height: 320)
        self.panel = panel
        return panel
    }

    private func send(_ state: AgentDeliveryState) {
        let paneID = state.selectedPane.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneID.isEmpty, !message.isEmpty, state.panes.contains(where: { $0.id == paneID }) else {
            state.status = "Choose an available Claude or Codex pane."
            return
        }
        state.isSending = true
        state.status = "Sending…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let listing = try HerdrBridge.runHerdr(["pane", "list"])
                    guard let data = listing.data(using: .utf8),
                          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let result = root["result"] as? [String: Any],
                          let rawPanes = result["panes"] as? [[String: Any]],
                          rawPanes.contains(where: {
                              ($0["pane_id"] as? String) == paneID &&
                              ["claude", "codex"].contains(($0["agent"] as? String ?? "").lowercased())
                          }) else { throw AgentDeliveryError.unavailablePane }
                    _ = try HerdrBridge.runHerdr(["pane", "run", paneID, message])
                }.value
                state.isSending = false
                state.status = "Message sent."
                if UserDefaults.standard.bool(forKey: "siso.voice.agentReadBack") {
                    speech.startSpeaking("Outgoing message sent: \(message)")
                }
            } catch {
                state.isSending = false
                state.status = "Could not send. Check Herdr and the selected pane, then try again."
            }
        }
    }

    private enum AgentDeliveryError: Error { case unavailablePane }
}

@MainActor
private final class AgentDeliveryState: ObservableObject {
    struct Pane: Identifiable, Hashable {
        let id: String
        let agent: String
        let label: String
        var title: String { "\(label.isEmpty ? agent.capitalized : label) · \(agent) · \(id)" }
    }

    @Published var text: String
    @Published var selectedPane: String
    @Published var panes: [Pane] = []
    @Published var status = "Loading available agent panes…"
    @Published var isSending = false

    init(text: String, selectedPane: String) {
        self.text = text
        self.selectedPane = selectedPane
    }

    func loadPanes() {
        Task {
            do {
                let listing = try await Task.detached(priority: .userInitiated) {
                    try HerdrBridge.runHerdr(["pane", "list"])
                }.value
                guard let data = listing.data(using: .utf8),
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = root["result"] as? [String: Any],
                      let rawPanes = result["panes"] as? [[String: Any]] else {
                    status = "Could not load agent panes."
                    return
                }
                panes = rawPanes.compactMap { pane in
                    guard let id = pane["pane_id"] as? String,
                          let agent = pane["agent"] as? String,
                          ["claude", "codex"].contains(agent.lowercased()) else { return nil }
                    return Pane(id: id, agent: agent, label: pane["label"] as? String ?? "")
                }
                if !panes.contains(where: { $0.id == selectedPane }) { selectedPane = panes.first?.id ?? "" }
                status = panes.isEmpty ? "No Claude or Codex panes are available." : "Review the message and choose Send."
            } catch {
                status = "Could not load agent panes. Check Herdr."
            }
        }
    }
}

private struct AgentDeliveryEditor: View {
    @ObservedObject var state: AgentDeliveryState
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
            Text("Review outgoing message").sisoText(.cardTitle)
            Text("This sends the edited text to the selected agent pane.")
                .sisoText(.caption)
                .foregroundStyle(SISOTheme.Colors.textMuted)
            TextEditor(text: $state.text)
                .font(SISOTheme.font(.body))
                .padding(6)
                .background(SISOTheme.Colors.cardWhite)
                .overlay(RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius)
                    .stroke(SISOTheme.Colors.hairline))
            HStack {
                Text("Agent pane").sisoText(.caption)
                Picker("Agent pane", selection: $state.selectedPane) {
                    ForEach(state.panes) { pane in Text(pane.title).tag(pane.id) }
                }
                .labelsHidden()
                .disabled(state.panes.isEmpty || state.isSending)
            }
            HStack {
                Text(state.status).sisoText(.caption).foregroundStyle(SISOTheme.Colors.textMuted)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Send", action: onSend)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.panes.isEmpty || state.isSending)
            }
        }
        .padding(SISOTheme.Metrics.s4)
        .background(SISOTheme.Colors.canvas)
        .frame(minWidth: 460, minHeight: 320)
    }
}
