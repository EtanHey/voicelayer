import AppKit
import SwiftUI
import OffscreenTestSupport
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchMenuU1Tests: XCTestCase {
    func testMenuListAndAdapters() {
        let menu = PillContextMenuController()
        menu.versionProvider = { "2.3.0" }
        menu.updateStatusProvider = { VoiceBarVersionStatus.latest.menuMessage }
        let empty = menu.makeNotchMenu()
        XCTAssertFalse(empty.items[0].isEnabled)
        XCTAssertFalse(empty.items[1].isEnabled)
        XCTAssertFalse(empty.items[2].isEnabled)
        menu.transcriptProvider = { "Synthetic transcript" }
        menu.canRetranscribeLatestProvider = { true }
        var actions: [String] = []
        menu.onCopyLastTranscript = { actions.append("copy") }
        menu.onPasteLastTranscript = { actions.append("paste") }
        menu.onRetranscribeLatest = { actions.append("again") }
        menu.onOpenSettings = { actions.append("settings") }
        menu.onSnooze = { actions.append("hide") }
        menu.onQuit = { actions.append("quit") }
        let built = menu.makeNotchMenu()
        XCTAssertEqual(built.items.map(\.title), ["Copy last transcript", "Paste last transcript", "Transcribe latest again", "",
            "Settings…", "Hide for 1 hour", "", "VoiceBar 2.3.0 · up to date", "Quit VoiceBar"])
        XCTAssertFalse(built.items[7].isEnabled)
        XCTAssertNil(built.items[7].action)
        XCTAssertEqual(built.items[4].keyEquivalent, ",")
        XCTAssertEqual(built.items[8].keyEquivalent, "q")
        for index in [0, 1, 2, 4, 5, 8] { built.performActionForItem(at: index) }
        XCTAssertEqual(actions, ["copy", "paste", "again", "settings", "hide", "quit"])
    }
    func testHistoryCloseAcknowledgementQueuedCancelAndMenuExclusion() {
        for first in [VoiceBarNotchMenuKind.notch, .microphone] {
            let second: VoiceBarNotchMenuKind = first == .notch ? .microphone : .notch
            let bridge = VoiceBarNotchHistoryBridge()
            var queued: [() -> Void] = [], shown: [VoiceBarNotchMenuKind] = []
            let handoff = VoiceBarNotchSurfaceHandoff(bridge: bridge) { shown.append($0) }
            handoff.schedule = { queued.append($0) }
            bridge.historyDidChange(isOpen: true)
            handoff.requestMenu(first)
            XCTAssertEqual(bridge.closeRequest, 1)
            XCTAssertTrue(queued.isEmpty)
            XCTAssertNil(bridge.presentedMenu)
            bridge.historyDidChange(isOpen: false)
            handoff.requestMenu(second)
            XCTAssertEqual(queued.count, 1, "a second kind cannot stack behind the queued kind")
            bridge.historyDidChange(isOpen: true)
            queued.removeFirst()()
            XCTAssertTrue(shown.isEmpty, "History reopening cancels the queued menu")
            bridge.historyDidChange(isOpen: false)
            handoff.requestMenu(first)
            handoff.cancelQueuedMenu()
            queued.removeFirst()()
            XCTAssertTrue(shown.isEmpty, "Escape cancels the queued menu")
            handoff.requestMenu(second)
            queued.removeFirst()()
            XCTAssertEqual(shown, [second])
        }
    }
    func testReadingIsCoveredDuringTrackingAndRestoredFromTheCurrentEnvelope() {
        for kind in [VoiceBarNotchMenuKind.notch, .microphone] {
            let model = VoiceBarNotchPresentationModel()
            model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false)
            let bridge = VoiceBarNotchHistoryBridge()
            var handoff: VoiceBarNotchSurfaceHandoff!
            handoff = VoiceBarNotchSurfaceHandoff(bridge: bridge, presentationModel: model) { shown in
                XCTAssertEqual(bridge.presentedMenu, kind)
                XCTAssertEqual(shown, kind)
                XCTAssertNotEqual(model.presentation.visualState, .teleprompter)
                handoff.requestMenu(kind == .notch ? .microphone : .notch)
                XCTAssertNil(handoff.coordinator.queuedMenu)
            }
            handoff.schedule = { $0() }
            XCTAssertEqual(model.presentation.visualState, .teleprompter)
            handoff.requestMenu(kind)
            XCTAssertNil(bridge.presentedMenu)
            XCTAssertEqual(model.presentation.visualState, .teleprompter)
            model.setHistoryPanelOpen(true)
            XCTAssertEqual(model.presentation.visualState, .history)
            model.setHistoryPanelOpen(false)
            XCTAssertEqual(model.presentation.visualState, .teleprompter)
            let ending = VoiceBarNotchSurfaceHandoff(bridge: bridge, presentationModel: model) { _ in
                model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: false, hasCompactStatus: false)
            }
            ending.schedule = { $0() }
            ending.requestMenu(kind)
            XCTAssertNotEqual(model.presentation.visualState, .teleprompter, "an ended read cannot be resurrected")
        }
    }

    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    func testRealBarViewBareNotchClickReachesTheMenuWithEmptyHistory() throws {
        let state = VoiceState()
        state.isConnected = true; state.isCollapsed = false; state.isHovering = true
        state.recentTranscriptionEntries = []
        var requested = 0
        let view = BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                           onOpenNotchMenu: { requested += 1 })
        let presentation = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: .idle, isHovered: true, isCollapsed: false))
        let geometry = presentation.geometry
        let host = PillHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: geometry.totalWidth, height: geometry.totalHeight)
        let panel = FloatingPillPanel(content: host)
        panel.isPillDragEnabled = false
        defer { panel.orderOut(nil); panel.close() }
        VLOrderTestWindow(panel)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(NSApp.isActive)
        let point = NSPoint(x: geometry.coreOriginX + geometry.coreWidth / 2, y: geometry.totalHeight - geometry.topHeight / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(requested, 1)
        XCTAssertFalse(NSApp.isActive, "a bare-notch click must not activate VoiceBar")
    }

    func testHostedBareNotchExposesTheExpandedAccessibilityAttribute() throws {
        let host = NSHostingView(rootView: BareNotchMenuControl(isExpanded: true, onMenu: {}, onHistory: {}, onClose: {}))
        host.frame = NSRect(x: 0, y: 0, width: 168, height: 32)
        let panel = FloatingPillPanel(content: host)
        defer { panel.orderOut(nil); panel.close() }
        VLOrderTestWindow(panel)
        host.layoutSubtreeIfNeeded()
        func button(_ view: NSView) -> BareNotchMenuButton? {
            if let found = view as? BareNotchMenuButton { return found }
            return view.subviews.compactMap(button).first
        }
        let control = try XCTUnwrap(button(host))
        XCTAssertEqual(control.accessibilityRole(), .button)
        XCTAssertEqual(control.accessibilityLabel(), "VoiceBar menu")
        XCTAssertTrue(control.canBecomeKeyView, "native keyboard focus stays reachable without SwiftUI click activation")
        XCTAssertTrue(control.isAccessibilityExpanded())
        host.rootView.isExpanded = false
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(control.isAccessibilityExpanded())
    }

    func testBareNotchAccessibilityAndKeysUseTheSameActions() throws {
        let button = BareNotchMenuButton()
        var actions: [String] = []
        button.onMenu = { actions.append("menu") }
        button.onHistory = { actions.append("history") }
        button.onClose = { actions.append("close") }
        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertFalse(button.needsPanelToBecomeKey)
        XCTAssertTrue(button.accessibilityPerformPress())
        for code: UInt16 in [36, 76, 125, 53] {
            button.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
        }
        XCTAssertEqual(actions, ["menu", "menu", "menu", "history", "close"])
        XCTAssertNil(button.hitTest(.zero), "pointer events belong to the shared click/pull gesture")
    }
}
