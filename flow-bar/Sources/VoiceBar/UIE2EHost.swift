#if VOICEBAR_QA
import AppKit
import SwiftUI
import VoiceBarUI

/// The real Settings/BarView/menu with fixture dependencies. This entry point intentionally
/// precedes AppDelegate construction: no daemon, global hotkeys, audio engine or live sockets.
@MainActor
final class UIE2EHost: NSObject, NSApplicationDelegate {
    let sandbox: UIE2ESandbox
    let model: UIE2EModel
    var settings: NSWindow!
    var pill: FloatingPillPanel!
    let menu = PillContextMenuController()
    var statusItem: NSStatusItem?
    var statusController: MenuBarStatusItemController?
    var popoverPresenter: MenuBarPopoverPresenter?

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
            if Bundle.main.object(forInfoDictionaryKey: "UIE2EPasteFeedback") as? Bool == true {
                HStack {
                    ForEach(["paste-not-inserted", "paste-unverified", "paste-partial"], id: \.self) { name in
                        Button(name) { self.model.fixture(name) }.accessibilityIdentifier("qa-fixture-\(name)")
                    }
                }.padding(6)
            }
            UIE2ESettings(model: model)
        })
        let bar = NSHostingView(rootView: BarView(state: model.voice, commandRouter: VoiceBarCommandRouter(voiceState: model.voice),
            onOpenSettings: { self.settings.makeKeyAndOrderFront(nil) },
            onOpenHistory: { self.model.tab = .history; self.model.requestID += 1 }))
        bar.frame = NSRect(x: 0, y: 0, width: 680, height: 180)
        pill = FloatingPillPanel(content: bar)
        pill.title = "VoiceBar QA Pill"
        pill.setFrame(NSRect(x: 100, y: 20, width: 680, height: 180), display: false)
        configureMenu()
        pill.contextMenuProvider = { self.menu.makeMenu() }
        pill.contextMenuHitTestProvider = { _ in true }
        pill.orderFront(nil)
        settings.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        configureStatusItem()
        model.receipt("launch")
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
                onRunSetup: { self.popoverPresenter?.close(); self.model.receipt("popover-setup") },
                onChangeMicrophone: { self.popoverPresenter?.close(); self.model.tab = .general; self.model.requestID += 1; self.model.receipt("popover-microphone") }))
        }
        popoverPresenter = presenter
        statusController = MenuBarStatusItemController(button: button, presenter: presenter)
        button.setAccessibilityTitle("VoiceBar QA")
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
    var hidden = false
    var tab: SettingsTab = .general
    var requestID = 0
    var events: [String] = []
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
        for (key, value) in [("model_polish", "off" as Any), ("outro_gate", true), ("smart_chunks", false), ("smart_boundaries", false)] {
            processing[key] = ["source": "settings", "raw": NSNull(), "effective": value]
        }
        // Existing test seams: even accidental paste/record intents cannot reach the host.
        voice.pasteHandler = { _ in true }
        voice.frontmostAppProvider = { nil }
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
        let cmd = message["cmd"] as? String ?? ""
        receipt("command:" + cmd)
        switch cmd {
        case "health": refresh(); return
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
        voice.confirmationText = nil
        switch name {
        case "confirmation": voice.mode = .idle; voice.confirmationText = "Pasted"
        case "paste-not-inserted": voice.mode = .idle; voice.confirmationText = "Not inserted — transcript kept in History. Click input and press Shift+F5, or Copy."
        case "paste-unverified": voice.mode = .idle; voice.confirmationText = "Insertion unverified — transcript kept in History. Check the input before retrying or Copy."
        case "paste-partial": voice.mode = .idle; voice.confirmationText = "Partially inserted — full transcript kept in History. Check the input before retrying or Copy."
        case "paste-failed": voice.mode = .idle; voice.confirmationText = "Paste failed — click input and press Shift+F5"
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
            historyPage: { limit in .init(groups: history.groups, hasMore: limit <= 100) }, initialHistoryPage: history, askHistoryPage: { limit in .init(groups: asks.groups, hasMore: limit <= 100) },
            historySearchPage: { _, query in history.groups[0].entries[0].transcript.localizedCaseInsensitiveContains(query) ? history : .init(groups: [], hasMore: false) },
            askHistorySearchPage: { _, query in "QA question QA response".localizedCaseInsensitiveContains(query) ? asks : .init(groups: [], hasMore: false) },
            searchPrewarm: {}, initialAskHistoryPage: asks, onCopyHistoryTranscript: { _ = model.copy($0) },
            onPasteHistoryTranscript: { model.pasteHistoryTranscript($0) }, onRetranscribeHistoryEntry: { _ in model.receipt("history-retranscribe") },
            onRevealHistoryFile: { _ in model.receipt("history-finder") },
            footerPresentation: { .resolve(isConnected: model.voice.isConnected, mode: model.voice.mode, captureLive: false,
                                            errorMessage: nil, remoteSTTConfigured: false) }, onRunSetup: { model.receipt("run-setup") },
            tabRequest: .init(tab: model.tab, id: model.requestID), initialDictionaryPreview: model.preview,
            onSelectedTabChange: { model.tab = $0 },
            historyPlayback: .init(start: { _ in fatalError("UIE2E forbids playback") }, stop: {}))
    }
}
#endif
