import SwiftUI
import ServiceManagement

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState(historyFetchLimit: CommandLine.arguments.contains("--resident") ? 10 : 1_000)
    var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var mainWindow: NSWindow?
    private var audioRetentionTimer: Timer?
    private let isResidentMode = CommandLine.arguments.contains("--resident")
    private let isStorageMaintenanceMode = CommandLine.arguments.contains("--storage-maintenance-only")
    private let isLoginUnregisterMode = CommandLine.arguments.contains("--unregister-login-item")
    /// Started by the standalone LaunchAgent (install-standalone.sh); launchd sets
    /// XPC_SERVICE_NAME to the job label.
    private let isLaunchAgentManaged = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.siso.voice"
    // SISO Voice: the ONE right-edge surface — thin bar → hover → icons → a single
    // tabbed floating panel (Internal | JARVIS). Replaces the old per-destination
    // floating chips (SidebarDrawerManager), which stacked 3 separate tabs.
    let edgeDock = EdgeDockController()

    /// SISO Voice ships standalone (~/Applications, LaunchAgent com.siso.voice). Older
    /// SISO Internal builds still embed a copy and submit it as the KeepAlive launchd
    /// job `com.siso.voice.runtime` when no "SISO Voice" process exists. If that won the
    /// race at login, remove the job (which also stops its process) so exactly one
    /// dictation runtime owns the hotkey. Terminating the process alone would just
    /// make launchd respawn it.
    private func retireEmbeddedRuntimeIfStandalone() {
        guard !Bundle.main.bundlePath.contains("SISO Internal.app/") else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.siso.voice")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        let remove = Process()
        remove.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        remove.arguments = ["remove", "com.siso.voice.runtime"]
        try? remove.run()
        remove.waitUntilExit()
        for application in others where !application.isTerminated {
            application.forceTerminate()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isLoginUnregisterMode {
            try? SMAppService.mainApp.unregister()
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: "com.siso.voice")
                where application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                application.terminate()
            }
            NSApp.terminate(nil)
            return
        }

        retireEmbeddedRuntimeIfStandalone()

        // `open -b com.siso.voice` / Dock clicks go through reopen; this is the
        // scriptable path for agents and CLI: post the distributed notification
        // "com.siso.voice.showMainWindow".
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.siso.voice.showMainWindow"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                NSLog("[SISOVoice] showMainWindow via distributed notification")
                self?.handleShowMainWindow()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetup),
            name: .showSetup,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowMainWindow),
            name: .showMainWindow,
            object: nil
        )
        AppState.writeRecordingStateFlag(false)

        // Operational one-shot: run retention without starting hotkeys, UI, or
        // any visual surface. Useful for cleaning an existing install safely.
        if isStorageMaintenanceMode {
            Task { @MainActor [appState] in
                await appState.purgeExpiredAudio()
                NSApp.terminate(nil)
            }
            return
        }

        // The SISO Internal desktop shell owns the main window and login launch.
        // Its bundled SISO Voice runtime starts with --resident so the proven
        // hotkeys and transcription pipeline remain resident without also
        // opening the legacy voice dashboard or edge dock.
        if isResidentMode {
            NSApp.setActivationPolicy(.accessory)
        } else {
            edgeDock.start()
        }

        // SISO Voice Dev: setup window is never auto-shown on launch.
        // hasCompletedSetup defaults to true (AppState.swift), so this branch
        // is effectively dead, but guard it explicitly here too so a stale
        // UserDefaults value on a fresh bundle can't slip through.
        if false && !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()
            // No UpdateManager checks: it polls upstream zachlatta/freeflow releases
            // and would offer to replace SISO Voice with vanilla FreeFlow.

            if !AXIsProcessTrusted() {
                appState.showAccessibilityAlert()
            }

            // Standalone SISO Voice keeps its dashboard. SISO Internal supplies
            // the desktop window when this process runs in resident mode.
            // Under the LaunchAgent (login / crash relaunch) stay quiet; a Dock or
            // Finder open reaches applicationShouldHandleReopen and shows it.
            if !isResidentMode && !isLaunchAgentManaged {
                handleShowMainWindow()
            }

            // SISO Voice: always run on this MacBook — auto-register as a login
            // item so the resident transcription service comes back on every boot.
            // Idempotent; only registers if not already enabled. The LaunchAgent
            // already starts it at login, so a login item there would double-launch.
            if (isResidentMode || isLaunchAgentManaged), SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            } else if !isResidentMode, !isLaunchAgentManaged, SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }

            JarvisReplyPresenter.shared.start(overlayManager: appState.overlayManager)
            if isResidentMode {
                Task { @MainActor [appState] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    await appState.purgeExpiredAudio()
                }
            } else {
                Task { @MainActor [appState] in
                    await appState.recoverUnfinishedTranscriptions()
                    await appState.purgeExpiredAudio()
                }
            }
            startAudioRetentionTimer()
            // Surface the dock's JARVIS tab whenever something is sent to JARVIS, so Shaan sees the reply.
            NotificationCenter.default.addObserver(
                forName: TranscriptRouter.didSendToJarvis, object: nil, queue: .main
            ) { [weak self] _ in
                self?.edgeDock.openDock(tab: .jarvis)
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleToggleSidebar),
                name: .toggleSidebar, object: nil
            )
        }

    }

    private func startAudioRetentionTimer() {
        audioRetentionTimer?.invalidate()
        audioRetentionTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(24 * 60 * 60),
            repeats: true
        ) { [weak self] _ in
            guard let appState = self?.appState else { return }
            Task { @MainActor in
                await appState.purgeExpiredAudio()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSLog("[SISOVoice] reopen resident=%d setup=%d flag=%d", isResidentMode ? 1 : 0, appState.hasCompletedSetup ? 1 : 0, flag ? 1 : 0)
        guard !isResidentMode else { return false }
        guard appState.hasCompletedSetup else { return true }
        // SISO Voice: Dock-icon click reopens the main dashboard. Not keyed on
        // `flag`: the always-visible edge-dock bar counts as a visible window.
        if mainWindow?.isVisible != true {
            handleShowMainWindow()
        }
        return true
    }

    @objc func handleShowSetup() {
        // Single wizard at a time — opening a second leaks the first's
        // willClose observer and breaks the bail-restore.
        if let existing = setupWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let wasCompleted = appState.hasCompletedSetup
        appState.hasCompletedSetup = false
        appState.stopAccessibilityPolling()
        appState.stopHotkeyMonitoring()
        showSetupWindow()

        // Restore prior state if the user closes the wizard without completing.
        // completeSetup() flips hasCompletedSetup back to true before window.close(),
        // so the !hasCompletedSetup check below correctly skips the restore there.
        if wasCompleted, let window = setupWindow {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                if !self.appState.hasCompletedSetup {
                    self.appState.hasCompletedSetup = true
                    self.appState.startHotkeyMonitoring()
                    self.appState.startAccessibilityPolling()
                    NSApp.setActivationPolicy(.regular) // SISO Voice: stay a Dock app, don't drop to menubar-only
                }
                self.setupWindow = nil
            }
        }
    }

    @objc private func handleShowSettings() {
        showSettingsWindow()
    }

    // SISO Voice: the Aqua-style main dashboard (history, stats, dictionary).
    @objc private func handleToggleSidebar() {
        guard !isResidentMode else { return }
        edgeDock.openDock(tab: .internalWeb)
    }

    @objc private func handleShowMainWindow() {
        guard !isResidentMode else { return }
        NSApp.setActivationPolicy(.regular)

        if let mainWindow, mainWindow.isVisible {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // UI v2: inject AppState so pages (Home/Settings keycap editor) read/write
        // live prefs — single source of truth, and the hotkey-revert fix.
        let hostingView = NSHostingView(rootView: MainWindowView().environmentObject(appState))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        mainWindow = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            if self?.setupWindow == nil && self?.settingsWindow == nil {
                NSApp.setActivationPolicy(.regular) // SISO Voice: stay a Dock app, don't drop to menubar-only
            }
            self?.mainWindow = nil
        }
    }

    private func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)

        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if settingsWindow == nil {
            presentSettingsWindow()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentSettingsWindow() {
        let settingsView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            if self?.setupWindow == nil {
                NSApp.setActivationPolicy(.regular) // SISO Voice: stay a Dock app, don't drop to menubar-only
            }
            self?.settingsWindow = nil
        }
    }


    func showSetupWindow() {
        NSApp.setActivationPolicy(.regular)

        let setupView = SetupView(onComplete: { [weak self] in
            self?.completeSetup()
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: setupView)
        window.minSize = NSSize(width: 520, height: 680)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        self.setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func completeSetup() {
        appState.hasCompletedSetup = true
        setupWindow?.close()
        setupWindow = nil
        NSApp.setActivationPolicy(.regular) // SISO Voice: stay a Dock app, don't drop to menubar-only
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
        if !isResidentMode {
            Task { @MainActor in
                UpdateManager.shared.startPeriodicChecks()
            }
        }

        if !AXIsProcessTrusted() {
            appState.showAccessibilityAlert()
        }
    }
}
