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
import ApplicationServices
import AVFoundation
import CoreGraphics
import Darwin
import SwiftUI
import VoiceBarUI

private let legacySocketHotkeyDuplicateWindow: TimeInterval = 0.75
private let launchExternalStartCommandGraceWindow: TimeInterval = 5.0
private let f5HIDMappingSource = 30_064_771_134
private let dictationHIDMappingSource = 51_539_607_759
private let f18HIDMappingDestination = 30_064_771_181

private struct RelaySetupStatus {
    var launchAgentInstalled: Bool
    var launchAgentLoaded: Bool
    var dictationMappingActive: Bool
    var staleF5MappingActive: Bool

    var isReady: Bool {
        launchAgentInstalled && launchAgentLoaded && dictationMappingActive && !staleF5MappingActive
    }

    var summary: String {
        if isReady { return "Relay ready: LaunchAgent loaded and Dictation maps to F18." }
        var missing: [String] = []
        if !launchAgentInstalled { missing.append("LaunchAgent plist missing") }
        if !launchAgentLoaded { missing.append("LaunchAgent not loaded") }
        if !dictationMappingActive { missing.append("Dictation to F18 mapping missing") }
        if staleF5MappingActive { missing.append("stale F5 to F18 mapping still active") }
        return "Relay needs attention: \(missing.joined(separator: ", "))."
    }
}

// MARK: - App Delegate

enum HotkeyInputSource {
    case native
    case legacySocket
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let voiceState = VoiceState(
        transcriptionVocabularyLoader: {
            STTVocabularySnapshotLoader.load().promptTerms
        },
        transcriptionVocabularyAliasLoader: {
            STTVocabularySnapshotLoader.load().aliases
        }
    )
    lazy var commandRouter = VoiceBarCommandRouter(
        voiceState: voiceState,
        resetHotkeyState: { [weak self] in self?.resetHotkeyTracking() },
        showVoiceBar: { [weak self] in self?.unsnoozeNow() }
    )
    private lazy var audioLevelMonitor = AudioLevelMonitor { [weak self] level in
        self?.voiceState.setLocalRecordingLevel(level)
    }

    private let commandModeAXHelper = CommandModeAXHelper()

    private let defaults = VoiceBarDefaults.make()
    private let pillContextMenuController = PillContextMenuController()
    private let daemonController = VoiceBarDaemonController()
    private lazy var anchorPreferences = VoiceBarAnchorPreferences(defaults: defaults)

    private var socketServer: SocketServer?
    private var panel: FloatingPillPanel?
    private var mouseMonitor: Any?
    private var moveObserver: Any?
    private var displayObserver: Any?
    private var workspaceNotificationObservers: [Any] = []
    private var snoozeTask: Task<Void, Never>?
    /// Track which screen the pill is on to avoid unnecessary repositioning.
    private var currentScreenIndex: Int = -1
    /// Saved offsets (0.0-1.0) for pill center positioning on screen.
    private var horizontalOffset: CGFloat = Theme.horizontalOffset
    private var verticalOffset: CGFloat? // nil = fixed top-center island placement
    private var anchorMode: VoiceBarAnchorMode = .follow
    private var dictionarySheetWindow: NSWindow?
    private var settingsWindow: NSWindow?

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
    var externalStartCommandGraceDeadline: TimeInterval? =
        CFAbsoluteTimeGetCurrent() + launchExternalStartCommandGraceWindow
    /// Whether the hotkey system is enabled.
    var hotkeyEnabled: Bool = false
    var missingHotkeyPermissions: [HotkeyPermission] = []
    /// Whether VoiceBar is snoozed (hidden for a timed period).
    var isSnoozed: Bool = false
    private var performanceEffort: VoiceBarPerformanceEffort = .accurate
    private var pendingPerformanceEffortID: String?
    private var pendingPerformanceEffort: VoiceBarPerformanceEffort?
    private var pendingPerformanceEffortPrevious: VoiceBarPerformanceEffort?
    private var performanceEffortNotice: String?
    private var performanceEffortNoticeTask: Task<Void, Never>?
    private lazy var cachedRelaySetupStatus = RelaySetupStatus(
        launchAgentInstalled: relayLaunchAgentInstalled(),
        launchAgentLoaded: false,
        dictationMappingActive: false,
        staleF5MappingActive: false
    )
    private var relaySetupStatusRefreshInFlight = false
    private var relaySetupInFlight = false

    private static let horizontalOffsetKey = "voicebar.horizontalOffset"
    private static let verticalOffsetKey = "voicebar.verticalOffset"
    private static let performanceEffortKey = "voicebar.performanceEffort"

    override init() {
        super.init()
        voiceState.onAckEvent = { [weak self] ack in
            self?.handlePerformanceEffortAck(ack)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleExternalURL(url)
        }
    }

    /// Handle voicebar:// URLs via Apple Events (kAEGetURL).
    /// This fires when `open voicebar://toggle` is invoked from Karabiner or the shell.
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        NSLog("[VoiceBar] handleGetURLEvent: %@", urlString)
        handleExternalURL(url)
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

        let myPID = ProcessInfo.processInfo.processIdentifier
        // Singleton guard: daily-driver launches keep one VoiceBar instance, while
        // isolated QA socket paths can run beside the installed app.
        if VoiceBarDefaults.shouldEnforceSingleton(), VoiceLayerPaths.enforcesSingletonInstance {
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            let others = running.filter { $0.processIdentifier != myPID && !$0.isTerminated }
            if !others.isEmpty {
                NSLog("[VoiceBar] Another instance already running (PID %d) — exiting", others[0].processIdentifier)
                // Give a moment for the log to flush
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
                return
            }
        } else if !VoiceLayerPaths.enforcesSingletonInstance {
            NSLog("[VoiceBar] Singleton guard skipped for isolated socket path %@", VoiceLayerPaths.socketPath)
        } else {
            NSLog("[VoiceBar] Singleton guard skipped by defaults")
        }

        // No Dock icon (LSUIElement equivalent)
        NSApp.setActivationPolicy(.accessory)

        // Register with Launch Services so voicebar:// URL scheme works
        // after rebuilds (Launch Services caches bundle->scheme mappings).
        if VoiceBarDefaults.shouldRegisterLaunchServices(),
           VoiceLayerPaths.enforcesSingletonInstance,
           let bundleURL = Bundle.main.bundleURL as CFURL? {
            let status = LSRegisterURL(bundleURL, true)
            if status != 0 {
                NSLog("[VoiceBar] LSRegisterURL returned %d", status)
            }
        } else if !VoiceLayerPaths.enforcesSingletonInstance {
            NSLog(
                "[VoiceBar] Launch Services registration skipped for isolated socket path %@",
                VoiceLayerPaths.socketPath
            )
        }

        configureGatekeptVoiceStateDependencies()
        performanceEffort = Self.loadPerformanceEffort(defaults: defaults)
        if VoiceBarDefaults.shouldPromptForPermissions() {
            promptForAccessibilityIfNeeded()
        }

        // Socket server — listens on VoiceLayerPaths.socketPath
        let server = SocketServer(state: voiceState)
        socketServer = server
        server.onControlCommand = { [weak self] command in
            self?.handleLocalControlCommand(command)
        }
        server.onCaptureFailure = { [weak self] failureType in
            self?.daemonController.handleCaptureFailure(type: failureType)
        }

        // Wire the send-command closure so BarView buttons -> socket -> MCP clients
        voiceState.sendCommand = { [weak server] cmd in
            server?.sendCommandToOwner(command: cmd)
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
        if VoiceBarDefaults.shouldStartHotkey() {
            setupHotkey()
        }
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
        if let saved = defaults.object(forKey: Self.horizontalOffsetKey) as? Double {
            horizontalOffset = max(0.05, min(0.95, CGFloat(saved)))
        }
        if let saved = defaults.object(forKey: Self.verticalOffsetKey) as? Double {
            verticalOffset = max(0.0, min(0.95, CGFloat(saved)))
        }
        anchorMode = anchorPreferences.loadAnchorMode()

        let pill = FloatingPillPanel(content: hosting)
        pill.contextMenuProvider = { [weak self] in
            self?.pillContextMenuController.makeMenu() ?? NSMenu()
        }
        pill.activeHitRectProvider = { [weak self] in
            Self.panelLayout(for: self?.voiceState).activeHitRect
        }
        pill.isPillDragEnabled = anchorMode.allowsFreeDrag
        positionPanel(pill, on: nil)
        pill.isMovableByWindowBackground = anchorMode.allowsFreeDrag &&
            VoiceBarPresentation.isPanelDraggable(mode: voiceState.mode)
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

        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reapplyAnchoredPanelPosition()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        snoozeTask?.cancel()
        dictionarySheetWindow?.close()
        settingsWindow?.close()
        hotkeyManager?.stop()
        audioLevelMonitor.stop()
        daemonController.stop()
        socketServer?.stop()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = displayObserver {
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
        pillContextMenuController.anchorModeProvider = { [weak self] in
            self?.currentAnchorMode() ?? .follow
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
        pillContextMenuController.onTranscribeLatestRecording = { [weak self] in
            self?.logDiagnostic(event: "context_menu_transcribe_latest_recording_tapped")
            self?.voiceState.retranscribeLastCapture()
        }
        pillContextMenuController.onAddSelectionToDictionary = { [weak self] in
            self?.presentAddToDictionarySheetFromSelection()
        }
        pillContextMenuController.onPasteLastTranscript = { [weak self] in
            self?.logDiagnostic(event: "context_menu_paste_last_transcript_tapped")
            self?.voiceState.repasteLastTranscript(source: "context_menu_latest")
        }
        pillContextMenuController.onCopyLastTranscript = { [weak self] in
            self?.logDiagnostic(event: "context_menu_copy_last_transcript_tapped")
            self?.voiceState.copyLastTranscript()
        }
        pillContextMenuController.onPasteTranscript = { [weak self] transcript in
            self?.logDiagnostic(event: "context_menu_paste_recent_transcript_tapped")
            self?.voiceState.repasteTranscript(transcript, source: "context_menu_history")
        }
        pillContextMenuController.onSelectAnchorMode = { [weak self] mode in
            self?.selectAnchorMode(mode)
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
        reapplyAnchoredPanelPosition()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Clean shutdown — exit code 0 so launchd KeepAlive.SuccessfulExit:false
        // does NOT respawn. Only crashes (non-zero) trigger restart.
        snoozeTask?.cancel()
        hotkeyManager?.stop()
        audioLevelMonitor.stop()
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
        let trusted = Self.isAccessibilityTrusted(prompt: true)
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

    private func configureGatekeptVoiceStateDependencies() {
        voiceState.simulatedPasteHandler = {
            Self.simulatePaste()
        }
        voiceState.accessibilityTrustChecker = { prompt in
            Self.isAccessibilityTrusted(prompt: prompt)
        }
        voiceState.dictationInsertionHandlerProvider = {
            CommandModeAXHelper.captureFocusedInsertionHandler()
        }
        voiceState.commandModeApplyHandler = { [commandModeAXHelper] text in
            commandModeAXHelper.applyReplacement(text)
        }
        RetainedRecordingPreview.urlProvider = {
            URL(fileURLWithPath: VoiceLayerPaths.retainedRecordingPath)
        }
    }

    /// Simulate Cmd+V via CGEvent. Requires Accessibility permission.
    /// Returns true if paste was posted, false if blocked (S3 fix: caller checks this).
    @discardableResult
    private static func simulatePaste() -> Bool {
        guard isAccessibilityTrusted(prompt: false) else {
            NSLog("[VoiceBar] simulatePaste: Accessibility not granted")
            return false
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            NSLog("[VoiceBar] simulatePaste: failed to create CGEventSource")
            return false
        }
        let vKey: CGKeyCode = 0x09 // V
        let commandKey: CGKeyCode = 0x37
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false)
        guard let commandDown, let vDown, let vUp, let commandUp else {
            NSLog("[VoiceBar] simulatePaste: failed to create CGEvent")
            return false
        }
        let pasteFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
        vDown.flags = pasteFlags
        vUp.flags = pasteFlags
        commandDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        return true
    }

    private static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
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
        manager.onMouseDown = { [weak self] in
            self?.handleHotkeyMouseDown(from: .native)
        }
        manager.onMouseUp = { [weak self] in
            self?.handleHotkeyMouseUp(from: .native)
        }
        manager.onCancel = { [weak self] in
            self?.noteHotkeyActivity(from: .native)
            self?.commandRouter.handleCancel()
        }
        manager.onPasteLastTranscript = { [weak self] in
            self?.voiceState.repasteLastTranscript(source: "shift_f5")
        }
        manager.shouldHandleEscape = { [weak self] in
            guard let mode = self?.voiceState.mode else { return false }
            return mode == .recording || mode == .transcribing || mode == .speaking
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
                    case .microphone: "Microphone"
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
        gestureStateMachine.onSingleTap = { [weak self] in
            NSLog("[VoiceBar] Hotkey single tap — checking active recording/transcription")
            self?.commandRouter.handleHotkeySingleTap()
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
        panel?.isMovableByWindowBackground = anchorMode.allowsFreeDrag &&
            VoiceBarPresentation.isPanelDraggable(mode: mode)
        panel?.isPillDragEnabled = anchorMode.allowsFreeDrag
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
        let placement = anchorPlacement(for: panel, visibleFrame: visibleFrame, pillSize: layout.panelSize)
        let plan = PillResizePlan.makeAnchored(
            visibleFrame: visibleFrame,
            horizontalOffset: placement.horizontalOffset,
            verticalOffset: placement.verticalOffset,
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
            transcribingStatusText: state?.transcribingStatusText,
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
            isPasteFlowActive: state?.keepsPasteFlowEnvelope ?? false,
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
        guard !shouldSuppressLaunchStartCommand(rawCommand: "native-hotkey") else {
            resetHotkeyTracking()
            return
        }
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
            guard !shouldSuppressLaunchStartCommand(rawCommand: command.rawValue) else {
                resetHotkeyTracking()
                return
            }
            handleHotkeyKeyDown(from: .legacySocket)
        case .stopRecording:
            handleHotkeyKeyUp(from: .legacySocket)
        case .toggle:
            guard !shouldSuppressLaunchStartCommand(rawCommand: command.rawValue) else {
                resetHotkeyTracking()
                return
            }
            commandRouter.handle(url: URL(string: "voicebar://toggle")!)
        case .pasteLastTranscript:
            voiceState.repasteLastTranscript(source: "local_control")
        }
    }

    private func handleExternalURL(_ url: URL) {
        commandRouter.handle(url: url)
    }

    private func shouldSuppressLaunchStartCommand(rawCommand: String) -> Bool {
        guard let deadline = externalStartCommandGraceDeadline else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        guard now <= deadline else {
            externalStartCommandGraceDeadline = nil
            return false
        }

        let wouldStartRecording =
            rawCommand == "start-recording" ||
            rawCommand == "native-hotkey" ||
            (rawCommand == "toggle" && (voiceState.mode == .idle || voiceState.mode == .error))
        guard wouldStartRecording else { return false }

        NSLog("[VoiceBar] Ignoring %@ during launch start-command grace window", rawCommand)
        return true
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

    /// Reposition pill when the active screen changes. Anchored modes still move
    /// between screens; only their position within each screen is fixed.
    private func handleMouseMoved() {
        guard let panel else { return }

        let screens = NSScreen.screens
        guard let targetScreen = Self.screenIndexContainingMouse(in: screens) else { return }

        // Only reposition when the screen actually changes
        if targetScreen != currentScreenIndex {
            currentScreenIndex = targetScreen
            positionPanel(panel, on: screens[targetScreen])
        }
    }

    private func positionPanel(_ panel: FloatingPillPanel, on screen: NSScreen?) {
        let targetScreen = screen ?? Self.screenContainingMouse() ?? panel.screen ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? .zero
        let placement = anchorPlacement(
            for: panel,
            visibleFrame: visibleFrame,
            pillSize: panel.frame.size
        )
        panel.positionOnScreen(
            targetScreen,
            horizontalOffset: placement.horizontalOffset,
            verticalOffset: placement.verticalOffset
        )
        if let targetScreen,
           let index = NSScreen.screens.firstIndex(of: targetScreen) {
            currentScreenIndex = index
        }
    }

    private static func screenContainingMouse() -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = screenIndexContainingMouse(in: screens) else { return nil }
        return screens[index]
    }

    private static func screenIndexContainingMouse(in screens: [NSScreen]) -> Int? {
        VoiceBarScreenFollowPolicy.targetScreenIndex(
            mouseLocation: NSEvent.mouseLocation,
            screenFrames: screens.map(\.frame)
        )
    }

    private func anchorPlacement(
        for panel: FloatingPillPanel,
        visibleFrame: CGRect,
        pillSize: CGSize
    ) -> VoiceBarAnchorPlacement {
        VoiceBarPositionLockPolicy.effectivePlacement(
            anchorMode: anchorMode,
            savedHorizontalOffset: horizontalOffset,
            savedVerticalOffset: verticalOffset,
            visibleFrame: visibleFrame,
            pillSize: pillSize
        )
    }

    private func reapplyAnchoredPanelPosition() {
        guard let panel else { return }
        positionPanel(panel, on: Self.screenContainingMouse() ?? panel.screen ?? NSScreen.main)
    }

    // MARK: - Drag persistence

    /// Save the pill's position as percentages of screen dimensions.
    private func savePanelPosition() {
        guard anchorMode.allowsFreeDrag else { return }
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let hOffset = (panel.frame.midX - visible.origin.x) / visible.width
        let vOffset = (panel.frame.midY - visible.origin.y) / visible.height
        horizontalOffset = max(0.05, min(0.95, CGFloat(hOffset)))
        verticalOffset = max(0.0, min(0.95, CGFloat(vOffset)))
        defaults.set(Double(horizontalOffset), forKey: Self.horizontalOffsetKey)
        defaults.set(Double(verticalOffset!), forKey: Self.verticalOffsetKey)
    }

    func currentAnchorMode() -> VoiceBarAnchorMode {
        anchorMode
    }

    func selectAnchorMode(_ mode: VoiceBarAnchorMode) {
        anchorMode = mode
        anchorPreferences.saveAnchorMode(mode)
        panel?.isPillDragEnabled = mode.allowsFreeDrag
        panel?.isMovableByWindowBackground = mode.allowsFreeDrag &&
            VoiceBarPresentation.isPanelDraggable(mode: voiceState.mode)
        if let panel {
            positionPanel(panel, on: nil)
            applyPanelLayout(animated: true)
        }
        refreshSettingsWindowAnchorState()
    }

    func currentPerformanceEffort() -> VoiceBarPerformanceEffort {
        performanceEffort
    }

    func currentPerformanceEffortNotice() -> String? {
        performanceEffortNotice
    }

    func selectPerformanceEffort(_ effort: VoiceBarPerformanceEffort) {
        guard effort != performanceEffort else {
            clearPerformanceEffortNotice()
            refreshSettingsWindowAnchorState()
            return
        }

        guard let sendCommand = voiceState.sendCommand else {
            rejectPendingPerformanceEffort(reason: "VoiceLayer is starting")
            return
        }

        let id = UUID().uuidString
        let previousEffort = performanceEffort
        performanceEffort = effort
        pendingPerformanceEffortID = id
        pendingPerformanceEffort = effort
        pendingPerformanceEffortPrevious = previousEffort
        clearPerformanceEffortNotice()
        sendCommand([
            "cmd": "set_whisper_effort",
            "effort": effort.rawValue,
            "id": id,
        ])
        refreshSettingsWindowAnchorState()
    }

    private func handlePerformanceEffortAck(_ ack: SocketAckEvent) {
        guard ack.command == .setWhisperEffort,
              ack.id == pendingPerformanceEffortID
        else {
            return
        }

        let effort = pendingPerformanceEffort
        let previousEffort = pendingPerformanceEffortPrevious
        pendingPerformanceEffortID = nil
        pendingPerformanceEffort = nil
        pendingPerformanceEffortPrevious = nil

        guard ack.outcome == .accept, let effort else {
            if let previousEffort {
                performanceEffort = previousEffort
            }
            rejectPendingPerformanceEffort(reason: ack.reason)
            return
        }

        performanceEffort = effort
        defaults.set(effort.rawValue, forKey: Self.performanceEffortKey)
        clearPerformanceEffortNotice()
        refreshSettingsWindowAnchorState()
    }

    private func rejectPendingPerformanceEffort(reason: String?) {
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmedReason?.isEmpty == false ? " - \(trimmedReason!), try again" : " - try again"
        performanceEffortNotice = "Couldn't change effort\(suffix)"
        refreshSettingsWindowAnchorState()
        schedulePerformanceEffortNoticeClear(expectedNotice: performanceEffortNotice)
    }

    private func clearPerformanceEffortNotice() {
        performanceEffortNoticeTask?.cancel()
        performanceEffortNoticeTask = nil
        performanceEffortNotice = nil
    }

    private func schedulePerformanceEffortNoticeClear(expectedNotice: String?) {
        performanceEffortNoticeTask?.cancel()
        performanceEffortNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self,
                  !Task.isCancelled,
                  performanceEffortNotice == expectedNotice
            else {
                return
            }
            performanceEffortNotice = nil
            performanceEffortNoticeTask = nil
            refreshSettingsWindowAnchorState()
        }
    }

    private static func loadPerformanceEffort(defaults: UserDefaults) -> VoiceBarPerformanceEffort {
        guard let rawValue = defaults.string(forKey: performanceEffortKey),
              let effort = VoiceBarPerformanceEffort(rawValue: rawValue)
        else {
            return .accurate
        }
        return effort
    }

    private func microphonePermissionGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func runRelaySetup() -> (message: String, status: RelaySetupStatus) {
        guard let scriptURL = Bundle.main.resourceURL?
            .appendingPathComponent("scripts")
            .appendingPathComponent("install-voicebar-f5-hidutil.sh")
        else {
            NSLog("[VoiceBar] Relay setup script not bundled")
            return (
                "Relay setup failed: bundled installer script not found.",
                currentRelaySetupStatus()
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[VoiceBar] Failed to run relay setup: %@", String(describing: error))
            return (
                "Relay setup failed: \(error.localizedDescription)",
                currentRelaySetupStatus()
            )
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let status = currentRelaySetupStatus()
        NSLog(
            "[VoiceBar] Relay setup finished exit=%d status=%@ output=%@",
            process.terminationStatus,
            status.summary,
            output
        )
        guard process.terminationStatus == 0 else {
            return (
                "Relay setup failed (exit \(process.terminationStatus)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))",
                status
            )
        }
        return (status.summary, status)
    }

    private func runRelaySetupAsync(completion: @escaping (String) -> Void) {
        guard !relaySetupInFlight else {
            completion("Relay setup is already running.")
            return
        }
        relaySetupInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion("Relay setup failed: VoiceBar is not available.")
                }
                return
            }
            let result = runRelaySetup()
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion(result.message)
                    return
                }
                cachedRelaySetupStatus = result.status
                relaySetupInFlight = false
                completion(result.message)
            }
        }
    }

    private func refreshRelaySetupStatusAsync() {
        guard !relaySetupStatusRefreshInFlight else { return }
        relaySetupStatusRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let status = currentRelaySetupStatus()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                cachedRelaySetupStatus = status
                relaySetupStatusRefreshInFlight = false
                if !relaySetupInFlight {
                    refreshSettingsWindowAnchorState()
                }
            }
        }
    }

    private func currentRelaySetupStatus() -> RelaySetupStatus {
        let mappingStatus = relayMappingStatus()
        return RelaySetupStatus(
            launchAgentInstalled: relayLaunchAgentInstalled(),
            launchAgentLoaded: relayLaunchAgentLoaded(),
            dictationMappingActive: mappingStatus.dictationMappingActive,
            staleF5MappingActive: mappingStatus.staleF5MappingActive
        )
    }

    private func relayLaunchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: relayLaunchAgentPath())
    }

    private func relayLaunchAgentLoaded() -> Bool {
        let uid = getuid()
        let result = Self.runProcess(
            executablePath: "/bin/launchctl",
            arguments: ["print", "gui/\(uid)/\(VoiceBarHotkeyContract.remapAgentLabel)"]
        )
        return result.exitCode == 0
    }

    private func relayMappingStatus() -> (dictationMappingActive: Bool, staleF5MappingActive: Bool) {
        let result = Self.runProcess(
            executablePath: "/usr/bin/hidutil",
            arguments: ["property", "--get", "UserKeyMapping"]
        )
        guard result.exitCode == 0 else { return (false, false) }
        return Self.hidutilRelayMappingStatus(result.outputData)
    }

    private func relayLaunchAgentPath() -> String {
        NSHomeDirectory()
            + "/Library/LaunchAgents/"
            + VoiceBarHotkeyContract.remapAgentLabel
            + ".plist"
    }

    private static func runProcess(executablePath: String, arguments: [String]) -> (exitCode: Int32, outputData: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, pipe.fileHandleForReading.readDataToEndOfFile())
        } catch {
            return (127, Data(String(describing: error).utf8))
        }
    }

    static func hidutilMappingContains(_ data: Data, source: Int, destination: Int) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains(String(source)) && output.contains(String(destination))
        }
        let mappings: [[String: Any]] = if let array = plist as? [[String: Any]] {
            array
        } else if let dict = plist as? [String: Any],
                  let array = dict["UserKeyMapping"] as? [[String: Any]] {
            array
        } else {
            []
        }
        return mappings.contains { entry in
            Self.hidutilInt(entry["HIDKeyboardModifierMappingSrc"]) == source &&
                Self.hidutilInt(entry["HIDKeyboardModifierMappingDst"]) == destination
        }
    }

    static func hidutilRelayMappingStatus(_ data: Data) -> (dictationMappingActive: Bool, staleF5MappingActive: Bool) {
        (
            dictationMappingActive: hidutilMappingContains(
                data,
                source: dictationHIDMappingSource,
                destination: f18HIDMappingDestination
            ),
            staleF5MappingActive: hidutilMappingContains(
                data,
                source: f5HIDMappingSource,
                destination: f18HIDMappingDestination
            )
        )
    }

    private static func hidutilInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func refreshSettingsWindowAnchorState() {
        guard let settingsWindow else { return }
        DispatchQueue.main.async { [weak self, weak settingsWindow] in
            guard let self,
                  let hosting = settingsWindow?.contentViewController as? NSHostingController<SettingsView>
            else { return }
            hosting.rootView = makeSettingsView()
        }
    }

    func currentVocabularyPreview() -> STTVocabularyPreview {
        STTVocabularyPreview(
            updatedAt: nil,
            promptTerms: voiceState.transcriptionVocabularyTerms,
            aliases: voiceState.transcriptionVocabularyAliases
        )
    }

    private func presentAddToDictionarySheetFromSelection() {
        voiceState.beginModalInteraction()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let selection = FrontmostSelectionReader.readCurrentSelection()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                logDiagnostic(event: "context_menu_add_to_dictionary_tapped", details: [
                    "selectionSource": selection?.source.rawValue ?? "none",
                    "selectionLength": String(selection?.text.count ?? 0),
                ])
                presentDictionarySheet(
                    draft: STTVocabularyDraft(
                        correct: selection?.text ?? "",
                        wrong: ""
                    )
                )
            }
        }
    }

    private func presentDictionarySheet(draft: STTVocabularyDraft) {
        closeDictionarySheet()
        NSApp.activate(ignoringOtherApps: true)
        let rootView = DictionaryAddSheetView(
            draft: draft,
            onSave: { [weak self] draft in
                self?.voiceState.addVocabularyAlias(
                    correct: draft.trimmedCorrect,
                    wrong: draft.trimmedWrong
                )
                self?.closeDictionarySheet()
            },
            onCancel: { [weak self] in
                self?.closeDictionarySheet()
            }
        )
        let hosting = NSHostingController(rootView: rootView)
        let sheet = NSWindow(contentViewController: hosting)
        sheet.title = "Add to Dictionary"
        sheet.styleMask = [.titled]
        sheet.isReleasedWhenClosed = false
        sheet.setContentSize(NSSize(width: 380, height: 210))
        dictionarySheetWindow = sheet

        if let panel {
            panel.beginSheet(sheet)
        } else {
            sheet.center()
            sheet.orderFront(nil)
        }
    }

    private func closeDictionarySheet() {
        guard let sheet = dictionarySheetWindow else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        }
        sheet.close()
        dictionarySheetWindow = nil
        voiceState.endModalInteraction()
    }

    func quickMenuActions() -> [VoiceBarMenuAction] {
        VoiceBarMenu.quickActions(
            isSnoozed: isSnoozed,
            openSettings: { [weak self] in self?.openSettingsWindow() },
            showVoiceBar: { [weak self] in self?.commandRouter.handleShowVoiceBar() },
            snoozeToggle: { [weak self] in
                guard let self else { return }
                if isSnoozed { unsnoozeNow() } else { snoozeForOneHour() }
            },
            transcribeLatestRecording: { [weak self] in
                self?.logDiagnostic(event: "menu_bar_transcribe_latest_recording_tapped")
                self?.voiceState.retranscribeLastCapture()
            },
            pasteLastTranscript: { [weak self] in
                self?.logDiagnostic(event: "menu_bar_paste_last_transcript_tapped")
                self?.voiceState.repasteLastTranscript(source: "menu_bar")
            },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }

    func openSettingsWindow() {
        voiceState.captureSettingsHistoryPasteTarget()
        NSApp.activate(ignoringOtherApps: true)
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            refreshRelaySetupStatusAsync()
            return
        }

        let hosting = NSHostingController(rootView: makeSettingsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceBar Settings"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.level = .floating
        window.center()
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        refreshRelaySetupStatusAsync()
    }

    func makeSettingsView() -> SettingsView {
        SettingsView(
            hotkeyEnabled: hotkeyEnabled,
            missingPermissions: missingHotkeyPermissions,
            availableDevices: { MicrophoneDeviceManager.availableInputDevices() },
            selectedDeviceID: { MicrophoneDeviceManager.selectedInputDeviceID() },
            onSelectDevice: { MicrophoneDeviceManager.selectInputDevice(id: $0) },
            anchorMode: { [weak self] in self?.currentAnchorMode() ?? .follow },
            onSelectAnchorMode: { [weak self] in self?.selectAnchorMode($0) },
            performanceEffort: { [weak self] in self?.currentPerformanceEffort() ?? .accurate },
            performanceEffortNotice: { [weak self] in self?.currentPerformanceEffortNotice() },
            onSelectPerformanceEffort: { [weak self] in self?.selectPerformanceEffort($0) },
            vocabularyPreview: { [weak self] in
                self?.currentVocabularyPreview() ?? STTVocabularyPreview(
                    updatedAt: nil,
                    promptTerms: [],
                    aliases: []
                )
            },
            onAddVocabularyAlias: { [weak self] correct, wrong in
                self?.voiceState.addVocabularyAlias(
                    correct: correct,
                    wrong: wrong
                )
            },
            onRemoveVocabularyAlias: { [weak self] alias in
                self?.voiceState.removeVocabularyAlias(alias)
            },
            onAddPromptTerm: { [weak self] term in
                self?.voiceState.addVocabularyPromptTerm(term)
            },
            onRemovePromptTerm: { [weak self] term in
                self?.voiceState.removeVocabularyPromptTerm(term)
            },
            isHotkeyRemapActive: { [weak self] in
                self?.cachedRelaySetupStatus.isReady ?? false
            },
            isMicrophonePermissionGranted: { [weak self] in
                self?.microphonePermissionGranted() ?? false
            },
            onRunRelaySetup: { [weak self] completion in
                self?.runRelaySetupAsync(completion: completion)
                    ?? completion("Relay setup failed: VoiceBar is not available.")
            }
        )
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

    func handleHotkeyKeyDown(from source: HotkeyInputSource) {
        let now = CFAbsoluteTimeGetCurrent()
        if source == .native, shouldSuppressLaunchStartCommand(rawCommand: "native-hotkey") {
            resetHotkeyTracking()
            return
        }
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

    private func handleHotkeyMouseDown(from source: HotkeyInputSource) {
        let now = CFAbsoluteTimeGetCurrent()
        guard !shouldIgnoreIncomingHotkeyEvent(from: source, now: now) else {
            NSLog("[VoiceBar] Ignoring duplicate %@ mouseDown", source == .native ? "native" : "legacy socket")
            return
        }
        noteHotkeyActivity(from: source)
        if gestureStateMachine.state == .idle {
            activeHotkeySource = source
        }
        gestureStateMachine.handleMouseButtonDown()
        if gestureStateMachine.state == .idle {
            activeHotkeySource = nil
        }
    }

    private func handleHotkeyMouseUp(from source: HotkeyInputSource) {
        let now = CFAbsoluteTimeGetCurrent()
        guard !shouldIgnoreIncomingHotkeyEvent(from: source, now: now) else {
            NSLog("[VoiceBar] Ignoring duplicate %@ mouseUp", source == .native ? "native" : "legacy socket")
            return
        }
        noteHotkeyActivity(from: source)
        gestureStateMachine.handleMouseButtonUp()
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
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
