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
    var settings: NSWindow!
    var pill: FloatingPillPanel!
    let menu = PillContextMenuController()
    var statusItem: NSStatusItem?
    var statusController: MenuBarStatusItemController?
    var popoverPresenter: MenuBarPopoverPresenter?
    var wizard: NSWindow?
    var contextMenuTracking = false
#if VOICEBAR_UIE2E_GATE2245
    var gate2245: UIE2EGate2245?
#endif
#if VOICEBAR_UIE2E_FOCUSED_338
    var stateGallery: UIE2EStateGallery?
#endif

    init(sandbox: UIE2ESandbox) {
        self.sandbox = sandbox
        model = UIE2EModel(sandbox: sandbox)
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
        settings.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            HStack {
                Text("UI ONLY · synthetic data · no audio").font(.caption)
                ForEach(["idle", "transcribing", "confirmation", "paste-failed", "error", "disconnected"], id: \.self) { name in
                    Button(name) { self.model.fixture(name) }.accessibilityIdentifier("qa-fixture-\(name)")
                }
            }.padding(6)
#if VOICEBAR_UIE2E_GATE2245
            gate2245Controls
#endif
            if Bundle.main.object(forInfoDictionaryKey: "UIE2EPasteFeedback") as? Bool == true {
                HStack {
                    ForEach(["paste-not-inserted", "paste-unverified", "paste-partial", "paste-typed"], id: \.self) { name in
                        Button(name) { self.model.fixture(name) }.accessibilityIdentifier("qa-fixture-\(name)")
                    }
                }.padding(6)
            }
            HStack {
                ForEach(["speaking", "readback", "finish", "preparing", "selection-replace"], id: \.self) { name in
                    Button("Silent " + name) { self.model.fixture(name) }.accessibilityIdentifier("qa-fixture-\(name)")
                }
                Button("Hidden pill menu") {
                    self.makeContextMenu().popUp(positioning: nil, at: NSPoint(x: 20, y: 20), in: self.settings.contentView)
                }.accessibilityIdentifier("qa-fixture-hidden-menu")
            }
            UIE2ESettings(model: model)
        })
        let bar = PillHostingView(rootView: BarView(state: model.voice, commandRouter: VoiceBarCommandRouter(voiceState: model.voice),
            onOpenSettings: { self.settings.makeKeyAndOrderFront(nil) },
            onOpenHistory: { self.model.tab = .history; self.model.requestID += 1 },
            includesPanelOutsets: true))
        bar.activeHitTestProvider = { [weak self] point in
            guard let self else { return false }
            return Self.panelLayout(for: self.model.voice).containsInteractiveContent(point)
        }
        bar.renderedSurfaceHitTestProvider = { [weak self] point in
            guard let self else { return false }
            return Self.panelLayout(for: self.model.voice).containsVisibleSurface(point)
        }
        bar.hoverExpansionHitTestProvider = { [weak self] point in
            guard let self else { return false }
            return Self.panelLayout(for: self.model.voice).containsHoverExpansion(point)
        }
        bar.hoverRetentionHitTestProvider = { [weak self] point in
            guard let self else { return false }
            return Self.panelLayout(for: self.model.voice).containsHoverRetention(point)
        }
        bar.onHoverChanged = { [weak self] hovering in
            self?.model.voice.setHoveringFromDebouncedPointer(hovering)
        }
        bar.wantsLayer = true
        bar.layer?.masksToBounds = true
        bar.frame = NSRect(x: 0, y: 0, width: 680, height: 180)
        pill = FloatingPillPanel(content: bar)
        pill.title = "VoiceBar QA Pill"
        pill.setFrame(NSRect(x: 100, y: 20, width: 680, height: 180), display: false)
        model.voice.onPanelLayoutChange = { [weak self] in
            self?.updatePillLayout()
        }
        if let screen = NSScreen.main { Self.fitPill(pill, layout: Self.panelLayout(for: model.voice), in: screen.visibleFrame) }
        model.onVisibilityChange = { [weak self] hidden in
            if hidden { self?.pill?.orderOut(nil) } else { self?.pill?.orderFront(nil) }
        }
        configureMenu()
        pill.contextMenuProvider = { self.makeContextMenu() }
        pill.contextMenuHitTestProvider = { _ in true }
        pill.orderFront(nil)
        settings.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        configureStatusItem()
#if VOICEBAR_UIE2E_GATE2245
        if ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] == "hide1" || ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] == "gate2246" {
            installHide1VisualMenu()
        }
#endif

        model.onRunSetup = { [weak self] in self?.openWizard() }
        model.receipt("launch")
    }

    /// Same operational input, morph canvas and hit configuration used by the production
    /// host. The QA-only capture placement keeps its core stable and away from Settings.
    /// No AppDelegate is constructed and no production services are started.
    static func panelLayout(for state: VoiceState) -> VoiceBarPanelLayout {
        let presentation = VoiceBarPresentation.notchPresentation(from: .init(
            mode: state.mode,
            showsRecordingHold: state.mode == .recording && state.recordingMode == "vad",
            hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isTeleprompterReadback: state.isTeleprompterReadback,
            readQueueLeadingSlotCount: VoiceBarPresentation.readQueueControl(for: state)?.leadingSlotCount ?? 1,
            confirmationText: state.confirmationText,
            commandModeState: state.commandModeState,
            activeClipMarker: state.activeClipMarker,
            queueDepth: state.queueDepth,
            keepsPasteFlowEnvelope: state.keepsPasteFlowEnvelope,
            hotkeyPhase: state.hotkeyPhase,
            statusText: VoiceBarPresentation.liveStatusText(mode: state.mode, transcript: state.transcript,
                confirmationText: state.confirmationText, hotkeyPhase: state.hotkeyPhase,
                hotkeyEnabled: state.hotkeyEnabled, errorMessage: state.errorMessage,
                transcribingStatusText: state.transcribingStatusText, commandModeState: state.commandModeState,
                activeClipMarker: state.activeClipMarker),
            isHovered: state.isHovering,
            isKeyboardFocused: false,
            isCollapsed: state.isCollapsed,
            visibleCoreOcclusionInset: 0,
            transientNote: state.selectionFeedbackNote))
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation)
        return VoiceBarPanelLayout.make(presentation: presentation,
            interactionConfiguration: AppDelegate.notchInteractionConfiguration(
                for: state, visualState: presentation.visualState),
            canvasGeometry: canvas.canvasGeometry)
    }

    static func fitPill(_ panel: FloatingPillPanel, layout: VoiceBarPanelLayout, in screen: CGRect) {
        panel.contentView?.setFrameSize(layout.panelSize)
        panel.setFrame(VoiceBarIsolatedCapturePlacement.frame(layout: layout, visibleFrame: screen,
            environment: [VoiceBarIsolatedCapturePlacement.topRightEnvironmentVariable: "1"]), display: true)
    }

    func updatePillLayout() {
        guard !contextMenuTracking else {
            model.receipt("qa-menu-layout-deferred")
            return
        }
        guard let pill, let screen = NSScreen.main else { return }
        Self.fitPill(pill, layout: Self.panelLayout(for: model.voice), in: screen.visibleFrame)
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
                onRunSetup: { self.popoverPresenter?.close(); self.model.receipt("popover-setup"); self.openWizard() },
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
    var revision: UInt64 = 0
    var hidden = false { didSet { onVisibilityChange?(hidden) } }
    var onVisibilityChange: ((Bool) -> Void)?
    var tab: SettingsTab = .general
    var requestID = 0
    var events: [String] = []
    var commands: [[String: Any]] = []
    var selectionText = "QA original selection"
    private var holdsFixturePresentation = false
    var onRunSetup: () -> Void = {}
    var residency = "loaded"
    var processing: [String: Any] = [:]
    var speech: [String: Any] = [:]
    var microphoneOrder = ["a", "b"]
    var recent: RecentTranscriptionEntry { .init(text: Self.transcript, createdAt: Date(timeIntervalSince1970: 1_790_000_000)) }

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
        let older = SettingsHistoryEntry(id: "qa-older", dayKey: entry.dayKey, recordingID: "qa-older",
            createdAt: entry.createdAt.addingTimeInterval(-120), transcript: "QA older transcript",
            audioPath: sandbox.root.appendingPathComponent("older.wav"))
        return .init(groups: [.init(dayKey: entry.dayKey, date: entry.createdAt, entries: [entry, older])], hasMore: true)
    }
    var askHistory: SettingsAskHistoryPage {
        let entry = SettingsAskHistoryEntry(id: "qa-ask", dayKey: "2026-10-15", askID: "qa-ask", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            questionText: "QA question", questionAudioPath: nil, responseTranscript: "QA response", responseAudioPath: nil)
        return .init(groups: [.init(dayKey: entry.dayKey, date: entry.createdAt, entries: [entry])], hasMore: true)
    }
    func historyPage(limit: Int) -> SettingsHistoryPage {
        receipt("history-page:" + String(limit))
        guard limit > 100, let group = history.groups.first else { return history }
        let entry = SettingsHistoryEntry(id: "qa-loaded", dayKey: group.dayKey, recordingID: "qa-loaded",
            createdAt: group.date.addingTimeInterval(-240), transcript: "QA loaded transcript",
            audioPath: sandbox.root.appendingPathComponent("loaded.wav"))
        return .init(groups: [.init(dayKey: group.dayKey, date: group.date, entries: group.entries + [entry])], hasMore: false)
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
        switch cmd {
        case "health": refresh(); return
        case "speak_text":
            // Real VoiceState selection routing ends here, never at a daemon or AX capture.
            voice.handleEvent(["type": "state", "state": "speaking", "duration_ms": 600_000,
                "text": message["text"] as? String ?? "",
                "long_read": ["id": message["id"] as? String ?? "qa-selection",
                              "chunk_start_ms": 0]])
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
    func fixture(_ name: String) {
        if holdsFixturePresentation { voice.endModalInteraction(); holdsFixturePresentation = false }
        voice.confirmationText = nil
        if ["confirmation", "paste-failed", "paste-not-inserted", "paste-unverified", "paste-partial", "paste-typed"].contains(name) {
            // These are held visual fixtures, not a claim about note lifetime.
            // A real pointer exit must not collapse the fixture before its frame is measured.
            voice.beginModalInteraction()
            holdsFixturePresentation = true
        }
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
                "text": "First QA item\nSecond QA item", "readback_id": "qa-readback"])
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
        case "disconnected": voice.setConnectionStatus(false)
        default: refresh(); voice.mode = .idle
        }
        receipt("fixture:" + name)
    }
}

private struct UIE2ESettings: View {
    let model: UIE2EModel
    var body: some View {
        let history = model.history, asks = model.askHistory
        SettingsView(hotkeyEnabled: false, missingPermissions: [.accessibility, .inputMonitoring],
            availableDevices: { [] }, selectedDeviceID: { nil }, prioritySnapshot: { model.microphone },
            onReorderPriority: { model.microphoneOrder = $0; model.receipt("microphone-order") },
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
                                            errorMessage: nil, remoteSTTConfigured: false) }, onRunSetup: { model.receipt("run-setup"); model.onRunSetup() },
            tabRequest: .init(tab: model.tab, id: model.requestID), initialDictionaryPreview: model.preview,
            onSelectedTabChange: { model.tab = $0 },
            historyPlayback: .init(start: { _ in fatalError("UIE2E forbids playback") }, stop: {}))
    }
}
#endif
