// VoiceBarApp.swift — Entry point for Voice Bar.
//
// Wires together: VoiceState, SocketServer, FloatingPillPanel, BarView.
// No Dock icon (.accessory activation policy). Menu bar icon for status + quit.
// Tracks mouse across screens — pill follows the cursor.
//
// AIDEV-NOTE: Architecture inversion (Phase 0) — VoiceBar is the persistent
// server on VoiceLayerPaths.socketPath. MCP servers connect as clients.
// All discovery file logic removed (no more polling, no file watchers).

import AppKit
import SwiftUI

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let voiceState = VoiceState()
    private lazy var audioLevelMonitor = AudioLevelMonitor { [weak self] level in
        self?.voiceState.setLocalRecordingLevel(level)
    }

    private let pillContextMenuController = PillContextMenuController()
    private let daemonLauncher = VoiceBarDaemonLauncher()

    private var socketServer: SocketServer?
    private var panel: FloatingPillPanel?
    private var mouseMonitor: Any?
    private var moveObserver: Any?
    private var snoozeTask: Task<Void, Never>?
    /// Track which screen the pill is on to avoid unnecessary repositioning.
    private var currentScreenIndex: Int = -1
    /// Saved offsets (0.0–1.0) for pill positioning on screen.
    private var horizontalOffset: CGFloat = Theme.horizontalOffset
    private var verticalOffset: CGFloat? // nil = use default bottomPadding

    /// Last reported pill size — used to avoid layout loops.
    private var lastPillSize: CGSize = .zero

    /// Hotkey management — CGEventTap + gesture state machine.
    private var hotkeyManager: HotkeyManager?
    private let gestureStateMachine = GestureStateMachine()
    /// Whether the hotkey system is enabled.
    var hotkeyEnabled: Bool = false
    var missingHotkeyPermissions: [HotkeyPermission] = []

    private static let horizontalOffsetKey = "voicebar.horizontalOffset"
    private static let verticalOffsetKey = "voicebar.verticalOffset"

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "voicebar" else { continue }
            let command = url.host ?? ""
            NSLog("[VoiceBar] URL scheme received: voicebar://%@", command)
            switch command {
            case "toggle":
                // Toggle hands-free recording (same as double-tap)
                if voiceState.mode == .idle {
                    voiceState.record()
                } else if voiceState.mode == .recording {
                    voiceState.stop()
                }
            case "start-recording":
                if voiceState.mode == .idle { voiceState.record() }
            case "stop-recording":
                if voiceState.mode == .recording { voiceState.stop() }
            default:
                NSLog("[VoiceBar] Unknown URL command: %@", command)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Singleton guard — if another VoiceBar is already running, quit immediately.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        let others = running.filter { $0.processIdentifier != myPID && !$0.isTerminated }
        if !others.isEmpty {
            NSLog("[VoiceBar] Another instance already running (PID %d) — exiting", others[0].processIdentifier)
            // Give a moment for the log to flush
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // No Dock icon (LSUIElement equivalent)
        NSApp.setActivationPolicy(.accessory)

        // Request Accessibility permission (needed for CGEvent paste-on-record-end).
        // Shows the macOS permission dialog on first launch.
        let axTrusted = AXIsProcessTrusted()
        NSLog("[VoiceBar] AXIsProcessTrusted() on launch: %@", axTrusted ? "YES" : "NO")
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(axOptions)
        NSLog("[VoiceBar] Accessibility trusted: %@", trusted ? "YES" : "NO — paste will not work")

        audioLevelMonitor.prepare()

        // Socket server — listens on VoiceLayerPaths.socketPath
        let server = SocketServer(state: voiceState)
        socketServer = server

        // Wire the send-command closure so BarView buttons -> socket -> MCP clients
        voiceState.sendCommand = { [weak server] cmd in
            server?.sendToAll(command: cmd)
        }
        voiceState.onModeChange = { [weak self] mode in
            self?.handleVoiceModeChange(mode)
        }
        configurePillContextMenu()

        server.start()
        daemonLauncher.startIfNeeded()

        // Hotkey setup — Cmd+F6 hold for push-to-talk, double-tap for hands-free toggle
        setupHotkey()

        // Resize panel dynamically when pill content changes
        voiceState.onPillSizeChange = { [weak self] size in
            DispatchQueue.main.async {
                self?.resizePanelToFit(size)
            }
        }

        // Floating pill
        let barView = BarView(state: voiceState)
        let hosting = NSHostingView(rootView: barView)
        hosting.frame = NSRect(
            x: 0, y: 0,
            width: Theme.panelWidth,
            height: 300
        )

        // Load saved position
        if let saved = UserDefaults.standard.object(forKey: Self.horizontalOffsetKey) as? Double {
            horizontalOffset = max(0.05, min(0.95, CGFloat(saved)))
        }
        if let saved = UserDefaults.standard.object(forKey: Self.verticalOffsetKey) as? Double {
            verticalOffset = max(0.0, min(0.95, CGFloat(saved)))
        }

        let pill = FloatingPillPanel(content: hosting)
        pill.contextMenuProvider = { [weak self] in
            self?.pillContextMenuController.makeMenu() ?? NSMenu()
        }
        pill.positionOnScreen(
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset
        )
        pill.orderFront(nil)
        panel = pill

        // Save position when user drags the pill
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: pill,
            queue: .main
        ) { [weak self] _ in
            self?.savePanelPosition()
        }

        // Track mouse across screens — move pill to whichever monitor the cursor is on
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        snoozeTask?.cancel()
        hotkeyManager?.stop()
        daemonLauncher.stop()
        socketServer?.stop()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func configurePillContextMenu() {
        pillContextMenuController.transcriptProvider = { [weak self] in
            self?.voiceState.transcript ?? ""
        }
        pillContextMenuController.availableDevicesProvider = {
            MicrophoneDeviceManager.availableInputDevices()
        }
        pillContextMenuController.selectedDeviceIDProvider = {
            MicrophoneDeviceManager.selectedInputDeviceID()
        }
        pillContextMenuController.onSnooze = { [weak self] in
            self?.snoozeForOneHour()
        }
        pillContextMenuController.onSelectDevice = { [weak self] deviceID in
            guard MicrophoneDeviceManager.selectInputDevice(id: deviceID) else { return }
            if self?.voiceState.mode == .recording {
                self?.audioLevelMonitor.restart()
            }
        }
        pillContextMenuController.onPasteLastTranscript = { [weak self] in
            self?.voiceState.repasteLastTranscript()
        }
        pillContextMenuController.onQuit = {
            NSApplication.shared.terminate(nil)
        }
    }

    private func snoozeForOneHour() {
        snoozeTask?.cancel()
        voiceState.snooze()
        panel?.orderOut(nil)

        snoozeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3600))
            guard let self, !Task.isCancelled else { return }
            voiceState.unsnooze()
            panel?.orderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running as a menu-bar agent
    }

    // MARK: - Hotkey setup

    /// Wire gesture callbacks to VoiceState and start the event tap.
    private func setupHotkey() {
        // Hold start → push-to-talk recording
        gestureStateMachine.onPreviewPhaseChange = { [weak self] phase in
            self?.voiceState.setHotkeyPhase(phase)
        }

        gestureStateMachine.onHoldStart = { [weak self] in
            guard let self else { return }
            NSLog("[VoiceBar] Hotkey hold start — starting push-to-talk recording")
            voiceState.record()
        }

        // Hold end → stop recording
        gestureStateMachine.onHoldEnd = { [weak self] in
            guard let self else { return }
            NSLog("[VoiceBar] Hotkey hold end — stopping recording")
            voiceState.stop()
        }

        // Single tap is intentionally ignored so double-tap can toggle hands-free mode.
        gestureStateMachine.onSingleTap = {
            NSLog("[VoiceBar] Hotkey single tap — ignored")
        }

        // Double tap → toggle hands-free recording
        gestureStateMachine.onDoubleTap = { [weak self] in
            guard let self else { return }
            if voiceState.mode == .idle {
                NSLog("[VoiceBar] Hotkey double tap — starting hands-free recording")
                voiceState.record()
            } else if voiceState.mode == .recording {
                NSLog("[VoiceBar] Hotkey double tap — stopping hands-free recording")
                voiceState.stop()
            }
        }

        let manager = HotkeyManager(gesture: gestureStateMachine)
        manager.onPasteLastTranscript = { [weak self] in
            self?.voiceState.repasteLastTranscript()
        }
        if manager.start() {
            hotkeyManager = manager
            hotkeyEnabled = true
            missingHotkeyPermissions = []
            voiceState.setHotkeyEnabled(true)
            NSLog("[VoiceBar] Hotkey system active — Cmd+F6 hold for push-to-talk, double-tap for hands-free")
        } else {
            hotkeyEnabled = false
            missingHotkeyPermissions = manager.permissionStatus.missingPermissions
            voiceState.setHotkeyEnabled(false)
            NSLog(
                "[VoiceBar] Hotkey system unavailable — missing permissions: %@",
                missingHotkeyPermissions.map {
                    switch $0 {
                    case .inputMonitoring: "Input Monitoring"
                    case .accessibility: "Accessibility"
                    }
                }.joined(separator: ", ")
            )
        }
    }

    private func handleVoiceModeChange(_ mode: VoiceMode) {
        switch mode {
        case .recording:
            audioLevelMonitor.start()
        default:
            audioLevelMonitor.stop()
        }
    }

    // MARK: - Dynamic panel sizing

    /// Resize the panel to tightly fit the pill content, anchored at bottom-center.
    /// Called via onPillSizeChange callback from the SwiftUI GeometryReader.
    private func resizePanelToFit(_ pillSize: CGSize) {
        guard let panel else { return }
        // Avoid layout loops — only resize on meaningful change
        let epsilon: CGFloat = 2
        if abs(pillSize.width - lastPillSize.width) < epsilon,
           abs(pillSize.height - lastPillSize.height) < epsilon {
            return
        }
        lastPillSize = pillSize

        let padding = Theme.panelPadding
        let newWidth = max(pillSize.width + padding * 2, 50)
        let newHeight = max(pillSize.height + padding * 2, 30)

        // Anchor at visual center — pill stays in place across state changes
        let oldFrame = panel.frame
        let centerX = oldFrame.midX
        let centerY = oldFrame.midY
        let newFrame = NSRect(
            x: centerX - newWidth / 2,
            y: centerY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - Mouse tracking

    /// Reposition pill when mouse moves to a different screen.
    private func handleMouseMoved() {
        let mouseLocation = NSEvent.mouseLocation
        // Capture screens array once to avoid TOCTOU race if a display disconnects.
        let screens = NSScreen.screens
        guard let targetScreen = screens.firstIndex(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) else { return }

        // Only reposition when the screen actually changes
        if targetScreen != currentScreenIndex {
            currentScreenIndex = targetScreen
            panel?.positionOnScreen(
                screens[targetScreen],
                horizontalOffset: horizontalOffset,
                verticalOffset: verticalOffset
            )
        }
    }

    // MARK: - Drag persistence

    /// Save the pill's position as percentages of screen dimensions.
    private func savePanelPosition() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let hOffset = (panel.frame.midX - visible.origin.x) / visible.width
        let vOffset = (panel.frame.origin.y - visible.origin.y) / visible.height
        horizontalOffset = max(0.05, min(0.95, CGFloat(hOffset)))
        verticalOffset = max(0.0, min(0.95, CGFloat(vOffset)))
        UserDefaults.standard.set(Double(horizontalOffset), forKey: Self.horizontalOffsetKey)
        UserDefaults.standard.set(Double(verticalOffset!), forKey: Self.verticalOffsetKey)
    }

    func quickMenuActions() -> [VoiceBarMenuAction] {
        VoiceBarMenu.quickActions(
            openSettings: { [weak self] in self?.openSettingsWindow() },
            hideForOneHour: { [weak self] in self?.snoozeForOneHour() },
            pasteLastTranscript: { [weak self] in self?.voiceState.repasteLastTranscript() },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - SwiftUI App entry point

@main
struct VoiceBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar icon + dropdown
        MenuBarExtra("VoiceBar", systemImage: "waveform.circle.fill") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appDelegate.voiceState.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(appDelegate.voiceState.isConnected ? "Connected" : "Disconnected")
                        .font(.system(.caption, weight: .medium))
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(appDelegate.hotkeyEnabled ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text(
                        VoiceBarPresentation.hotkeyPermissionHint(
                            hotkeyEnabled: appDelegate.hotkeyEnabled,
                            missingPermissions: appDelegate.missingHotkeyPermissions
                        )
                    )
                    .font(.system(.caption, weight: .medium))
                }
                Divider()
                ForEach(appDelegate.quickMenuActions()) { action in
                    Button(action.title) {
                        action.perform()
                    }
                }
            }
            .padding(8)
        }

        // Empty Settings scene satisfies the "at least one Scene" requirement
        Settings {
            EmptyView()
        }
    }
}
