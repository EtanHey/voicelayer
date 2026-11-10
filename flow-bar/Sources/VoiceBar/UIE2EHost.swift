#if VOICEBAR_QA
import AppKit
import SwiftUI
import VoiceBarUI
import AVFoundation
import Darwin

/// No engine/input node is constructed; the product monitor lifecycle remains exercised.
final class UIE2ENoDeviceLevelEngine: AudioLevelMonitoringEngine, AudioLevelMonitoringInputNode {
    private(set) var starts = 0
    var monitoringInputNode: AudioLevelMonitoringInputNode { self }
    func inputFormat() -> AVAudioFormat? { nil }
    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat?,
                    block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {}
    func removeTap() {}
    func prepare() {}
    func start() throws { starts += 1 }
    func stop() {}
}

enum UIE2ENoDeviceGuard {
    /// Every scenario whose fixture constructs the real AppDelegate (UIE2EGate2245).
    static let guardedScenarios: Set<String> = ["hide1", "gate2246"]
#if VOICEBAR_UIE2E_GATE2245
    static let gateBuild = true
#else
    static let gateBuild = false
#endif

    /// A GATE2245 build can construct the real AppDelegate under any scenario name: fail closed.
    static func isRequired(scenario: String?, gateBuild: Bool = gateBuild) -> Bool {
        gateBuild || guardedScenarios.contains(scenario ?? "")
    }

    static func requireInstalled() {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "voicebar_no_device_guard_version"),
              unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)() == 1
        else { fatalError("GATE2245 fixtures refuse startup without the device tripwire library") }
    }
}

/// The real Settings/BarView/menu with fixture dependencies. This entry point intentionally
/// precedes AppDelegate construction: no daemon, global hotkeys, audio engine or live sockets.
@MainActor
final class UIE2EHost: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let sandbox: UIE2ESandbox
    let model: UIE2EModel
    let hostGeometry: VoiceBarNotchScreenGeometry?
    private var syntheticInputTimer: Timer?
    var settings: NSWindow!
    var pill: FloatingPillPanel!
    /// 2.3 U4: the notch History panel (open state, extend-handle rows) for hit testing and the pill's size.
    var notchModel: VoiceBarNotchPresentationModel!
    let menu = PillContextMenuController()
    var statusItem: NSStatusItem?
    var statusController: MenuBarStatusItemController?
    var popoverPresenter: MenuBarPopoverPresenter?
    var wizard: NSWindow?
    var contextMenuTracking = false
    /// 2.3 U2: the same History bridge + surface handoff the app uses (U2 review R1: no separate QA menu path).
    let historyBridge = VoiceBarNotchHistoryBridge()
    /// 2.4 Lane A: the same ONE notch surface the app uses; every transition is a receipt (`notch-surface …`), so the
    /// M1 XCUI cases can prove an Esc, an outside click or a drag-up closed the drawer.
    let notchSurface = NotchSurfaceModel()
    lazy var surfaceHandoff: VoiceBarNotchSurfaceHandoff = makeSurfaceHandoff()
    /// QA-only: hold scheduled menu presentations so a test can open History in the gap (wings-u2 queued-cancel).
    var holdsMenuQueue = false
    var heldMenuPresentations: [() -> Void] = []
    private var historyEscapeMonitors: [Any] = []
    private var firstClickMonitor: Any?
    private var firstClickRecords: [[String: Any]] = []
#if VOICEBAR_UIE2E_GATE2245
    var gate2245: UIE2EGate2245?
#endif
#if VOICEBAR_UIE2E_FOCUSED_338
    var stateGallery: UIE2EStateGallery?
#endif

    init(sandbox: UIE2ESandbox) {
        self.sandbox = sandbox
        model = UIE2EModel(sandbox: sandbox)
        hostGeometry = ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_GEOMETRY"] == "host"
            ? UIE2ECaptureFixtures.hostGeometry() : nil
    }

    static func runIfRequested() -> Bool {
        do {
            let environment = ProcessInfo.processInfo.environment
            let mode = try UIE2ELaunchPolicy.resolve(bundleIdentifier: Bundle.main.bundleIdentifier,
                marker: Bundle.main.object(forInfoDictionaryKey: UIE2ELaunchPolicy.markerKey),
                environment: environment, confirmMute: confirmedMute)
            guard mode == .fixture else { return false }
            if UIE2ENoDeviceGuard.isRequired(scenario: environment["VOICEBAR_UIE2E_SCENARIO"]) {
                UIE2ENoDeviceGuard.requireInstalled()
            }
            let sandbox = try UIE2ESandbox(environment: environment)
            let app = NSApplication.shared
            let host = UIE2EHost(sandbox: sandbox)
            app.delegate = host
            withExtendedLifetime(host) { app.run() }
        } catch { fatalError("UIE2E startup refused before production initialization: \(error)") }
        return true
    }

    private static func confirmedMute() throws -> Bool {
        // A terminal-mac guest has no audio route to mute. Read-only CoreAudio proof; lookup errors refuse.
        if UIE2ECaptureFixtures.hasNoDefaultOutputDevice() { return true }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        check.arguments = ["-e", "output muted of (get volume settings)"]
        let pipe = Pipe(); check.standardOutput = pipe
        try check.run(); check.waitUntilExit()
        return check.terminationStatus == 0 &&
              String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] == "focused-338" {
#if VOICEBAR_UIE2E_FOCUSED_338
            let gallery = UIE2EStateGallery(sandbox: sandbox)
            stateGallery = gallery
            gallery.show()
            NSApp.activate(ignoringOtherApps: true)
            return
#else
            fatalError("focused-338 requires an explicit verified #338-capable QA build")
#endif
        }
        // The minimal AppKit host needs standard Edit commands too. Without this,
        // Cmd-A was a no-op and Dictionary rename/search silently appended text.
        let main = NSMenu(), editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        // AppKit reserves the first menu for application commands.
        let applicationItem = NSMenuItem()
        applicationItem.submenu = NSMenu(title: "VoiceBar QA")
        main.addItem(applicationItem)
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
        settings = NSWindow(contentRect: NSRect(x: 80, y: 180, width: 820, height: 700),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        settings.title = "VoiceBar QA Settings"
        settings.isReleasedWhenClosed = false
        settings.contentView = NSHostingView(rootView: settingsRoot())
        bindNotchModel(VoiceBarNotchPresentationModel(onLayoutInvalidated: { [weak self] in self?.updatePillLayout() }))
        let bar = PillHostingView(rootView: BarView(state: model.voice, commandRouter: VoiceBarCommandRouter(voiceState: model.voice),
            onOpenSettings: { self.settings.makeKeyAndOrderFront(nil) },
            onOpenHistory: { self.model.tab = .history; self.model.requestID += 1; self.model.receipt("history-open") },
            presentationModel: notchModel,
            includesPanelOutsets: true,
            onOpenMicrophonePicker: { [weak self] in self?.surfaceHandoff.requestMenu(.microphone) },
            onOpenSetupSettings: { [weak self] in self?.openSetupSettings() },
            historyBridge: historyBridge,
            onOpenNotchMenu: { [weak self] in self?.surfaceHandoff.requestMenu(.notch) },
            onCancelNotchMenu: { [weak self] in self?.surfaceHandoff.cancelQueuedMenu() },
            surface: notchSurface,
            settingsDrawer: NotchSettingsDrawerContext(
                updates: nil,
                pane: { [weak self] tab, request in
                    guard let self else { return AnyView(EmptyView()) }
                    return AnyView(UIE2ESettings(model: model, notchTab: tab, notchRequest: request))
                }
            )))
        notchSurface.log = { [weak self] line in
            self?.model.receipt(line.replacingOccurrences(of: "[VoiceBar] ", with: ""))
        }
        bar.activeHitTestProvider = { [weak self] point in
            guard let self else { return false }
            return self.panelLayout().containsInteractiveContent(point)
        }
        bar.renderedSurfaceHitTestProvider = { [weak self] point in
            guard let self else { return false }
            return self.panelLayout().containsVisibleSurface(point)
        }
        bar.hoverExpansionHitTestProvider = { [weak self] point in
            guard let self else { return false }
            return self.panelLayout().containsHoverExpansion(point)
        }
        bar.hoverRetentionHitTestProvider = { [weak self] point in
            guard let self else { return false }
            return self.panelLayout().containsHoverRetention(point)
        }
        bar.onHoverChanged = { [weak self] hovering in
            self?.model.voice.setHoveringFromDebouncedPointer(hovering)
        }
        bar.wantsLayer = true
        bar.layer?.masksToBounds = true
        bar.frame = NSRect(x: 0, y: 0, width: 680, height: 180)
        pill = FloatingPillPanel(content: bar)
        // Default isolated placement stays virtual; explicit host mode uses measured display geometry.
        pill.configureNotchDragging(screenKind: hostGeometry?.kind ?? .flatDisplayFallback, allowsFreeDrag: false, mode: model.voice.mode)
        pill.title = "VoiceBar QA Pill"
        pill.setFrame(NSRect(x: 100, y: 20, width: 680, height: 180), display: false)
        model.voice.onPanelLayoutChange = { [weak self] in
            self?.updatePillLayout()
        }
        if let screen = NSScreen.main { fitPill(in: screen) }
        model.onVisibilityChange = { [weak self] hidden in
            if hidden { self?.pill?.orderOut(nil) } else { self?.pill?.orderFront(nil) }
        }
        // 2.4 Lane A fixture providers (#813): they drive the same notch surface and Settings window the app does.
        model.onNotchSurface = { [weak self] event in self?.notchSurface.send(event) }
        model.onShowSettings = { [weak self] in self?.settings.makeKeyAndOrderFront(nil) }
        installTakeIdentity(on: bar)
        configureMenu()
        // wings-u2 first-click check: the pill must never become key from a click while another app is active.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: pill, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.model.receipt("pill-became-key") }
        }
        pill.contextMenuProvider = { self.makeContextMenu() }
        pill.contextMenuHitTestProvider = { _ in true }
        pill.orderFront(nil)
        settings.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] == "wings-u2"
            || ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_NOTCH_HISTORY_ROWS"] != nil {
            installFirstClickReceipts()
        }
        if ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_NOTCH_HISTORY_ROWS"] != nil {
            // U4 exercises the normal nonactivating click path with another app frontmost, not Settings' Esc.
            settings.orderOut(nil)
            installHistoryEscapeReceipts()
        }
        configureStatusItem()
#if VOICEBAR_UIE2E_GATE2245
        if ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] == "hide1" || ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] == "gate2246" {
            installHide1VisualMenu()
        }
#endif

        model.seedNotchHistoryIfRequested()
        syntheticInputTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.advanceSyntheticCapture(milliseconds: 50) }
        }
        model.receipt("launch")
        if let name = ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_FIXTURE"] {
            model.fixture(name)
        }
    }

    private func installHistoryEscapeReceipts() {
        func record(_ event: NSEvent, source: String) {
            guard event.keyCode == 53 else { return }
            sandbox.writeObject(["source": source, "eventWindowNumber": event.windowNumber,
                           "eventTimestamp": event.timestamp,
                           "eventWindowIsPill": event.window === pill,
                           "eventWindowIsSettings": event.window === settings,
                           "voiceBarKeyWindowNumber": NSApp.keyWindow?.windowNumber ?? 0,
                           "voiceBarIsActive": NSApp.isActive] as [String: Any], file: "u4-escape-target.json")
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            MainActor.assumeIsolated { record(event, source: "global") }
        }) { historyEscapeMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            MainActor.assumeIsolated { record(event, source: "local") }
            return event
        }) { historyEscapeMonitors.append(monitor) }
    }

    /// First-click oracle (U2 wings-u2, U4): whether VoiceBar was active, and whether the pill was key, at the moment
    /// a mouse-down reached the pill. Written by the host at click time, because Finder's state after the click
    /// cannot tell a product activation from XCUITest's own activation of the app under test.
    private func installFirstClickReceipts() {
        firstClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let pill = self.pill, event.window === pill else { return }
                self.firstClickRecords.append(["appActive": NSApp.isActive, "pillKey": pill.isKeyWindow,
                                               "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                                               "eventTimestamp": event.timestamp])
                self.sandbox.writeObject(self.firstClickRecords, file: "first-click.json")
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        syntheticInputTimer?.invalidate()
        historyEscapeMonitors.forEach(NSEvent.removeMonitor)
        historyEscapeMonitors.removeAll()
        if let firstClickMonitor { NSEvent.removeMonitor(firstClickMonitor) }
        firstClickMonitor = nil
    }

    /// Shared with the offscreen layout regression test; constructing this view starts no services.
    func settingsRoot(pasteFeedback: Bool? = nil, onFixtureFrames: @escaping ([String: CGRect]) -> Void = { _ in }) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("UI ONLY · synthetic data · no audio").font(.caption)
                ForEach(["idle", "transcribing", "confirmation", "paste-failed", "error", "disconnected"], id: \.self) { name in
                    Button(name) { self.model.fixture(name) }.accessibilityIdentifier("qa-fixture-\(name)")
                }
            }.controlSize(.small).padding(2).fixtureFrame("baseline")
#if VOICEBAR_UIE2E_GATE2245
            gate2245Controls.controlSize(.small).fixtureFrame("gate")
#endif
            if pasteFeedback ?? (Bundle.main.object(forInfoDictionaryKey: "UIE2EPasteFeedback") as? Bool == true) {
                HStack {
                    ForEach(["paste-not-inserted", "paste-unverified", "paste-partial", "paste-typed"], id: \.self) { name in
                        Button(name) { self.model.fixture(name) }.accessibilityIdentifier("qa-fixture-\(name)")
                    }
                }.controlSize(.small).padding(2).fixtureFrame("paste")
            }
            HStack {
                ForEach(["speaking", "readback", "finish", "preparing", "selection-replace"], id: \.self) { name in
                    Button("Silent " + name) { self.model.fixture(name) }.accessibilityIdentifier("qa-fixture-\(name)")
                }
                Button("Hidden pill menu") {
                    self.makeContextMenu().popUp(positioning: nil, at: NSPoint(x: 20, y: 20), in: self.settings.contentView)
                }.accessibilityIdentifier("qa-fixture-hidden-menu")
            }
            .controlSize(.small).fixtureFrame("silent")
            // 2.3 U2 wings (scenario wings-u2): each wing state of the 3-wings mock, silently.
            HStack {
                ForEach(["launcher", "recording", "recording-vad", "recording-ptt-long", "setup-error", "speaking-collapsed"], id: \.self) { name in
                    Button("Wing " + name) { self.model.fixture(name) }.accessibilityIdentifier("qa-fixture-\(name)")
                }
                Button("Hold menu queue") { self.holdsMenuQueue = true; self.model.receipt("menu-queue-held") }
                    .accessibilityIdentifier("qa-fixture-hold-menu-queue")
                Button("Release menu queue") { self.releaseMenuQueue() }
                    .accessibilityIdentifier("qa-fixture-release-menu-queue")
            }.controlSize(.small).padding(2).fixtureFrame("wings")
            playbackFixtureRow().fixtureFrame("playback-2.4") // Lane B providers (UIE2EPlaybackFixtures.swift)
            // 2.4 #813 (Lane A): one provider per E2E flow, `qa-fixture-2.4-<name>`, each ending in the receipt
            // `fixture:2.4-<name>`. Synthetic only: no device, no audio, nothing outside the sandbox.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 2) {
                ForEach(UIE2EModel.laneAFixtures24, id: \.self) { name in
                    Button(name) { self.model.fixture("2.4-" + name) }
                        .accessibilityIdentifier("qa-fixture-2.4-\(name)")
                }
            }.controlSize(.mini).padding(2).fixtureFrame("e2e24-lane-a")
            // Preserve Settings' real minimum viewport for its inner scrollers;
            // only the small overflow below the fixture rows scrolls here.
            ScrollView(.vertical) {
                UIE2ESettings(model: model).frame(height: 620).fixtureFrame("settings")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fixtureFrame("settings-viewport")
        }
        .onPreferenceChange(UIE2EFixtureFrames.self, perform: onFixtureFrames)
    }

    /// Same operational input, morph canvas and hit configuration used by the production
    /// host. The QA-only capture placement keeps its core stable and away from Settings.
    /// No AppDelegate is constructed and no production services are started.
    func panelLayout() -> VoiceBarPanelLayout {
        Self.panelLayout(for: model.voice, historyOpen: notchModel?.isHistoryPanelOpen ?? false,
                         historyRows: notchModel?.historyRows ?? NotchHistoryMorph.visibleRows, screenGeometry: hostGeometry)
    }

    static func panelLayout(for state: VoiceState, historyOpen: Bool = false,
                            historyRows: Int = NotchHistoryMorph.visibleRows,
                            screenGeometry: VoiceBarNotchScreenGeometry? = nil) -> VoiceBarPanelLayout {
        if let geometry = screenGeometry {
            let model = VoiceBarNotchPresentationModel()
            AppDelegate.refreshNotchPresentationModel(model, for: state, coreWidth: geometry.housingFrame.width,
                visibleCoreOcclusionInset: geometry.visibleCoreOcclusionInset,
                virtualNotchIdleCoreHeight: geometry.virtualNotchIdleCoreHeight)
            model.setHistoryRows(historyRows)
            model.setHistoryPanelOpen(historyOpen)
            return layout(presentation: model.presentation, state: state)
        }
        var input = VoiceBarNotchOperationalInput(
            mode: state.mode,
            showsRecordingHold: state.mode == .recording && state.recordingMode == "vad",
            showsRecordingPause: state.mode == .recording && state.recordingMode == "ptt",
            hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isTeleprompterReadback: state.isTeleprompterReadback,
            isPlaybackPaused: state.isPlaybackPaused,
            readQueueLeadingSlotCount: VoiceBarPresentation.playbackLeadingSlotCount(for: state),
            confirmationText: state.confirmationText,
            commandModeState: state.commandModeState,
            activeClipMarker: state.activeClipMarker,
            queueDepth: state.queueDepth,
            keepsPasteFlowEnvelope: state.keepsPasteFlowEnvelope,
            hotkeyPhase: state.presentedHotkeyPhase,
            statusText: VoiceBarPresentation.liveStatusText(mode: state.mode, transcript: state.transcript,
                confirmationText: state.confirmationText, hotkeyPhase: state.presentedHotkeyPhase,
                hotkeyEnabled: state.hotkeyEnabled, errorMessage: state.errorMessage,
                transcribingStatusText: state.transcribingStatusText, commandModeState: state.commandModeState,
                activeClipMarker: state.activeClipMarker),
            isHovered: state.isHovering,
            isKeyboardFocused: false,
            isCollapsed: state.isCollapsed,
            visibleCoreOcclusionInset: 0,
            transientNote: state.selectionFeedbackNote,
            transientNoteOffersHistory: state.selectionFeedbackNoteOffersHistory,
            showsEarlierTakeProcessing: VoiceBarPresentation.showsEarlierTakeProcessing(for: state))
        input.isHistoryPanelOpen = historyOpen
        input.historyRows = historyRows
        input.showsIdleMicrophoneControl = VoiceBarPresentation.showsIdleMicrophoneControl(for: state)
        let presentation = VoiceBarPresentation.notchPresentation(from: input)
        return layout(presentation: presentation, state: state)
    }

    private static func layout(presentation: VoiceBarNotchPresentation, state: VoiceState) -> VoiceBarPanelLayout {
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation)
        return VoiceBarPanelLayout.make(presentation: presentation,
            interactionConfiguration: AppDelegate.notchInteractionConfiguration(
                for: state, visualState: presentation.visualState, bandState: presentation.bandState,
                visibleCoreOcclusionInset: presentation.visibleCoreOcclusionInset),
            canvasGeometry: canvas.canvasGeometry)
    }

    static func fitPill(_ panel: FloatingPillPanel, layout: VoiceBarPanelLayout, in screen: CGRect) {
        panel.contentView?.setFrameSize(layout.panelSize)
        panel.setFrame(VoiceBarIsolatedCapturePlacement.frame(layout: layout, visibleFrame: screen,
            environment: [VoiceBarIsolatedCapturePlacement.topRightEnvironmentVariable: "1"]), display: true)
    }

    private func fitPill(in screen: NSScreen) {
        let layout = panelLayout()
        if let geometry = hostGeometry {
            pill.contentView?.setFrameSize(layout.panelSize)
            pill.setFrame(layout.windowFrame(anchoredTo: geometry), display: true)
            UIE2ECaptureFixtures.receipt(sandbox: sandbox, geometry: geometry, panel: pill, state: model.voice)
        } else { Self.fitPill(pill, layout: layout, in: screen.visibleFrame) }
    }

    /// U2×U4 review: the QA BarView renders this model, so it is fed from VoiceState exactly like the app's
    /// (`AppDelegate.refreshNotchPresentationModel`), on every fixture and every layout change.
    func bindNotchModel(_ notchModel: VoiceBarNotchPresentationModel) {
        self.notchModel = notchModel
        model.onFixtureApplied = { [weak self] in self?.updatePillLayout(); self?.publishTakeIdentity() }
        refreshNotchModel()
    }

    /// 2.4 #813: the recording take's identity, readable natively as the pill's AX value and as static text
    /// `recording-take-id` (a window's own AXValue is often nil). QA host only; the product shows no take id.
    private var takeIdentityLabel: NSTextField?

    private func installTakeIdentity(on host: NSView) {
        let label = UIE2ETakeIdentityLabel(labelWithString: "")
        label.setAccessibilityIdentifier("recording-take-id")
        label.alphaValue = 0.02
        label.frame = NSRect(x: 0, y: 0, width: 2, height: 2)
        host.addSubview(label)
        takeIdentityLabel = label
        publishTakeIdentity()
    }

    func publishTakeIdentity() {
        let take = model.recordingTakeID ?? ""
        takeIdentityLabel?.stringValue = take
        takeIdentityLabel?.setAccessibilityLabel(take.isEmpty ? "no take" : take)
        pill?.setAccessibilityValue(model.recordingTakeID)
    }

    func refreshNotchModel() {
        guard let notchModel else { return }
        AppDelegate.refreshNotchPresentationModel(notchModel, for: model.voice,
            coreWidth: hostGeometry?.housingFrame.width ?? VoiceBarNotchContract.coreWidth,
            visibleCoreOcclusionInset: hostGeometry?.visibleCoreOcclusionInset ?? 0,
            virtualNotchIdleCoreHeight: hostGeometry?.virtualNotchIdleCoreHeight)
    }

    func updatePillLayout() {
        refreshNotchModel()
        guard !contextMenuTracking else {
            model.receipt("qa-menu-layout-deferred")
            return
        }
        guard let pill, let screen = NSScreen.main else { return }
        fitPill(in: screen)
    }

    /// 2.3 U2: the production handoff; only the scheduler can be held (QA) and the outcomes become receipts.
    private func makeSurfaceHandoff() -> VoiceBarNotchSurfaceHandoff {
        let handoff = VoiceBarNotchSurfaceHandoff(bridge: historyBridge, presentationModel: notchModel) { [weak self] kind in
            self?.presentNotchMenu(kind)
        }
        handoff.schedule = { [weak self] block in
            guard let self, holdsMenuQueue else { return DispatchQueue.main.async(execute: block) }
            heldMenuPresentations.append(block)
            model.receipt(self.surfaceHandoff.coordinator.queuedMenu == .notch ? "notch-menu-queued" : "microphone-list-queued")
        }
        handoff.onOutcome = { [weak self] outcome in
            switch outcome {
            case .presented(let kind): self?.model.receipt(kind == .notch ? "notch-menu-open" : "microphone-list-open")
            case .cancelled(let kind): self?.model.receipt(kind == .notch ? "notch-menu-cancelled" : "microphone-list-cancelled")
            }
        }
        return handoff
    }

    private func releaseMenuQueue() {
        holdsMenuQueue = false
        let held = heldMenuPresentations
        heldMenuPresentations.removeAll()
        model.receipt("menu-queue-released")
        // Run after the release button's own click, as the app's scheduled block would.
        for block in held { DispatchQueue.main.async(execute: block) }
    }

    /// The shared handoff's presenter: the production menu under the core or microphone wing (modal).
    private func presentNotchMenu(_ kind: VoiceBarNotchMenuKind) {
        guard let pill, let content = pill.contentView else { return }
        menu.microphonePickerRowsProvider = { [model] in MicrophonePickerRow.rows(from: model.microphone) }
        let list = kind == .notch ? menu.makeNotchMenu() : menu.makeMicrophonePickerMenu()
        list.items.first?.setAccessibilityIdentifier(kind == .notch ? "uie2e-notch-menu" : "uie2e-microphone-list")
        list.delegate = self
        if kind == .notch { list.minimumWidth = panelLayout().presentation.geometry.topWidth }
        let origin = AppDelegate.notchMenuOrigin(kind: kind, menuWidth: list.size.width,
                                                 layout: panelLayout())
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        list.popUp(positioning: nil, at: content.convert(origin, from: nil), in: content)
    }

    /// 2.3 U2: the badged gear opens Settings › General scrolled to Permissions.
    func openSetupSettings() {
        model.tab = .general
        model.focus = .permissions
        model.requestID += 1
        settings.makeKeyAndOrderFront(nil)
        model.receipt("setup-settings")
    }

    private func makeContextMenu() -> NSMenu {
        let result = menu.makeMenu()
        Self.identifyRecentMenuItems(result)
        result.delegate = self
        return result
    }

    static func identifyRecentMenuItems(_ menu: NSMenu) {
        // Composite native title/subtitle is not a stable XCUITest query key.
        // Tag only the QA instance while retaining the real titles and actions.
        for parent in menu.items where parent.title == "Microphone" {
            parent.setAccessibilityIdentifier("uie2e-microphone-menu")
            for child in parent.submenu?.items ?? [] {
                if child.title.hasPrefix("Default:") { child.setAccessibilityIdentifier("uie2e-microphone-default") }
                if child.title == MicrophoneDefaultPresentation.changeTitle {
                    child.setAccessibilityIdentifier("uie2e-microphone-change")
                }
            }
        }
        // Native NSMenuItem's AX title is not its XCUIElement.label. Keep the
        // production controller/title/action and tag only this synthetic row.
        for item in menu.items.flatMap({ $0.submenu?.items ?? [] })
            where item.representedObject as? String == UIE2EModel.transcript {
            item.setAccessibilityIdentifier("uie2e-recent-qa-recording")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        contextMenuTracking = true
        model.voice.beginModalInteraction()
        model.receipt("qa-menu-open")
    }

    func menuDidClose(_ menu: NSMenu) {
        contextMenuTracking = false
        model.voice.endModalInteraction()
        updatePillLayout()
        model.receipt("qa-menu-close")
    }

    func openWizard() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SetupWizardView.contentSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "VoiceBar QA Setup"
        window.isReleasedWhenClosed = false
        let defaults = UserDefaults(suiteName: "com.voicelayer.uie2e.wizard.\(sandbox.root.lastPathComponent)")!
        let controller = SetupWizardController(store: SetupWizardCompletionStore(defaults: defaults),
            model: .init(), onClose: { [weak self, weak window] in
                window?.orderOut(nil); self?.settings.makeKeyAndOrderFront(nil)
            })
        window.contentView = NSHostingView(rootView: SetupWizardView(controller: controller,
            dependencies: .init(permissionSnapshot: { .allGranted },
                onRequestMicrophone: { done in self.model.receipt("wizard-permission-fixture"); done() },
                openURL: { self.model.receipt("wizard-url:" + $0.absoluteString) },
                f5KeyStatus: { .init(listenerActive: true, helperInstalled: true) },
                onRunRelaySetup: { done in done(.installerRun(exitCode: 7, output: "QA fixture only", missingAfter: [], finishedAt: Date())) },
                onRestartHotkeyListener: { .failed(missing: []) },
                defaultMicrophoneName: { "QA microphone A" }, onChangeMicrophone: { self.model.receipt("wizard-microphone") },
                tryItObservation: { .none })))
        wizard = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }
        let presenter = MenuBarPopoverPresenter { [unowned self] in
            AnyView(MenuBarPopoverView(
                footer: .resolve(isConnected: true, mode: .idle, captureLive: false, errorMessage: nil, remoteSTTConfigured: false),
                hotkeyHint: "QA · hotkeys disabled", defaultMicrophoneName: "QA microphone A",
                transcript: UIE2EModel.transcript, onCopy: { self.model.copy(UIE2EModel.transcript) },
                onSettings: { self.popoverPresenter?.close(); self.settings.makeKeyAndOrderFront(nil); self.model.receipt("popover-settings") },
                onQuit: { self.model.receipt("popover-quit"); NSApp.terminate(nil) },
                // A fixture broken step, so the popover's setup row exists; it opens General at Setup.
                setupAlert: MenuBarSetupAlert(setup: SettingsGeneralSetup(
                    permissions: SetupPermissionsStep(snapshot: SetupPermissionSnapshot(
                        microphone: .granted, accessibilityGranted: false, inputMonitoringGranted: true,
                        hotkeyListenerActive: true)).rows,
                    hotkeyListenerActive: true, f5CheckedAt: nil, voice: nil)),
                onFixSetup: { self.popoverPresenter?.close(); self.model.tab = .general; self.model.focus = .permissions
                    self.model.requestID += 1; self.model.receipt("popover-setup") },
                onChangeMicrophone: { self.popoverPresenter?.close(); self.model.tab = .general; self.model.requestID += 1; self.model.receipt("popover-microphone") }))
        }
        popoverPresenter = presenter
        statusController = MenuBarStatusItemController(button: button, presenter: presenter)
        Self.identifyStatusButton(button)
    }

    static func identifyStatusButton(_ button: NSButton) {
        button.setAccessibilityTitle("VoiceBar QA")
        // NSButton otherwise derives AXLabel from the production SF Symbol's
        // accessibilityDescription ("VoiceBar"), overriding the QA title.
        button.setAccessibilityLabel("VoiceBar QA")
        button.setAccessibilityIdentifier("uie2e-status-item")
    }

    private func configureMenu() {
        menu.updateStatusProvider = { VoiceBarVersionStatus.latest.menuMessage }
        menu.transcriptProvider = { UIE2EModel.transcript }
        menu.recentTranscriptionEntriesProvider = { [self.model.recent] }
        menu.defaultMicrophoneNameProvider = { "QA microphone A" }
        menu.isSnoozedProvider = { self.model.hidden }
        menu.onOpenSettings = { self.settings.makeKeyAndOrderFront(nil); self.model.receipt("menu-settings") }
        menu.onSnooze = { self.model.hidden = true; self.model.receipt("menu-hide") }
        menu.onUnsnooze = { self.model.hidden = false; self.model.receipt("menu-show") }
        menu.onChangeMicrophone = { self.model.tab = .general; self.model.requestID += 1; self.model.receipt("menu-microphone") }
        menu.onPasteLastTranscript = { self.model.receipt("menu-paste-last") }
        menu.onPasteTranscript = { text in self.model.receipt("menu-paste-recent:" + text) }
        menu.onCopyLastTranscript = { _ = self.model.copy(UIE2EModel.transcript) }
        // Re-transcribe is UI-only: the sink records intent, never runs STT.
        menu.canRetranscribeLatestProvider = { true }
        menu.onRetranscribeLatest = { self.model.receipt("menu-retranscribe") }
        menu.onQuit = { self.model.receipt("menu-quit"); NSApp.terminate(nil) }
    }
}

@MainActor @Observable
final class UIE2EModel {
    static let transcript = "QA fixture transcript שלום 👋"
    let sandbox: UIE2ESandbox
    let voice = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
        recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
        transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] })
    var entries = [STTDictionaryEntry(canonical: "QA initial", variants: ["initial variant"])]
    /// Lane B answers playback commands only while one of its own fixtures is presented; every other fixture
    /// (for example `speaking`, pinned by UIE2EPlaybackFixtureTests) keeps the host's pause/resume/seek fakes.
    var playbackFixturePresented = false
    var revision: UInt64 = 0
    var hidden = false { didSet { onVisibilityChange?(hidden) } }
    var onVisibilityChange: ((Bool) -> Void)?
    var tab: SettingsTab = .general
    var focus: SettingsFocus?
    var requestID = 0
    var events: [String] = []
    var commands: [[String: Any]] = []
    var selectionText = "QA original selection"
    private var holdsFixturePresentation = false
    /// The QA host refreshes its notch presentation model after every fixture (U2×U4 review).
    var onFixtureApplied: () -> Void = {}
    var residency = "loaded"
    var processing: [String: Any] = [:]
    var speech: [String: Any] = [:]
    var microphoneOrder = ["a", "b"]
    /// 2.4 #813: the permissions Settings reports broken (the QA baseline keeps the two it always showed).
    var missingPermissions: [HotkeyPermission] = [.accessibility, .inputMonitoring]
    /// 2.4 #813: the synthetic recording take, exposed natively by the host (`recording-take-id`).
    var recordingTakeID: String?
    var syntheticCaptureClockMs: Int?
    var onNotchSurface: (NotchSurfaceEvent) -> Void = { _ in }
    var onShowSettings: () -> Void = {}
    var recent: RecentTranscriptionEntry { .init(text: Self.transcript, createdAt: Date(timeIntervalSince1970: 1_790_000_000)) }

    /// 2.3 U4 native test only (`VOICEBAR_UIE2E_NOTCH_HISTORY_ROWS=N`): N synthetic dictations in the notch History
    /// panel, enough for its extend handle to reach 12 rows. Unset (every scenario run), nothing changes.
    func seedNotchHistoryIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_NOTCH_HISTORY_ROWS"],
              let count = Int(raw), (1 ... 40).contains(count) else { return }
        voice.recentTranscriptionEntries = (0 ..< count).map { index in
            RecentTranscriptionEntry(text: "QA notch row \(index + 1)", recordingPath: sandbox.root
                .appendingPathComponent("notch-\(index).wav").path, createdAt: Date().addingTimeInterval(Double(-60 * index)))
        }
    }

    init(sandbox: UIE2ESandbox) {
        self.sandbox = sandbox
        func field(_ value: Any) -> [String: Any] { ["source": "settings", "raw": value, "effective": value] }
        let profile: [String: Any] = ["engine": field("clone"), "voice": field("theo-c4s"), "rate": field("+0%")]
        speech = ["profiles": ["short": profile, "long": profile], "short_limit_chars": field(400),
                  "clone_daemon": "down", "available_voices": [
                    ["engine": "edge", "voice": "en-US-JennyNeural"], ["engine": "edge", "voice": "en-US-GuyNeural"],
                    ["engine": "clone", "voice": "theo-c4s"], ["engine": "clone", "voice": "ben-c1"]]]
        for (key, value) in [("model_polish", "off" as Any), ("outro_gate", true), ("smart_chunks", false)] {
            processing[key] = ["source": "settings", "raw": NSNull(), "effective": value]
        }
        // Existing test seams: even accidental paste/record intents cannot reach the host.
        voice.controlLayerEventWriter = { _, _ in } // Also isolated before any host/window exists.
        voice.pasteHandler = { _ in true }
        voice.frontmostAppProvider = { nil }
        voice.selectionTextCaptureHandler = { [weak self] done in done(.completed(self?.selectionText ?? "")) }
        voice.sendCommand = { [weak self] command in self?.command(command) }
        refresh()
        persistDictionary()
    }

    var preview: STTVocabularyPreview {
        .init(updatedAt: nil, entries: entries, displayEntries: entries.map { .init(source: "personal", entry: $0) } + [
            .init(source: "bundled", entry: .init(canonical: "TypeScript", variants: ["type script"]))])
    }
    var history: SettingsHistoryPage {
        let entry = SettingsHistoryEntry(id: "qa-recording", dayKey: "2026-10-15", recordingID: "qa-recording",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), transcript: Self.transcript,
            audioPath: sandbox.root.appendingPathComponent("fixture.wav"), durationMs: 5000,
            modelLabel: "QA recognizer", performanceEffort: .accurate, inputDeviceLabel: "QA microphone A")
        // V27: the older row is on the day before, so the newest (selected) row is the last of its day, directly
        // above the next day's header: the row Etan saw clipped.
        let older = SettingsHistoryEntry(id: "qa-older", dayKey: "2026-10-14", recordingID: "qa-older",
            createdAt: entry.createdAt.addingTimeInterval(-86_400), transcript: "QA older transcript",
            audioPath: sandbox.root.appendingPathComponent("older.wav"))
        return .init(groups: [.init(dayKey: entry.dayKey, date: entry.createdAt, entries: [entry]),
                              .init(dayKey: older.dayKey, date: older.createdAt, entries: [older])], hasMore: true)
    }
    var askHistory: SettingsAskHistoryPage {
        let entry = SettingsAskHistoryEntry(id: "qa-ask", dayKey: "2026-10-15", askID: "qa-ask", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            questionText: "QA question", questionAudioPath: nil, responseTranscript: "QA response", responseAudioPath: nil)
        return .init(groups: [.init(dayKey: entry.dayKey, date: entry.createdAt, entries: [entry])], hasMore: true)
    }
    func historyPage(limit: Int) -> SettingsHistoryPage {
        receipt("history-page:" + String(limit))
        guard limit > 100, let group = history.groups.last else { return history }
        let entry = SettingsHistoryEntry(id: "qa-loaded", dayKey: group.dayKey, recordingID: "qa-loaded",
            createdAt: group.date.addingTimeInterval(-240), transcript: "QA loaded transcript",
            audioPath: sandbox.root.appendingPathComponent("loaded.wav"))
        return .init(groups: history.groups.dropLast() + [.init(dayKey: group.dayKey, date: group.date,
                                                              entries: group.entries + [entry])], hasMore: false)
    }
    func askHistoryPage(limit: Int) -> SettingsAskHistoryPage {
        receipt("ask-history-page:" + String(limit))
        guard limit > 100, let group = askHistory.groups.first else { return askHistory }
        let entry = SettingsAskHistoryEntry(id: "qa-ask-loaded", dayKey: group.dayKey, askID: "qa-ask-loaded",
            createdAt: group.date.addingTimeInterval(-240), questionText: "QA loaded question", questionAudioPath: nil,
            responseTranscript: "QA loaded response", responseAudioPath: nil)
        return .init(groups: [.init(dayKey: group.dayKey, date: group.date, entries: group.entries + [entry])], hasMore: false)
    }
    var microphone: MicrophonePrioritySnapshot {
        .init(rows: microphoneOrder.map { .init(uid: $0, deviceID: $0, label: "QA microphone \($0.uppercased())", isConnected: true) },
              nextDeviceName: "QA microphone \(microphoneOrder[0].uppercased())")
    }
    func receipt(_ value: String) { events.append(value); sandbox.write(events, file: "events.json") }
    func persistDictionary() { sandbox.write(entries, file: "dictionary.json"); revision += 1 }
    func add(_ term: String, variant: String? = nil) {
        if let i = entries.firstIndex(where: { $0.canonical == term }) {
            if let variant, !entries[i].variants.contains(variant) { entries[i].variants.append(variant) }
        } else { entries.append(.init(canonical: term, variants: variant.map { [$0] } ?? [])) }
        persistDictionary()
    }
    func remove(_ term: String, variant: String? = nil) {
        if let variant, let i = entries.firstIndex(where: { $0.canonical == term }) { entries[i].variants.removeAll { $0 == variant } }
        else { entries.removeAll { $0.canonical == term } }
        persistDictionary()
    }
    func pasteHistoryTranscript(_ text: String) { receipt("history-paste:" + text) }

    func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
    func refresh() {
        voice.setConnectionStatus(true)
        voice.handleEvent(["type": "health", "recording_state": "idle", "tts_controls": speech, "polish_controls": processing,
            "model_status": ["residency": residency, "configured_effort": "accurate",
                             "configured_model": ["name": "QA recognizer", "installed": true, "size_bytes": 1_000_000]]])
    }
    func command(_ message: [String: Any]) {
        commands.append(message)
        sandbox.writeObject(["messages": commands], file: "commands.json")
        let cmd = message["cmd"] as? String ?? ""
        receipt("command:" + cmd)
        if answerPlaybackCommand(cmd, message) { return } // Lane B (UIE2EPlaybackFixtures.swift)
        switch cmd {
        case "health": refresh(); return
        case "speak_text":
            // Real VoiceState selection routing ends here, never at a daemon or AX capture.
            voice.handleEvent(["type": "state", "state": "speaking", "duration_ms": 600_000,
                "text": message["text"] as? String ?? "",
                "long_read": ["id": message["id"] as? String ?? "qa-selection",
                              "chunk_start_ms": 0]])
            return
        case "speech_seek":
            guard let table = voice.speechWords,
                  message["utteranceId"] as? String == table.utteranceID,
                  let index = message["wordIndex"] as? Int, table.words.indices.contains(index),
                  let word = table.words[index] else { return }
            voice.handleEvent(["type": "state", "state": "speaking", "text": voice.statusText,
                "utteranceId": table.utteranceID, "playback_offset_ms": word.startMs,
                "playback_id": "qa-player", "generation": 1,
                "duration_ms": max(1, table.words.compactMap { $0?.endMs }.max() ?? 1)])
            return
        case "pause", "resume":
            voice.handleEvent(["type": "ack", "command": cmd, "id": message["id"] ?? "", "outcome": "accept"])
            if cmd == "resume" {
                var speaking: [String: Any] = ["type": "state", "state": "speaking", "text": voice.statusText,
                    "duration_ms": 600_000, "playback_offset_ms": voice.playbackElapsedMilliseconds(),
                    "playback_id": message["playback_id"] ?? "qa-player", "generation": message["generation"] ?? 1]
                if let table = voice.speechWords { speaking["utteranceId"] = table.utteranceID }
                voice.handleEvent(speaking)
            }
            var event = message
            event["type"] = "playback_state"
            event["state"] = cmd == "pause" ? "paused" : "resumed"
            event["pause_owner"] = "user"
            event["offset_ms"] = message["playback_elapsed_ms"]
            voice.handleEvent(event)
            return
        case "replay", "stop":
            // Synthetic daemon responses only, for native layout transitions. This
            // proves BarView geometry, never real replay admission or audio lifecycle.
            voice.handleEvent(["type": "ack", "command": cmd, "id": message["id"] ?? "", "outcome": "accept"])
            fixture(cmd == "replay" ? "speaking" : "finish")
            return
        case "set_whisper_residency": residency = message["action"] as? String == "load" ? "loaded" : "not_loaded"
        case "set_processing_setting":
            if let key = message["key"] as? String, let value = message["value"] { let stored: Any = key == "model_polish" ? ((value as? Bool == true) ? "on" : "off") : value
                processing[key] = ["source": "settings", "raw": NSNull(), "effective": stored] }
        case "set_tts_setting" where message["profile"] == nil:
            if let key = message["key"] as? String, let value = message["value"] {
                let parts = key.split(separator: ".").map(String.init)
                if parts.count == 2, var profiles = speech["profiles"] as? [String: [String: Any]] {
                    profiles[parts[0]]?[parts[1]] = ["source": "settings", "raw": value, "effective": value]; speech["profiles"] = profiles
                } else { speech[key] = ["source": "settings", "raw": value, "effective": value] }
            }
        case "set_tts_setting":
            if let kind = message["profile"] as? String, var profiles = speech["profiles"] as? [String: [String: Any]] {
                for key in ["engine", "voice"] { if let value = message[key] { profiles[kind]?[key] = ["source": "settings", "raw": value, "effective": value] } }
                speech["profiles"] = profiles
            }
        default: return // No audio/capture/process/socket command has an implementation.
        }
        voice.handleEvent(["type": "ack", "command": cmd, "id": message["id"] ?? "", "outcome": "accept", "tts_controls": speech, "polish_controls": processing])
        sandbox.writeObject(speech, file: "speech.json")
        sandbox.writeObject(processing, file: "processing.json")
        refresh()
    }
    /// 2.4 #813: Lane A's 22 providers (REVIEW-813 contract table, rows 1, 2, 5 to 24).
    static let laneAFixtures24 = [
        "settings", "history", "recording", "paste-failed", "queued", "typed-feedback", "microphone-priority",
        "permission-revoked", "history-expanded", "history-20", "recording-long-microphone-name",
        "record-after-record", "history-dictation", "history-ask", "history-speak",
        "tooltips-launcher", "tooltips-recording", "tooltips-transcribing", "tooltips-speaking", "tooltips-readback",
        "tooltips-history", "tooltips-settings",
    ]

    /// Puts the QA app into the real product state each 2.4 flow starts from. Every state below is one the
    /// production code reaches; nothing is drawn only for the test except the take identity the host exposes.
    private func apply24(_ name: String) {
        recordingTakeID = nil
        onNotchSurface(.dismiss(.action))
        let baseline = {
            self.missingPermissions = [.accessibility, .inputMonitoring]
            self.voice.setSetupMissingPermissions([])
            self.refresh()
            self.voice.handleEvent(["type": "state", "state": "idle"])
            self.voice.dismissRetainedTeleprompter()
        }
        func showSettings(_ tab: SettingsTab, focus: SettingsFocus? = nil) {
            self.tab = tab; self.focus = focus; requestID += 1; onShowSettings()
        }
        func seedHistory(_ count: Int) {
            voice.recentTranscriptionEntries = (0 ..< count).map { index in
                RecentTranscriptionEntry(text: "QA notch row \(index + 1)", recordingPath: sandbox.root
                    .appendingPathComponent("notch-\(index).wav").path, createdAt: Date().addingTimeInterval(Double(-60 * index)))
            }
        }
        func hoverHeld() {
            voice.isHovering = true
            voice.beginModalInteraction(); holdsFixturePresentation = true
        }
        func recording(queueDepth: Int = 0) {
            voice.setSetupMissingPermissions([])
            voice.handleEvent(["type": "state", "state": "recording", "mode": "ptt"])
            if queueDepth > 0 { voice.handleEvent(["type": "queue", "depth": queueDepth]) }
            recordingTakeID = "qa-take-\(queueDepth + 1)"
        }
        switch name {
        case "settings": baseline(); showSettings(.general)
        case "history": baseline(); showSettings(.history)
        case "recording", "recording-long-microphone-name", "tooltips-recording":
            baseline(); recording()
        case "queued", "record-after-record":
            // Take 1 still processing behind take 2's live recording (the daemon's queue depth).
            baseline(); recording(queueDepth: 1)
        case "paste-failed":
            baseline(); voice.mode = .idle
            voice.confirmationText = "Paste failed. Click the text field and press Shift+F5."
            hoverHeld()
        case "typed-feedback":
            // The product's typed feedback is the one-line "Typed" confirmation; there is no typed-feedback field.
            baseline(); voice.mode = .idle; voice.confirmationText = "Typed"; hoverHeld()
        case "microphone-priority":
            baseline(); microphoneOrder = ["a", "b", "c"]; showSettings(.general, focus: .microphonePriority)
        case "permission-revoked":
            baseline(); missingPermissions = [.accessibility]; voice.setSetupMissingPermissions([.accessibility])
            showSettings(.general, focus: .permissions)
        case "history-expanded", "history-20", "tooltips-history":
            baseline(); seedHistory(20); hoverHeld()
            onNotchSurface(.openHistory)
            onNotchSurface(.setHistoryDetent(name == "history-expanded" ? .expanded : .collapsed))
        case "history-dictation", "history-ask", "history-speak":
            baseline(); showSettings(.history)
        case "tooltips-launcher": baseline(); seedHistory(3); hoverHeld()
        case "tooltips-transcribing": baseline(); voice.handleEvent(["type": "state", "state": "transcribing"])
        case "tooltips-speaking", "tooltips-readback":
            baseline(); voice.isHovering = true
            voice.handleEvent(["type": "state", "state": "speaking", "duration_ms": 600_000,
                "text": "First QA item\nSecond QA item", "readback_id": "qa-readback"])
            if name == "tooltips-readback" { voice.handleEvent(["type": "state", "state": "idle", "source": "playback"]) }
        case "tooltips-settings":
            // Settings in the notch: its tabs and buttons are pill controls now.
            baseline(); hoverHeld(); onNotchSurface(.openSettings(.general))
        default: baseline()
        }
    }

    func fixture(_ name: String) {
        syntheticCaptureClockMs = nil
        if holdsFixturePresentation { voice.endModalInteraction(); holdsFixturePresentation = false }
        voice.confirmationText = nil
        if ["confirmation", "paste-failed", "paste-not-inserted", "paste-unverified", "paste-partial", "paste-typed"].contains(name) {
            // These are held visual fixtures, not a claim about note lifetime.
            // A real pointer exit must not collapse the fixture before its frame is measured.
            voice.beginModalInteraction()
            holdsFixturePresentation = true
        }
        playbackFixturePresented = applyPlaybackFixture(name)
        if playbackFixturePresented { receipt("fixture:" + name); onFixtureApplied(); return } // Lane B
        switch name {
        case "preparing":
            // Establish the actual original selection request before the daemon's
            // Preparing event, then change only the synthetic selection capture.
            voice.mode = .idle
            refresh()
            selectionText = "QA original selection"
            voice.speakSelection()
            voice.isHovering = true
            voice.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                "long_read": ["id": commands.last?["id"] as? String ?? "qa-selection", "chunk_index": 0, "chunk_count": 1,
                              "chunk_start_ms": 0, "preparing": true]])
            sandbox.writeObject(["mode": voice.mode.rawValue, "statusText": voice.statusText,
                "durationGrowing": voice.isPlaybackDurationGrowing,
                "originalRequested": commands.contains { $0["cmd"] as? String == "speak_text" &&
                    $0["text"] as? String == "QA original selection" }], file: "preparing.json")
            selectionText = "QA replacement selection"
        case "selection-replace": voice.speakSelection()
        case "speaking", "readback":
            voice.isHovering = true
            voice.handleEvent(["type": "state", "state": "speaking", "duration_ms": 600_000,
                "text": "First QA item\nSecond QA item", "readback_id": "qa-readback",
                "playback_id": "qa-player", "generation": 1, "utteranceId": "qa-utterance"])
            // Decode the legacy wire shape too: works on both main and CLN1b's typed boundaries.
            voice.handleEvent(["type": "subtitle", "words": [
                ["offset_ms": 0, "duration_ms": 1000, "text": "First"],
                ["offset_ms": 1000, "duration_ms": 1000, "text": "QA"],
                ["offset_ms": 2000, "duration_ms": 1000, "text": "item"],
                ["offset_ms": 3000, "duration_ms": 1000, "text": "Second"],
                ["offset_ms": 4000, "duration_ms": 1000, "text": "QA"],
                ["offset_ms": 5000, "duration_ms": 1000, "text": "item"]]])
            if name == "readback" { voice.handleEvent(["type": "state", "state": "idle", "source": "playback"]) }
        case "finish": voice.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        case "idle":
            voice.setSetupMissingPermissions([])
            // Preserve the existing fixture contract: every idle reset restores
            // the synthetic health/connection baseline before clearing playback.
            refresh()
            // This is fixture cleanup, not playback completion: omitting the
            // playback source clears status without retaining it as readback.
            voice.handleEvent(["type": "state", "state": "idle"])
            voice.dismissRetainedTeleprompter()
            voice.setHovering(false)
        case "confirmation": voice.mode = .idle; voice.confirmationText = "Pasted"
        case "paste-not-inserted": voice.mode = .idle; voice.confirmationText = "Not pasted\nIn History"
        case "paste-unverified": voice.mode = .idle; voice.confirmationText = "Unverified\nIn History"
        case "paste-partial": voice.mode = .idle; voice.confirmationText = "Part pasted\nHistory: full"
        case "paste-typed": voice.mode = .idle; voice.confirmationText = "Typed"
        case "paste-failed": voice.mode = .idle; voice.confirmationText = "Paste failed. Click the text field and press Shift+F5."
        case "error": voice.handleEvent(["type": "error", "message": "QA fixture failure", "recoverable": true])
        case "transcribing": voice.handleEvent(["type": "state", "state": "transcribing"])
        // 2.3 U2 wing states. The launcher and setup-error fixtures hold the hover presentation (a real pointer
        // exit must not collapse them before their frame is measured); recording is a state event only, so no
        // device opens.
        case "launcher", "setup-error":
            refresh(); voice.handleEvent(["type": "state", "state": "idle"])
            voice.setSetupMissingPermissions(name == "setup-error" ? [.accessibility] : [])
            voice.isHovering = true
            voice.beginModalInteraction(); holdsFixturePresentation = true
        case "recording", "recording-ptt", "recording-vad", "recording-ptt-long":
            beginSyntheticCapture(mode: name == "recording-vad" ? "vad" : "ptt",
                                  elapsedMilliseconds: name == "recording-ptt-long" ? 3_661_000 : 12_000)
        case "speaking-collapsed":
            voice.handleEvent(["type": "state", "state": "speaking", "duration_ms": 600_000,
                "text": "First QA item\nSecond QA item", "readback_id": "qa-readback",
                "playback_id": "qa-player", "generation": 1, "utteranceId": "qa-utterance"])
            voice.dismissTeleprompter()
        case "disconnected": voice.setConnectionStatus(false)
        case let lane where lane.hasPrefix("2.4-"): apply24(String(lane.dropFirst(4)))
        default: refresh(); voice.mode = .idle
        }
        if ["launcher", "setup-error", "recording", "transcribing", "speaking-collapsed"].contains(name) {
            // 2.3 U2: the wing widths the production presentation resolves for this state (wings-u2 reads it).
            let geometry = UIE2EHost.panelLayout(for: voice).presentation.geometry
            sandbox.writeObject(["fixture": name, "leadingWingWidth": Double(geometry.leadingWingWidth),
                                 "trailingWingWidth": Double(geometry.trailingWingWidth),
                                 "fixedWingWidth": Double(VoiceBarNotchContract.fixedWingWidth),
                                 "setupNeedsAttention": voice.setupNeedsAttention], file: "wings.json")
        }
        receipt("fixture:" + name)
        onFixtureApplied()
    }
}

private struct UIE2EFixtureFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func fixtureFrame(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: UIE2EFixtureFrames.self,
                value: [name: geometry.frame(in: .global)])
        })
    }
}

private struct UIE2ESettings: View {
    let model: UIE2EModel
    /// Non-nil: the notch Settings drawer's pane for this tab (0510 N1), from the same synthetic stores.
    var notchTab: SettingsTab?
    var notchRequest: SettingsTabRequest?
    var body: some View {
        let history = model.history, asks = model.askHistory
        let settings = SettingsView(hotkeyEnabled: false, missingPermissions: model.missingPermissions,
            availableDevices: { [] }, selectedDeviceID: { nil }, prioritySnapshot: { model.microphone },
            onReorderPriority: {
                model.microphoneOrder = $0; model.receipt("microphone-order")
                model.receipt("microphone-priority:" + $0.joined(separator: ","))
            },
            modelsStatus: { model.voice.modelsSettingsState }, onRefreshModelsStatus: { model.refresh() },
            residencyNotice: { "QA recognizer failure\nSecond line" }, onSelectResidency: { model.voice.setWhisperResidency($0) },
            speechControls: { model.voice.speechControls }, speechConnected: { model.voice.isConnected },
            speechNotice: { "Couldn't complete the speech request - provider unavailable\nFull diagnostic: connection refused · שלום 🎧" },
            onChangeSpeech: { model.voice.setTTSSetting($0, $1) },
            onSelectSpeechEngine: { model.voice.setTTSProfile($0, engine: $1, voice: $2) },
            // Preview deliberately has no callback. It is disabled, and never clicked.
            onToggleProcessing: { model.voice.setProcessingSetting($0, $1) },
            vocabularyPreview: { model.preview }, vocabularyRevision: { model.revision },
            onAddVocabularyAlias: { model.add($0, variant: $1) }, onRemoveVocabularyAlias: { model.remove($0.to, variant: $0.from) },
            onAddPromptTerm: { model.add($0) }, onRemovePromptTerm: { model.remove($0) },
            onCheckShortcut: { $0("QA shortcut failure\nSecond line"); model.receipt("check-shortcut") },
            onRestartHotkeyListener: { model.receipt("restart-listener"); return .failed(missing: []) },
            microphoneAuthorization: { .denied },
            onOpenPermissionURL: { model.receipt("permission:" + $0.absoluteString) },
            isVoiceBarHidden: { model.hidden }, onHideVoiceBar: { model.hidden = true; model.receipt("hide") },
            onShowVoiceBar: { model.hidden = false; model.receipt("show") },
            onRunRelaySetup: { done in model.receipt("relay-setup"); done(.installerRun(exitCode: 7, output: "QA relay failure\nSecond line", missingAfter: [], finishedAt: Date())) },
            lastDictationEntry: { model.recent }, lastDictationInsertionStatus: { .pasted }, onCopyLastDictation: { model.copy($0) },
            historyPage: { await model.historyPage(limit: $0) }, initialHistoryPage: history, askHistoryPage: { await model.askHistoryPage(limit: $0) },
            historySearchPage: { _, query in history.groups[0].entries[0].transcript.localizedCaseInsensitiveContains(query) ? history : .init(groups: [], hasMore: false) },
            askHistorySearchPage: { _, query in "QA question QA response".localizedCaseInsensitiveContains(query) ? asks : .init(groups: [], hasMore: false) },
            searchPrewarm: {}, initialAskHistoryPage: asks, onCopyHistoryTranscript: { _ = model.copy($0) },
            onPasteHistoryTranscript: { model.pasteHistoryTranscript($0) }, onRetranscribeHistoryEntry: { _ in model.receipt("history-retranscribe") },
            onRevealHistoryFile: { _ in model.receipt("history-finder") },
            footerPresentation: { .resolve(isConnected: model.voice.isConnected, mode: model.voice.mode, captureLive: false,
                                            errorMessage: nil, remoteSTTConfigured: false) },
            tabRequest: notchTab == nil ? .init(tab: model.tab, focus: model.focus, id: model.requestID) : notchRequest,
            initialDictionaryPreview: model.preview,
            onSelectedTabChange: { if notchTab == nil { model.tab = $0 } },
            historyPlayback: .init(start: { _ in fatalError("UIE2E forbids playback") }, stop: {}))
        if let notchTab {
            settings.notchDrawerPane(notchTab)
        } else {
            settings
        }
    }
}
/// The host's take identity: readable by XCUI, never hit-tested, never seen.
private final class UIE2ETakeIdentityLabel: NSTextField {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}
#endif

