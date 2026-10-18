#if VOICEBAR_QA && VOICEBAR_UIE2E_GATE2245
import AppKit
import SwiftUI
import VoiceBarUI

/// Product AppDelegate ordering and snooze callbacks, without application launch/services.
/// Its state, panels, wizard dependencies and commands belong only to the marked QA sandbox.
@MainActor
final class UIE2EGate2245 {
    // Checked before the real AppDelegate exists, whichever path constructs this fixture.
    let app: AppDelegate = {
        UIE2ENoDeviceGuard.requireInstalled()
        return AppDelegate()
    }()
    let panel: FloatingPillPanel
    unowned let host: UIE2EHost
    var beforeShow: [String: Any] = [:]
#if VOICEBAR_UIE2E_GATE2246_CAPTURE
    var captureServer: SocketServer?
    var captureController: VoiceBarDaemonController?
#endif
    var gateCommands: [[String: Any]] = []
    var placementObservers: [NSObjectProtocol] = []
    let noDeviceEngine = UIE2ENoDeviceLevelEngine()

    init(host: UIE2EHost) {
        self.host = host
        // Replace the lazy default BEFORE the real AppDelegate mode observer is installed.
        app.configureAudioLevelMonitoringForTesting(engine: noDeviceEngine)
        let state = app.voiceState
        state.controlLayerEventWriter = { _, _ in }
        state.sendCommand = { _ in }
        state.selectionTextCaptureHandler = { $0(.completed(nil)) }
        state.setConnectionStatus(true)
        state.isHovering = true
        panel = FloatingPillPanel(content: PillHostingView(rootView: BarView(state: state,
            commandRouter: app.commandRouter, onOpenSettings: {}, onOpenHistory: {}, includesPanelOutsets: true)))
        panel.title = "VoiceBar GATE2245 Product Pill"
        app.configurePanelVisibilityForTesting(panel)
        app.configureSetupWizardPresentationForTesting { [weak host] in host?.openWizard() }
        if let screen = NSScreen.main {
            UIE2EHost.fitPill(panel, layout: UIE2EHost.panelLayout(for: state), in: screen.visibleFrame)
        }
        if ["hide1", "gate2246"].contains(ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] ?? "") {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                placementObservers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.fitVisualPanel() }
                })
            }
        }
        panel.orderFront(nil)
        fitVisualPanel()
        snapshot("start")
    }

    func fitVisualPanel() {
        guard ["hide1", "gate2246"].contains(ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] ?? ""),
              let screen = NSScreen.main else { return }
        let layout = UIE2EHost.panelLayout(for: app.voiceState)
        panel.contentView?.setFrameSize(layout.panelSize)
        // Isolated capture placement below the menu bar, away from top-right OS banners.
        let frame = NSRect(x: screen.frame.midX - layout.panelSize.width / 2,
            y: screen.frame.maxY - 140 - layout.panelSize.height,
            width: layout.panelSize.width, height: layout.panelSize.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func current() -> [String: Any] {
        let state = app.voiceState
        return ["mode": state.mode.rawValue, "status": state.statusText,
                "readback": state.isTeleprompterReadback]
    }

    func snapshot(_ action: String) {
        let command = UIE2EFixtureCommandListener.delivered
        host.sandbox.writeObject(["pid": ProcessInfo.processInfo.processIdentifier, "action": action,
            "fixtureCommand": ["count": command.count, "name": command.name], "noDeviceEngineStarts": noDeviceEngine.starts, "commands": gateCommands, "statusText": app.voiceState.statusText, "state": current(), "beforeShow": beforeShow,
            "snoozed": app.isSnoozed, "hidden": app.voiceState.isHidden, "connected": app.voiceState.isConnected,
            "panelVisible": panel.isVisible, "windowNumber": panel.windowNumber,
            "visiblePanels": NSApp.windows.filter { $0 is NSPanel && $0.isVisible }.map(\.title),
            "wizardVisible": host.wizard?.isVisible ?? false,
            "screenWindows": (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).map { window in
                ["owner": window[kCGWindowOwnerName as String] ?? "", "pid": window[kCGWindowOwnerPID as String] ?? 0,
                 "number": window[kCGWindowNumber as String] ?? 0, "bounds": window[kCGWindowBounds as String] ?? [:]]
            },
            "settingsVisible": host.settings.isVisible,
            "panelFrame": NSStringFromRect(panel.frame),
            "ownedVisibleWindows": NSApp.windows.filter { $0.isVisible && !$0.frame.isEmpty }.map { ["title": $0.title, "number": $0.windowNumber, "frame": NSStringFromRect($0.frame)] as [String: Any] }], file: "gate-hide.json")
    }

    func hideAndDeliver(_ event: String) {
        app.quickMenuActions().first { $0.title == "Hide for 1 hour" }!.perform()
        let state = app.voiceState
        switch event {
        case "speaking": state.handleEvent(["type": "state", "state": "speaking", "text": "Hidden current speech", "duration_ms": 600_000])
        case "preparing": state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
            "long_read": ["preparing": true, "chunk_start_ms": 0]])
        case "readback":
            state.handleEvent(["type": "state", "state": "speaking", "text": "Hidden retained words"])
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        case "error": state.handleEvent(["type": "error", "message": "Hidden synthetic error"])
        case "reconnect": state.setConnectionStatus(false); state.setConnectionStatus(true)
        case "notes": state.mode = .transcribing; state.speakSelection()
        case "wizard": app.completeFirstRunSetupDetection { true }
        default: fatalError("Unknown gate event")
        }
        beforeShow = current()
        // Include deferred layout work in the native visibility readback.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.fitVisualPanel()
            self?.snapshot("hidden:" + event)
        }
    }

    func show() { beforeShow = current(); app.commandRouter.handleShowVoiceBar(); fitVisualPanel(); snapshot("show") }
    func close() {
        for observer in placementObservers { NotificationCenter.default.removeObserver(observer) }
        placementObservers.removeAll()
        app.unsnoozeNow(); panel.orderOut(nil); host.wizard?.close()
    }
}

// BEGIN UIE2E FIXTURE COMMANDS
/// Fixture commands arrive as distributed notifications named for this sandbox, never as
/// keystrokes: a key equivalent can be consumed by a global macOS shortcut (run-03's ⌥⌘D was
/// symbolic hotkey 52 and toggled the operator's Dock). The sandboxed XCTest runner can post a
/// name-only notification but cannot write files; the QA app acknowledges with a file it owns.
enum UIE2EFixtureCommand {
    static let prefix = "com.voicelayer.voicebar.uie2e.command."
    static let ackFile = "fixture-command-ack.json"
    static func notificationName(token: String, command: String) -> String { prefix + token + "." + command }
    /// The command a notification name carries for this sandbox token, or nil for any other name.
    static func command(from name: String, token: String, allowed: [String]) -> String? {
        let expected = prefix + token + "."
        guard name.hasPrefix(expected) else { return nil }
        let command = String(name.dropFirst(expected.count))
        return allowed.contains(command) ? command : nil
    }
}
// END UIE2E FIXTURE COMMANDS

@MainActor
final class UIE2EFixtureCommandListener {
    static var active: UIE2EFixtureCommandListener?
    static var delivered: (count: Int, name: String) = (0, "")
    var observers: [NSObjectProtocol] = []

    init(host: UIE2EHost, names: [String]) {
        let token = host.sandbox.root.lastPathComponent
        let center = DistributedNotificationCenter.default()
        for name in names {
            let full = UIE2EFixtureCommand.notificationName(token: token, command: name)
            observers.append(center.addObserver(forName: Notification.Name(full), object: nil, queue: .main) { [weak host] note in
                let raw = note.name.rawValue
                MainActor.assumeIsolated {
                    // Like a menu key equivalent, a command never runs under a modal (the product NSAlert);
                    // it stays unacknowledged, so the runner reports "not delivered", never a fake verdict.
                    guard let host, NSApp.modalWindow == nil,
                          let command = UIE2EFixtureCommand.command(from: raw, token: token, allowed: names) else { return }
                    UIE2EFixtureCommandListener.delivered = (UIE2EFixtureCommandListener.delivered.count + 1, command)
                    // Acknowledge before running: a capture-failure command can enter the NSAlert modal loop.
                    // Receipts the command writes carry the same count in "fixtureCommand".
                    host.sandbox.writeObject(["count": UIE2EFixtureCommandListener.delivered.count, "name": command],
                                             file: UIE2EFixtureCommand.ackFile)
                    host.hide1VisualCommand(command)
                }
            })
        }
    }
}

extension UIE2EHost {
    func installHide1VisualMenu() {
        model.hidden = true
        pill.orderOut(nil)
        settings.orderOut(nil)
        statusItem?.isVisible = false
        let names = ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] == "gate2246"
            ? ["start", "user-f5", "user-ask", "unknown", "background", "recovered", "visible", "show", "selection", "end", "same-hash", "different", "pending", "fast-bc", "no-hash", "busy"]
            : ["start", "speaking", "preparing", "readback", "error", "reconnect", "notes", "wizard", "show", "end"]
        UIE2EFixtureCommandListener.active = UIE2EFixtureCommandListener(host: self, names: names)
        // The HIDE1VIS menu is the runner's readiness marker, installed after the listener. Its items
        // carry NO key equivalents: commands are notification-only (see UIE2EFixtureCommand).
        let item = NSMenuItem(); let menu = NSMenu(title: "HIDE1VIS")
        item.title = "HIDE1VIS"; item.submenu = menu
        for name in names {
            let command = NSMenuItem(title: "HIDE1VIS " + name, action: #selector(hide1VisualMenuItem(_:)), keyEquivalent: "")
            command.target = self; command.representedObject = name
            menu.addItem(command)
        }
        NSApp.mainMenu?.addItem(item)
    }

    @objc func hide1VisualMenuItem(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { hide1VisualCommand(name) }
    }

    func hide1VisualCommand(_ name: String) {
        if ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] == "gate2246" {
            gate2246Command(name); return
        }
        if name == "start" {
            gateHide("start")
        } else if name == "show" { gate2245?.show() }
        else if name == "end" { gateHide("end") }
        else { gate2245?.hideAndDeliver(name) }
    }

    var gate2245Controls: some View {
        VStack(spacing: 2) {
            HStack {
                ForEach(["start", "speaking", "preparing", "readback", "error", "reconnect", "notes", "wizard", "show", "end"], id: \.self) { name in
                    Button(name) { self.gateHide(name) }.accessibilityIdentifier("qa-fixture-gate-hide-" + name)
                }
            }
            HStack {
                ForEach(["same", "empty", "failed", "busy", "partial", "untimed", "edge"], id: \.self) { name in
                    Button(name) { self.model.gateFixture(name) }.accessibilityIdentifier("qa-fixture-gate-state-" + name)
                }
            }
        }.font(.caption)
    }

    func gateHide(_ name: String) {
        if name == "end" {
            gate2245?.close(); gate2245 = nil; model.hidden = false; return
        }
        if name == "show" { gate2245?.show(); return }
        gate2245?.close()
        model.hidden = true
        gate2245 = UIE2EGate2245(host: self)
        if name != "start" { gate2245?.hideAndDeliver(name) }
    }
}

extension UIE2EModel {
    func gateFixture(_ name: String) {
        if ["same", "empty", "failed"].contains(name) {
            fixture("preparing")
            let result: SelectionCaptureResult = name == "failed" ? .captureFailed
                : .completed(name == "same" ? "QA original selection" : "")
            voice.selectionTextCaptureHandler = { $0(result) }
            let start = commands.count
            voice.speakSelection()
            sandbox.writeObject(["case": name, "commands": Array(commands.dropFirst(start))], file: "gate-selection.json")
            voice.selectionTextCaptureHandler = { [weak self] in $0(.completed(self?.selectionText ?? "")) }
        } else if name == "busy" {
            fixture("idle"); voice.mode = .transcribing; voice.speakSelection()
        } else {
            fixture("idle")
            voice.isHovering = true
            voice.handleEvent(["type": "state", "state": "speaking", "text": "Alpha Bravo Charlie Delta", "duration_ms": 600_000])
            if name == "edge" {
                voice.handleEvent(["type": "subtitle", "words": ["Alpha", "Bravo", "Charlie", "Delta"].enumerated().map {
                    ["text": $0.element, "offset_ms": $0.offset * 1000, "duration_ms": 900] as [String: Any]
                }])
            } else {
                let rows: [[String: Any]] = ["Alpha", "Bravo", "Charlie", "Delta"].enumerated().map { index, word in
                    let timed = name == "partial" && index % 2 == 0
                    let offset: Any = timed ? index * 1000 : NSNull()
                    let duration: Any = timed ? 900 : NSNull()
                    return ["text": word, "word_index": index, "offset_ms": offset, "duration_ms": duration]
                }
                voice.handleEvent(["type": "subtitle", "aligned_words": rows])
            }
        }
        receipt("gate:" + name)
    }
}

extension UIE2EHost {
    func gate2246Command(_ name: String) {
        if name == "end" { gateHide("end"); return }
        if name == "show" { gate2245?.show(); return }
        if ["start", "selection", "user-f5", "user-ask", "unknown", "background", "recovered", "visible"].contains(name) { gateHide("start") }
        guard let gate = gate2245 else { return }
        if ["start", "selection"].contains(name) { return }
        if ["user-f5", "user-ask", "unknown", "background", "recovered", "visible"].contains(name) {
#if VOICEBAR_UIE2E_GATE2246_CAPTURE
            gate.captureFailure(name)
#else
            fatalError("gate2246 capture cases require a VOICEBAR_UIE2E_GATE2246_CAPTURE build")
#endif
        } else { gate.selectionCase(name) }
    }
}

extension UIE2EGate2245 {
#if VOICEBAR_UIE2E_GATE2246_CAPTURE
    // Uses #410's capture-failure APIs; hide1 builds without this flag do not depend on #410.
    func captureFailure(_ name: String) {
        // Parser-only server; real observer uses the device-free injected level engine.
        let server = SocketServer(state: app.voiceState, socketPath: host.sandbox.root.appendingPathComponent("unused.sock").path)
        let controller = VoiceBarDaemonController(restartScheduler: { _, _ in }, microphonePromptDisabled: { false })
        captureServer = server; captureController = controller
        app.configureCaptureFailurePresentation(server, controller: controller)
        if name != "visible" { app.quickMenuActions().first { $0.title == "Hide for 1 hour" }!.perform() }
        let failure = #"{"type":"error","capture_failure":"broken-mic","show_during_bar_recording":true}"#
        if ["background", "recovered"].contains(name) {
            controller.handleCaptureFailure(type: "broken-mic", userInitiated: false)
            controller.handleCaptureFailure(type: "broken-mic", userInitiated: false)
        } else {
            for _ in 0..<2 {
                if name == "user-f5" { server.parseLine(#"{"type":"state","state":"recording","bar_owned":true}"#) }
                if name == "user-ask" { server.parseLine(#"{"type":"state","state":"recording","bar_owned":false}"#) }
                server.parseLine(failure)
            }
        }
        if name == "recovered" {
            server.parseLine(#"{"type":"state","state":"recording","bar_owned":false}"#)
            server.parseLine(#"{"type":"state","state":"transcribing"}"#)
            server.parseLine(#"{"type":"transcription","text":"Synthetic recovery","recording_is_latest":false}"#)
            server.parseLine(#"{"type":"state","state":"idle","source":"recording"}"#)
        }
        // NSAlert runs a modal loop. Its visible state is observed out of process by XCUI;
        // a delayed MainActor snapshot can remain queued behind the alert until dismissal.
    }
#endif

    func selectionCase(_ name: String) {
        let state = app.voiceState
        gateCommands.removeAll()
        state.sendCommand = { [weak self] in self?.gateCommands.append($0) }
        // Clear only this QA model's preceding read and preserve the silent command sink.
        state.stop(); gateCommands.removeAll()
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        let hash = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        func read(_ id: String, _ text: String, _ preparing: Bool, request: String = "external-X", hash: String? = nil) {
            var event: [String: Any] = ["type": "state", "state": "speaking", "text": text, "duration_ms": 600_000,
                "request_id": request, "long_read": ["id": id, "preparing": preparing]]
            if let hash { event["text_hash"] = hash }
            state.handleEvent(event)
        }
        func select(_ text: String) {
            state.selectionTextCaptureHandler = { $0(.completed(text)) }; state.speakSelection()
        }
        switch name {
        case "same-hash", "different", "no-hash":
            read("external-X", "Preparing speech…", true, hash: name == "no-hash" ? nil : hash)
            select(name == "same-hash" ? "hello world" : "Replacement selection B")
            if name != "same-hash", let request = gateCommands.last?["id"] as? String {
                read("own-B", "Replacement selection B", false, request: request)
            }
        case "pending":
            read("external-A", "Playing selection A", false)
            select("Own selection B")
            let request = gateCommands.last?["id"] as? String ?? "MISSING"
            read("external-X", "Preparing external X…", true)
            read("external-X", "External selection X", false)
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            read("own-B", "Own selection B", false, request: request)
        case "fast-bc":
            read("external-A", "Playing selection A", false)
            select("Own selection B"); select("Own selection C")
            guard gateCommands.count == 2 else { snapshot("selection:" + name); return }
            let b = gateCommands[0]["id"] as? String ?? "MISSING"
            let c = gateCommands[1]["id"] as? String ?? "MISSING"
            read("own-C", "Own selection C", false, request: c)
            read("own-B", "Stale selection B", false, request: b)
        case "busy": state.mode = .transcribing; state.speakSelection()
        default: fatalError("Unknown gate2246 selection")
        }
        state.isHovering = true
        fitVisualPanel(); snapshot("selection:" + name)
    }
}
#endif
