import Foundation

/// HerdrBridge — drives the live herdr instance from the SISO Voice app to talk to JARVIS.
///
/// JARVIS lives as two panes in the "JARVIS" herdr workspace: an Opus coordinator (the one Shaan
/// talks to) and a Codex worker, both booted from `~/SISO_Workspace/.agents/jarvis`. This bridge
/// resolves the Opus pane fresh every call (pane ids renumber when panes close — never cache one),
/// types a message into it, and reads the reply back.
///
/// IMPORTANT: use the REAL herdr binary at ~/.local/bin/herdr. The /opt/homebrew/bin/cmux binary
/// talks to a different/stale socket and cannot see the live workspaces. (Learned the hard way.)
/// The app is not sandboxed and already shells out via Process(), so this is fine.
enum HerdrBridge {

    static let herdrPath = "\(NSHomeDirectory())/.local/bin/herdr"
    static let jarvisWorkspaceId = "w6536f558caca12"
    static let jarvisHomeMarker = ".agents/jarvis"
    static let jarvisWorkspaceLabel = "JARVIS"
    static let jarvisOpusPaneLabel = "JARVIS-OPUS"

    enum BridgeError: Error, CustomStringConvertible {
        case bridgeDisabled
        case herdrMissing
        case jarvisPaneNotFound
        case commandFailed(String)
        var description: String {
            switch self {
            case .bridgeDisabled: return "SISO Voice -> JARVIS bridge is disabled"
            case .herdrMissing: return "herdr binary not found at \(herdrPath)"
            case .jarvisPaneNotFound: return "No live JARVIS Opus pane (label '\(jarvisOpusPaneLabel)' in workspace '\(jarvisWorkspaceId)')"
            case .commandFailed(let m): return "herdr command failed: \(m)"
            }
        }
    }

    private struct OpusPaneTarget {
        let paneId: String
        let workspaceId: String
        let tabId: String?
    }

    // MARK: - Pane resolution

    /// Resolve the JARVIS Opus pane id fresh. Opus = a `claude` agent whose cwd is the jarvis home,
    /// in the workspace labelled "JARVIS". Returns nil if not found (JARVIS not booted).
    static func resolveOpusPane() throws -> String? {
        return try resolveOpusPaneTarget()?.paneId
    }

    /// Reveal the real live JARVIS pane in herdr. This does not embed or mirror a terminal; it
    /// focuses herdr's existing workspace/tab/pane and brings the terminal host app forward.
    @discardableResult
    static func revealOpusPane() throws -> String {
        guard let target = try resolveOpusPaneTarget() else {
            throw BridgeError.jarvisPaneNotFound
        }

        _ = try runHerdr(["workspace", "focus", target.workspaceId])
        if let tabId = target.tabId {
            _ = try runHerdr(["tab", "focus", tabId])
        }
        _ = try runHerdr(["agent", "focus", target.paneId])
        foregroundHerdrHost()
        return target.paneId
    }

    private static func resolveOpusPaneTarget() throws -> OpusPaneTarget? {
        let panesJSON = try runHerdr(["pane", "list"])
        guard let data = panesJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let panes = result["panes"] as? [[String: Any]] else {
            return nil
        }

        for pane in panes {
            let label = (pane["label"] as? String) ?? ""
            let wsid = (pane["workspace_id"] as? String) ?? ""
            if wsid == jarvisWorkspaceId, label == jarvisOpusPaneLabel,
               let target = opusPaneTarget(from: pane) {
                return target
            }
        }

        // Map workspace_id -> label so we can match on the JARVIS workspace.
        let jarvisWorkspaceIds = try jarvisWorkspaceIds()

        for pane in panes {
            let label = (pane["label"] as? String) ?? ""
            let wsid = (pane["workspace_id"] as? String) ?? ""
            if jarvisWorkspaceIds.contains(wsid), label == jarvisOpusPaneLabel,
               let target = opusPaneTarget(from: pane) {
                return target
            }
        }

        for pane in panes {
            let cwd = (pane["cwd"] as? String) ?? (pane["foreground_cwd"] as? String) ?? ""
            let agent = (pane["agent"] as? String) ?? ""
            let wsid = (pane["workspace_id"] as? String) ?? ""
            let inJarvisWs = jarvisWorkspaceIds.contains(wsid)
            // Opus = the claude session homed in .agents/jarvis (Codex is agent != claude).
            if inJarvisWs, agent == "claude", cwd.contains(jarvisHomeMarker),
               let target = opusPaneTarget(from: pane) {
                return target
            }
        }
        // Fallback: any claude pane whose cwd is the jarvis home, even if label lookup missed.
        for pane in panes {
            let cwd = (pane["cwd"] as? String) ?? ""
            let agent = (pane["agent"] as? String) ?? ""
            if agent == "claude", cwd.contains(jarvisHomeMarker),
               let target = opusPaneTarget(from: pane) {
                return target
            }
        }
        return nil
    }

    private static func opusPaneTarget(from pane: [String: Any]) -> OpusPaneTarget? {
        guard let paneId = pane["pane_id"] as? String,
              let workspaceId = pane["workspace_id"] as? String else {
            return nil
        }
        return OpusPaneTarget(
            paneId: paneId,
            workspaceId: workspaceId,
            tabId: pane["tab_id"] as? String
        )
    }

    /// workspace_ids whose label is "JARVIS", plus the known standing JARVIS workspace id.
    private static func jarvisWorkspaceIds() throws -> Set<String> {
        let json = try runHerdr(["workspace", "list"])
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let wss = result["workspaces"] as? [[String: Any]] else {
            return [jarvisWorkspaceId]
        }
        var ids = Set<String>([jarvisWorkspaceId])
        for ws in wss {
            if (ws["label"] as? String) == jarvisWorkspaceLabel, let id = ws["workspace_id"] as? String {
                ids.insert(id)
            }
        }
        return ids
    }

    // MARK: - Send + read

    /// Send a message to the JARVIS Opus pane (types text + presses Enter atomically via `pane run`).
    static func send(_ message: String, toPane pane: String) throws {
        guard SISOVoiceConfig.jarvisHerdrBridgeEnabled else {
            throw BridgeError.bridgeDisabled
        }
        _ = try runHerdr(["pane", "run", pane, message])
    }

    /// Read the recent rendered scrollback of a pane.
    static func readPane(_ pane: String, lines: Int = 40) throws -> String {
        return try runHerdr(["pane", "read", pane, "--source", "recent", "--lines", "\(lines)"])
    }

    // MARK: - Process plumbing

    @discardableResult
    static func runHerdr(_ args: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: herdrPath) else {
            throw BridgeError.herdrMissing
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: herdrPath)
        proc.arguments = args
        // herdr needs a sane PATH for its own socket helper resolution.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env

        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw BridgeError.commandFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    private static func foregroundHerdrHost() {
        let bundleIds = [
            "com.cmuxterm.app",
            "com.openai.codex",
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty"
        ]
        for bundleId in bundleIds where openApplication(["-b", bundleId]) {
            return
        }

        let appNames = ["cmux", "Codex", "Terminal", "iTerm", "Ghostty"]
        for appName in appNames where openApplication(["-a", appName]) {
            return
        }
    }

    private static func openApplication(_ args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
