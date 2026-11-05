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
        XCTAssertEqual(empty.items.prefix(3).map(\.isEnabled), [false, false, false])
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
        XCTAssertFalse(built.items[7].isEnabled); XCTAssertNil(built.items[7].action)
        XCTAssertEqual(built.items[4].keyEquivalent, ","); XCTAssertEqual(built.items[8].keyEquivalent, "q")
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
            bridge.historyDidChange(isOpen: true); handoff.requestMenu(first)
            XCTAssertEqual(bridge.closeRequest, 1)
            XCTAssertTrue(queued.isEmpty); XCTAssertNil(bridge.presentedMenu)
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
            XCTAssertNil(bridge.presentedMenu); XCTAssertEqual(model.presentation.visualState, .teleprompter)
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

    private func button(_ view: NSView) -> BareNotchMenuButton? {
        (view as? BareNotchMenuButton) ?? view.subviews.compactMap(button).first
    }
    func testRealBarViewClickSlopAndHistoryEligibility() throws {
        let cases: [(VoiceMode, Bool, Bool, CGFloat, Bool)] = [
            (.idle, true, false, 0, false), (.idle, true, false, 80, false),
            (.idle, false, true, 80, false), (.recording, true, true, 80, false),
            (.transcribing, true, true, 80, false), (.idle, true, true, 80, true),
        ]
        for (mode, hovered, hasEntries, distance, historyAllowed) in cases {
            let state = VoiceState()
            state.isConnected = true; state.isCollapsed = !hovered; state.isHovering = hovered; state.mode = mode
            state.recentTranscriptionEntries = hasEntries
                ? [RecentTranscriptionEntry(text: "Synthetic", recordingPath: "/synthetic/a.wav", createdAt: Date())] : []
            let bridge = VoiceBarNotchHistoryBridge(); var requested = 0; var mounted = false
            let host = PillHostingView(rootView: BarView(state: state, commandRouter: Router(),
                onOpenSettings: {}, onOpenHistory: {}, includesPanelOutsets: true, historyBridge: bridge, onOpenNotchMenu: { requested += 1 }))
            let presentation = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
                mode: mode, isHovered: hovered, isCollapsed: !hovered))
            let layout = VoiceBarPanelLayout.make(presentation: presentation,
                canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry)
            host.frame = NSRect(origin: .zero, size: layout.panelSize)
            let panel = FloatingPillPanel(content: host)
            panel.isPillDragEnabled = false
            defer { panel.orderOut(nil); panel.close() }
            VLOrderTestWindow(panel)
            host.layoutSubtreeIfNeeded(); XCTAssertFalse(NSApp.isActive)
            let control = try XCTUnwrap(button(host))
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                let location = NSPoint(x: point.x, y: point.y - (type == .leftMouseDown ? 0 : distance))
                panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
                RunLoop.main.run(until: Date().addingTimeInterval(0.02)); mounted = mounted || bridge.isHistoryOpen
            }
            XCTAssertEqual(requested, distance == 0 ? 1 : 0, "\(mode)/\(hovered)/\(hasEntries): a long busy drag cannot become a menu click")
            XCTAssertEqual(mounted, historyAllowed, "\(mode)/\(hovered)/\(hasEntries): History requires a nonempty launcher")
            if !historyAllowed {
                XCTAssertTrue(panel.makeFirstResponder(control))
                panel.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "",
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)))
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                XCTAssertFalse(bridge.isHistoryOpen, "\(mode)/\(hovered)/\(hasEntries): Down must obey the same History eligibility")
            }
            XCTAssertFalse(NSApp.isActive)
        }
    }

    func testBareNotchAdaptersViaResponderChainAndExpandedAccessibility() throws {
        var actions: [String] = []
        let host = NSHostingView(rootView: BareNotchMenuControl(isExpanded: true,
            onMenu: { actions.append("menu") }, onHistory: { actions.append("history") }, onClose: { actions.append("close") }))
        host.frame = NSRect(x: 0, y: 0, width: 168, height: 32); let panel = FloatingPillPanel(content: host)
        defer { panel.orderOut(nil); panel.close() }
        VLOrderTestWindow(panel)
        host.layoutSubtreeIfNeeded()
        let control = try XCTUnwrap(button(host))
        XCTAssertEqual(control.accessibilityRole(), .menuButton)
        XCTAssertEqual(control.accessibilityLabel(), "VoiceBar menu")
        XCTAssertTrue(panel.makeFirstResponder(control), "fixture focus only; production focus reachability is unproven")
        XCTAssertTrue(control.accessibilityPerformPress())
        for code: UInt16 in [36, 76, 125, 53] {
            panel.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
        }
        XCTAssertEqual(actions, ["menu", "menu", "menu", "history", "close"])
        XCTAssertTrue(control.isAccessibilityExpanded())
        host.rootView.isExpanded = false
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(control.isAccessibilityExpanded())
    }

}
