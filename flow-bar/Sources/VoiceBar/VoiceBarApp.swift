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
import Darwin
import SwiftUI

private let legacySocketHotkeyDuplicateWindow: TimeInterval = 0.75

// MARK: - App Delegate

enum HotkeyInputSource {
    case native
    case legacySocket
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let voiceState = VoiceState()
    lazy var commandRouter = VoiceBarCommandRouter(
        voiceState: voiceState,
        resetHotkeyState: { [weak self] in
            self?.resetHotkeyTracking()
        }
    )
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
    /// Saved offsets (0.0-1.0) for pill center positioning on screen.
    private var horizontalOffset: CGFloat = Theme.horizontalOffset
    private var verticalOffset: CGFloat? // nil = fixed top-center island placement

    /// Last transition seen by the panel resize path. Used to decide whether a
    /// given geometry change should tween instead of snap.
    private var previousVoiceMode: VoiceMode = .idle
    private var currentVoiceMode: VoiceMode = .idle

    /// Hotkey management — CGEventTap + gesture state machine.
    private var hotkeyManager: HotkeyManager?
    private let gestureStateMachine = GestureStateMachine()
    private lazy var wakeRecoveryCoordinator = WakeRecoveryCoordinator(
        modeProvider: { [weak self] in self?.voiceState.mode ?? .idle },
        restartRecordingAudio: { [weak self] in
            self?.audioLevelMonitor.restart()
        },
        resetHotkeyState: { [weak self] in
            self?.resetHotkeyTracking()
        }
    )
    /// Track when F5 hold started — for minimum recording duration guard.
    private var holdStartTime: Date?
    /// Last moment any hotkey input source was accepted.
    private var lastHotkeyActivityAt: TimeInterval?
    private var lastHotkeyActivitySource: HotkeyInputSource?
    private var activeHotkeySource: HotkeyInputSource?
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
        signal(SIGPIPE, SIG_IGN)
        NSLog("[VoiceBar] SIGPIPE ignored process-wide")

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
        server.onControlCommand = { [weak self] command in
            self?.handleLocalControlCommand(command)
        }

        // Wire the send-command closure so BarView buttons -> socket -> MCP clients
        voiceState.sendCommand = { [weak server] cmd in
            server?.sendToAll(command: cmd)
        }
        voiceState.onModeChange = { [weak self] mode in
            self?.handleVoiceModeChange(mode)
        }
        voiceState.onPanelLayoutChange = { [weak self] in
            self?.applyPanelLayout(animated: true)
        }
        voiceState.diagnosticLogger = { [weak self] event, details in
            self?.logDiagnostic(event: event, details: details)
        }
        configurePillContextMenu()

        server.start()
        _ = daemonController.activateIfNeeded()

        // Hotkey setup — F5 hold for push-to-talk.
        setupHotkey()
        configureWakeRecovery()

        // Floating pill
        let initialLayout = Self.panelLayout(for: voiceState)
        let barView = BarView(state: voiceState, commandRouter: commandRouter)
        let hosting = PillHostingView(rootView: barView)
        hosting.activeHitRectProvider = { [weak self] in
            Self.panelLayout(for: self?.voiceState).activeHitRect
        }
        hosting.frame = NSRect(
            x: 0, y: 0,
            width: initialLayout.panelSize.width,
            height: initialLayout.panelSize.height
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
        pill.activeHitRectProvider = { [weak self] in
            Self.panelLayout(for: self?.voiceState).activeHitRect
        }
        pill.positionOnScreen(
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset
        )
        pill.isMovableByWindowBackground = VoiceBarPresentation.isPanelDraggable(mode: voiceState.mode)
        pill.orderFront(nil)
        panel = pill
        applyPanelLayout(animated: false)
        if let panelScreen = pill.screen {
            currentScreenIndex = NSScreen.screens.firstIndex(of: panelScreen) ?? currentScreenIndex
        }

        // Save position when user drags the pill
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: pill,
            queue: .main
        ) { [weak self] _ in
            guard NSEvent.pressedMouseButtons != 0 else { return }
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
            self?.voiceState.latestReusableTranscript ?? ""
        }
        pillContextMenuController.recentTranscriptionsProvider = { [weak self] in
            self?.voiceState.recentTranscriptions ?? []
        }
        pillContextMenuController.transcriptionVocabularyTermsProvider = { [weak self] in
            self?.voiceState.transcriptionVocabularyTerms ?? []
        }
        pillContextMenuController.transcriptionVocabularyAliasesProvider = { [weak self] in
            self?.voiceState.transcriptionVocabularyAliases ?? []
        }
        pillContextMenuController.availableDevicesProvider = {
            MicrophoneDeviceManager.availableInputDevices()
        }
        pillContextMenuController.selectedDeviceIDProvider = {
            MicrophoneDeviceManager.selectedInputDeviceID()
        }
        pillContextMenuController.onOpenSettings = { [weak self] in
            self?.openSettingsWindow()
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
            self?.logDiagnostic(event: "context_menu_paste_last_transcript_tapped")
            self?.voiceState.repasteLastTranscript()
        }
        pillContextMenuController.onCopyLastTranscript = { [weak self] in
            self?.logDiagnostic(event: "context_menu_copy_last_transcript_tapped")
            self?.voiceState.copyLastTranscript()
        }
        pillContextMenuController.onPasteTranscript = { [weak self] transcript in
            self?.logDiagnostic(event: "context_menu_paste_recent_transcript_tapped")
            self?.voiceState.repasteTranscript(transcript)
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
        configureHotkeyCallbacks()

        let manager = HotkeyManager(gesture: gestureStateMachine)
        manager.onKeyDown = { [weak self] in
            self?.handleHotkeyKeyDown(from: .native)
        }
        manager.onKeyUp = { [weak self] in
            self?.handleHotkeyKeyUp(from: .native)
        }
        manager.onCancel = { [weak self] in
            self?.noteHotkeyActivity(from: .native)
            self?.commandRouter.handleCancel()
        }
        manager.onPasteLastTranscript = { [weak self] in
            self?.voiceState.repasteLastTranscript()
        }
        if manager.start() {
            hotkeyManager = manager
            hotkeyEnabled = true
            missingHotkeyPermissions = []
            voiceState.setHotkeyEnabled(true)
            NSLog("%@", VoiceBarHotkeyContract.activationLogMessage)
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

    func configureHotkeyCallbacksForTesting() {
        configureHotkeyCallbacks()
    }

    private func configureHotkeyCallbacks() {
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

        // Single/double tap are intentionally not assigned in the immediate PTT model.
        gestureStateMachine.onSingleTap = {
            NSLog("[VoiceBar] Hotkey single tap — not assigned")
        }

        gestureStateMachine.onDoubleTap = { [weak self] in
            NSLog("[VoiceBar] Hotkey double tap — locking active recording")
            self?.handleHotkeyDoubleTap()
        }

        gestureStateMachine.onCancel = { [weak self] in
            NSLog("[VoiceBar] Hotkey cancel — cancelling active recording")
            self?.commandRouter.handleCancel()
        }
    }

    private func handleVoiceModeChange(_ mode: VoiceMode) {
        previousVoiceMode = currentVoiceMode
        currentVoiceMode = mode
        panel?.isMovableByWindowBackground = VoiceBarPresentation.isPanelDraggable(mode: mode)
        applyPanelLayout(animated: true)
        logDiagnostic(event: "mode_changed", details: [
            "newMode": mode.rawValue,
        ])
        switch mode {
        case .recording:
            audioLevelMonitor.start()
        default:
            audioLevelMonitor.stop()
        }
    }

    private func applyPanelLayout(animated: Bool) {
        guard let panel else { return }
        let targetScreen = panel.screen ?? NSScreen.main
        guard let visibleFrame = targetScreen?.visibleFrame else { return }
        let layout = Self.panelLayout(for: voiceState)
        let plan = PillResizePlan.makeAnchored(
            visibleFrame: visibleFrame,
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset,
            topPadding: Theme.topPadding,
            pillSize: layout.panelSize,
            from: previousVoiceMode,
            to: currentVoiceMode,
            padding: 0
        )
        panel.contentView?.frame = NSRect(origin: .zero, size: layout.panelSize)
        panel.setFrame(plan.frame, display: true, animate: animated && plan.animate)
    }

    private static func panelLayout(for state: VoiceState?) -> VoiceBarPanelLayout {
        let mode = state?.mode ?? .idle
        let previewText = VoiceBarPresentation.transcriptPreviewText(
            mode: mode,
            confirmationText: state?.confirmationText,
            commandModeState: state?.commandModeState,
            activeClipMarker: state?.activeClipMarker
        )
        let statusText = VoiceBarPresentation.liveStatusText(
            mode: mode,
            transcript: state?.transcript ?? "",
            confirmationText: state?.confirmationText,
            hotkeyPhase: state?.hotkeyPhase ?? .idle,
            hotkeyEnabled: state?.hotkeyEnabled ?? false,
            errorMessage: state?.errorMessage,
            commandModeState: state?.commandModeState,
            activeClipMarker: state?.activeClipMarker
        )
        return VoiceBarPanelLayout.make(
            mode: mode,
            isCollapsed: state?.isCollapsed ?? false,
            previewText: previewText,
            statusText: statusText,
            idleAccessoryButtonCount: VoiceBarPresentation.idleAccessoryButtonCount(
                recentTranscriptions: state?.recentTranscriptions ?? [],
                transcriptionVocabularyTerms: state?.transcriptionVocabularyTerms ?? [],
                transcriptionVocabularyAliases: state?.transcriptionVocabularyAliases ?? [],
                canReplay: state?.canReplay ?? false
            ),
            queueItemCount: state?.queueItems.count ?? 0,
            padding: Theme.panelPadding
        )
    }

    private func logDiagnostic(event: String, details: [String: String] = [:]) {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let panelFrameDescription = panel.map { NSStringFromRect($0.frame) } ?? "nil"
        let appKeyWindowTitle = NSApp.keyWindow?.title ?? "nil"
        let mergedDetails = [
            "appActive": boolString(NSApp.isActive),
            "panelVisible": boolString(panel?.isVisible ?? false),
            "panelKey": boolString(panel?.isKeyWindow ?? false),
            "panelMain": boolString(panel?.isMainWindow ?? false),
            "panelFrame": panelFrameDescription,
            "frontmostApp": frontmostApp?.bundleIdentifier ?? frontmostApp?.localizedName ?? "nil",
            "voiceMode": voiceState.mode.rawValue,
            "appKeyWindowTitle": appKeyWindowTitle,
        ].merging(details) { _, new in new }

        let payload = mergedDetails
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        NSLog("[VoiceBar][diag] %@ %@", event, payload)
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
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

    func handleLocalControlCommand(_ command: VoiceBarLocalControlCommand) {
        switch command {
        case .startRecording:
            handleHotkeyKeyDown(from: .legacySocket)
        case .stopRecording:
            handleHotkeyKeyUp(from: .legacySocket)
        case .toggle:
            commandRouter.handle(url: URL(string: "voicebar://toggle")!)
        case .pasteLastTranscript:
            voiceState.repasteLastTranscript()
        }
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
        let vOffset = (panel.frame.midY - visible.origin.y) / visible.height
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
            pasteLastTranscript: { [weak self] in
                self?.logDiagnostic(event: "menu_bar_paste_last_transcript_tapped")
                self?.voiceState.repasteLastTranscript()
            },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func resetHotkeyTracking() {
        gestureStateMachine.reset()
        activeHotkeySource = nil
        voiceState.setHotkeyPhase(.idle)
    }

    private func noteHotkeyActivity(from source: HotkeyInputSource) {
        lastHotkeyActivityAt = CFAbsoluteTimeGetCurrent()
        lastHotkeyActivitySource = source
    }

    private func handleHotkeyKeyDown(from source: HotkeyInputSource) {
        let now = CFAbsoluteTimeGetCurrent()
        guard !shouldIgnoreIncomingHotkeyEvent(from: source, now: now) else {
            NSLog("[VoiceBar] Ignoring duplicate %@ keyDown", source == .native ? "native" : "legacy socket")
            return
        }
        noteHotkeyActivity(from: source)
        if gestureStateMachine.state == .idle {
            activeHotkeySource = source
        }
        gestureStateMachine.handleKeyDown()
        if gestureStateMachine.state == .idle {
            activeHotkeySource = nil
        }
    }

    private func handleHotkeyKeyUp(from source: HotkeyInputSource) {
        let now = CFAbsoluteTimeGetCurrent()
        guard !shouldIgnoreIncomingHotkeyEvent(from: source, now: now) else {
            NSLog("[VoiceBar] Ignoring duplicate %@ keyUp", source == .native ? "native" : "legacy socket")
            return
        }
        noteHotkeyActivity(from: source)
        gestureStateMachine.handleKeyUp()
        if gestureStateMachine.state == .idle {
            activeHotkeySource = nil
        }
    }

    private func shouldIgnoreIncomingHotkeyEvent(
        from source: HotkeyInputSource,
        now: TimeInterval
    ) -> Bool {
        shouldIgnoreHotkeyEvent(
            source: source,
            gestureState: gestureStateMachine.state,
            activeHotkeySource: activeHotkeySource,
            lastHotkeyActivityAt: lastHotkeyActivityAt,
            lastHotkeyActivitySource: lastHotkeyActivitySource,
            now: now
        )
    }
}

func shouldIgnoreHotkeyEvent(
    source: HotkeyInputSource,
    gestureState: GestureStateMachine.State,
    activeHotkeySource: HotkeyInputSource?,
    lastHotkeyActivityAt: TimeInterval?,
    lastHotkeyActivitySource: HotkeyInputSource?,
    now: TimeInterval
) -> Bool {
    if let activeHotkeySource,
       gestureState != .idle,
       source != activeHotkeySource {
        return true
    }
    if gestureState == .idle,
       let lastHotkeyActivityAt,
       let lastHotkeyActivitySource,
       source != lastHotkeyActivitySource,
       (now - lastHotkeyActivityAt) <= legacySocketHotkeyDuplicateWindow {
        return true
    }
    return false
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
