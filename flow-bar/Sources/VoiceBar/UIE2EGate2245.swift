#if VOICEBAR_QA && VOICEBAR_UIE2E_GATE2245
import AppKit
import SwiftUI
import VoiceBarUI

/// Product AppDelegate ordering and snooze callbacks, without application launch/services.
/// Its state, panels, wizard dependencies and commands belong only to the marked QA sandbox.
@MainActor
final class UIE2EGate2245 {
    let app = AppDelegate()
    let panel: FloatingPillPanel
    unowned let host: UIE2EHost
    var beforeShow: [String: Any] = [:]
    var placementObservers: [NSObjectProtocol] = []

    init(host: UIE2EHost) {
        self.host = host
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
        if ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] == "hide1" {
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
        guard ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_SCENARIO"] == "hide1",
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
        host.sandbox.writeObject(["action": action, "state": current(), "beforeShow": beforeShow,
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

extension UIE2EHost {
    func installHide1VisualMenu() {
        model.hidden = true
        pill.orderOut(nil)
        settings.orderOut(nil)
        statusItem?.isVisible = false
        let item = NSMenuItem(); let menu = NSMenu(title: "HIDE1VIS")
        item.title = "HIDE1VIS"; item.submenu = menu
        for (index, name) in ["start", "speaking", "preparing", "readback", "error", "reconnect", "notes", "wizard", "show", "end"].enumerated() {
            let command = NSMenuItem(title: "HIDE1VIS " + name, action: #selector(hide1VisualCommand(_:)), keyEquivalent: String(index))
            command.target = self; command.representedObject = name
            menu.addItem(command)
        }
        NSApp.mainMenu?.addItem(item)
    }

    @objc func hide1VisualCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
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
#endif
