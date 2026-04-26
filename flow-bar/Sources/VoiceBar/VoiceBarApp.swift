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
    lazy var commandRouter = VoiceBarCommandRouter(voiceState: voiceState)
    private lazy var audioLevelMonitor = AudioLevelMonitor { [weak self] level in
        self?.voiceState.setLocalRecordingLevel(level)
    }

    private let pillContextMenuController = PillContextMenuController()
    private let daemonController = VoiceBarDaemonController()

    private var socketServer: SocketServer?
    private var panel: FloatingPillPanel?
    private var mouseMonitor: Any?
    private var moveObserver: Any?
    private var workspaceNotificationObservers: [Any] = []
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
    private lazy var wakeRecoveryCoordinator = WakeRecoveryCoordinator(
        modeProvider: { [weak self] in self?.voiceState.mode ?? .idle },
        restartRecordingAudio: { [weak self] in
            self?.audioLevelMonitor.restart()
        },
        resetHotkeyState: { [weak self] in
            self?.gestureStateMachine.reset()
            self?.voiceState.setHotkeyPhase(.idle)
        }
    )
    /// Track when F6 hold started — for minimum recording duration guard.
    private var holdStartTime: Date?
    /// Whether the hotkey system is enabled.
    var hotkeyEnabled: Bool = false
    var missingHotkeyPermissions: [HotkeyPermission] = []
    /// Whether VoiceBar is snoozed (hidden for a timed period).
    var isSnoozed: Bool = false

    private static let horizontalOffsetKey = "voicebar.horizontalOffset"
    private static let verticalOffsetKey = "voicebar.verticalOffset"

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            commandRouter.handle(url: url)
        }
    }

    /// Handle voicebar:// URLs via Apple Events (kAEGetURL).
    /// This fires when `open voicebar://toggle` is invoked from Karabiner or the shell.
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        NSLog("[VoiceBar] handleGetURLEvent: %@", urlString)
        commandRouter.handle(url: url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register Apple Event handler for voicebar:// URL scheme.
        // Must happen after SwiftUI scene setup completes, so we defer
        // registration to the next run loop iteration.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSAppleEventManager.shared().setEventHandler(
                self,
                andSelector: #selector(handleGetURLEvent(_:withReply:)),
                forEventClass: AEEventClass(kInternetEventClass),
                andEventID: AEEventID(kAEGetURL)
            )
            NSLog("[VoiceBar] Apple Event handler registered for voicebar:// scheme")
        }

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

        // Register with Launch Services so voicebar:// URL scheme works
        // after rebuilds (Launch Services caches bundle→scheme mappings).
        if let bundleURL = Bundle.main.bundleURL as CFURL? {
            let status = LSRegisterURL(bundleURL, true)
            if status != 0 {
                NSLog("[VoiceBar] LSRegisterURL returned %d", status)
            }
        }

        promptForAccessibilityIfNeeded()

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
        _ = daemonController.activateIfNeeded()

        // Hotkey setup — primary user contract is F6; modifier-mode observer is fallback only.
        setupHotkey()
        configureWakeRecovery()

        // Resize panel dynamically when pill content changes
        voiceState.onPillSizeChange = { [weak self] size in
            DispatchQueue.main.async {
                self?.resizePanelToFit(size)
            }
        }

        // Floating pill
        let barView = BarView(state: voiceState, commandRouter: commandRouter)
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
        daemonController.stop()
        socketServer?.stop()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in workspaceNotificationObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceNotificationObservers.removeAll()
    }

    private func configurePillContextMenu() {
        pillContextMenuController.transcriptProvider = { [weak self] in
            self?.voiceState.transcript ?? ""
        }
        pillContextMenuController.recentTranscriptionsProvider = { [weak self] in
            self?.voiceState.recentTranscriptions ?? []
        }
        pillContextMenuController.availableDevicesProvider = {
            MicrophoneDeviceManager.availableInputDevices()
        }
        pillContextMenuController.selectedDeviceIDProvider = {
            MicrophoneDeviceManager.selectedInputDeviceID()
        }
        pillContextMenuController.isSnoozedProvider = { [weak self] in
            self?.isSnoozed ?? false
        }
        pillContextMenuController.onSnooze = { [weak self] in
            self?.snoozeForOneHour()
        }
        pillContextMenuController.onUnsnooze = { [weak self] in
            self?.unsnoozeNow()
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
        isSnoozed = true
        voiceState.snooze()
        panel?.orderOut(nil)

        snoozeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3600))
            guard let self, !Task.isCancelled else { return }
            unsnoozeNow()
        }
    }

    func unsnoozeNow() {
        snoozeTask?.cancel()
        isSnoozed = false
        voiceState.unsnooze()
        panel?.orderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Clean shutdown — exit code 0 so launchd KeepAlive.SuccessfulExit:false
        // does NOT respawn. Only crashes (non-zero) trigger restart.
        snoozeTask?.cancel()
        hotkeyManager?.stop()
        daemonController.stop()
        socketServer?.stop()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running as a menu-bar agent
    }

    private func promptForAccessibilityIfNeeded() {
        // Request Accessibility permission (needed for CGEvent paste-on-record-end).
        // Shows the macOS permission dialog on first launch and after revocation.
        let trusted = VoiceState.isAccessibilityTrusted(prompt: true)
        NSLog("[VoiceBar] Accessibility trusted on launch: %@", trusted ? "YES" : "NO — paste will not work")
        guard !trusted else { return }

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "VoiceBar needs Accessibility permission to paste"
            alert.informativeText = "Grant VoiceBar in System Settings > Privacy & Security > Accessibility, then try paste again."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
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
            NSLog("[VoiceBar] Hotkey hold start — starting recording")
            holdStartTime = Date()
            handleHotkeyHoldStart()
        }

        // Hold end → stop the active PTT recording and transcribe whatever was captured.
        gestureStateMachine.onHoldEnd = { [weak self] in
            guard let self else { return }
            let holdDuration = Date().timeIntervalSince(holdStartTime ?? Date())
            NSLog("[VoiceBar] Hotkey hold end (%.1fs) — stopping recording", holdDuration)
            handleHotkeyHoldEnd(holdDuration: holdDuration)
        }

        // Single tap is intentionally ignored on the fallback modifier-mode lane.
        gestureStateMachine.onSingleTap = {
            NSLog("[VoiceBar] Hotkey single tap — ignored")
        }

        // Double tap remains a fallback modifier-mode toggle lane, not the primary F6 contract.
        gestureStateMachine.onDoubleTap = { [weak self] in
            guard let self else { return }
            if voiceState.mode == .idle {
                NSLog("[VoiceBar] Hotkey double tap — starting hands-free recording")
            } else if voiceState.mode == .recording {
                NSLog("[VoiceBar] Hotkey double tap — stopping hands-free recording")
            }
            handleHotkeyDoubleTap()
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
            NSLog(VoiceBarHotkeyContract.activationLogMessage)
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

    func handleHotkeyHoldStart() {
        commandRouter.handleHotkeyHoldStart()
    }

    func handleHotkeyHoldEnd(holdDuration: TimeInterval) {
        commandRouter.handleHotkeyHoldEnd(holdDuration: holdDuration)
    }

    func handleHotkeyDoubleTap() {
        commandRouter.handleHotkeyDoubleTap()
    }

    private func configureWakeRecovery() {
        let center = NSWorkspace.shared.notificationCenter
        let willSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.wakeRecoveryCoordinator.handleWillSleep()
        }
        let didWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.wakeRecoveryCoordinator.handleDidWake()
        }
        workspaceNotificationObservers = [willSleepObserver, didWakeObserver]
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
            isSnoozed: isSnoozed,
            openSettings: { [weak self] in self?.openSettingsWindow() },
            snoozeToggle: { [weak self] in
                guard let self else { return }
                if isSnoozed { unsnoozeNow() } else { snoozeForOneHour() }
            },
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

        Settings {
            SettingsView(
                hotkeyEnabled: appDelegate.hotkeyEnabled,
                missingPermissions: appDelegate.missingHotkeyPermissions,
                availableDevices: { MicrophoneDeviceManager.availableInputDevices() },
                selectedDeviceID: { MicrophoneDeviceManager.selectedInputDeviceID() },
                onSelectDevice: { MicrophoneDeviceManager.selectInputDevice(id: $0) }
            )
        }
    }
}
