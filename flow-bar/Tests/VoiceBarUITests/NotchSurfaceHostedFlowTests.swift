import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.4 Lane A flows, end to end in the real BarView inside the real non-activating FloatingPillPanel, offscreen.
/// Events go to the panel with `sendEvent` (the same harness as NotchHistoryHandleDragHostTests); the pointer never
/// moves and nothing is ever key. Each test drives one user flow through the surface machine and checks both the
/// machine and what the notch reports to the app (the presentation model's History-panel state).
@MainActor
final class NotchSurfaceHostedFlowTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for window in windows {
                window.isReleasedWhenClosed = false
                window.orderOut(nil)
                window.close()
            }
            windows.removeAll()
        }
        super.tearDown()
    }

    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private struct Harness {
        let state: VoiceState
        let model: VoiceBarNotchPresentationModel
        let surface: NotchSurfaceModel
        let host: PillHostingView<BarView>
        let panel: FloatingPillPanel
        let rects: [CGRect]
        let paneRequests: PaneRequests
    }

    /// The requests the Settings drawer hands its panes (the microphone control's scroll target, 0510 N9 / F4).
    final class PaneRequests { var all: [SettingsTabRequest?] = [] }

    func testHideResetsMountedDrawerAndShowCanOpenSettingsAndSelectATab() throws {
        let harness = makeHarness()
        harness.surface.send(.openHistory)
        drain(0.5)
        XCTAssertTrue(harness.model.isHistoryPanelOpen)
        harness.state.snooze()
        harness.surface.hide()
        harness.panel.orderOut(nil)
        drain(0.1)
        XCTAssertNil(harness.surface.drawer)
        XCTAssertFalse(harness.model.isHistoryPanelOpen, "hidden drawer must unmount without waiting for a spring")
        harness.state.unsnooze()
        harness.panel.orderBack(nil)
        harness.surface.send(.openSettings(.general))
        drain(0.5)
        XCTAssertTrue(harness.model.isHistoryPanelOpen)
        harness.surface.send(.selectSettingsTab(.transcription))
        XCTAssertEqual(harness.surface.drawer, .settings(.transcription))
    }

    private func drain(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, to panel: NSWindow) throws {
        panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )))
    }

    private func click(_ point: NSPoint, in panel: NSWindow) throws {
        try send(.leftMouseDown, at: point, to: panel)
        try send(.leftMouseUp, at: point, to: panel)
    }

    /// A press, then a drag in `steps` to `dy` (window space: negative is down the screen), then release.
    private func drag(from start: NSPoint, dy: CGFloat, steps: Int = 12, in panel: NSWindow) throws {
        try send(.leftMouseDown, at: start, to: panel)
        drain()
        for step in 1 ... steps {
            try send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y + dy * CGFloat(step) / CGFloat(steps)), to: panel)
            drain(0.02)
        }
        try send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y + dy), to: panel)
        drain(0.8)
    }

    private func wait(_ condition: () -> Bool, seconds: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { drain() }
    }

    private func layout(_ model: VoiceBarNotchPresentationModel) -> VoiceBarPanelLayout {
        VoiceBarPanelLayout.make(
            presentation: model.presentation,
            interactionConfiguration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2),
            canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
        )
    }

    private func resize(_ harness: Harness) {
        let size = layout(harness.model).panelSize
        harness.panel.setContentSize(size)
        harness.host.frame = NSRect(origin: .zero, size: size)
        harness.host.layoutSubtreeIfNeeded()
    }

    private func makeHarness(entries: Int = 20) -> Harness {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: false
        )
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true
        state.recentTranscriptionEntries = (0 ..< entries).map { index in
            RecentTranscriptionEntry(text: "Synthetic history row \(index + 1).", recordingPath: "/synthetic/\(index).wav",
                                     createdAt: Date().addingTimeInterval(Double(-60 * index)))
        }
        let model = VoiceBarNotchPresentationModel()
        let surface = NotchSurfaceModel()
        surface.log = { _ in }
        let paneRequests = PaneRequests()
        let context = NotchSettingsDrawerContext(updates: nil, pane: { _, request in
            paneRequests.all.append(request)
            return AnyView(EmptyView())
        })
        let host = PillHostingView(rootView: BarView(
            state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
            presentationModel: model, includesPanelOutsets: true, surface: surface, settingsDrawer: context
        ))
        host.activeHitTestProvider = { _ in true }
        host.renderedSurfaceHitTestProvider = { _ in true }
        let panel = FloatingPillPanel(content: host)
        panel.isPillDragEnabled = false
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        windows.append(panel)
        model.setHovered(true)
        let launcher = layout(model)
        panel.setContentSize(launcher.panelSize)
        host.frame = NSRect(origin: .zero, size: launcher.panelSize)
        host.layoutSubtreeIfNeeded()
        drain(0.3)
        let rects = VoiceBarNotchHitRegion(
            geometry: launcher.presentation.geometry,
            configuration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2)
        ).rects.map { $0.offsetBy(dx: launcher.visibleContentRect.minX, dy: launcher.visibleContentRect.minY) }
        return Harness(state: state, model: model, surface: surface, host: host, panel: panel, rects: rects,
                       paneRequests: paneRequests)
    }

    private func center(_ rect: CGRect) -> NSPoint { NSPoint(x: rect.midX, y: rect.midY) }

    /// The control rects for the window as it is sized NOW (the window grows when a drawer opens, and window
    /// space is unflipped, so the band moves up in window coordinates).
    private func control(_ index: Int, _ harness: Harness) -> NSPoint {
        let current = layout(harness.model)
        let rects = VoiceBarNotchHitRegion(
            geometry: current.presentation.geometry,
            configuration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2)
        ).rects.map { $0.offsetBy(dx: current.visibleContentRect.minX, dy: current.visibleContentRect.minY) }
        return center(rects[index])
    }

    private func openHistory(_ harness: Harness) throws {
        try click(center(harness.rects[2]), in: harness.panel)
        wait { harness.model.isHistoryPanelOpen }
        resize(harness)
        drain(1.0) // the spring settles; body drags start only above 98 %
    }

    /// The point `fromTop` points below the top of the screen on the notch's centre line, in window space.
    private func notchPoint(_ harness: Harness, fromTop: CGFloat) -> NSPoint {
        let height = harness.panel.contentView?.bounds.height ?? harness.host.bounds.height
        let core = harness.rects[0].union(harness.rects[harness.rects.count - 1])
        return NSPoint(x: core.midX, y: height - 17 - fromTop)
    }

    func testTheHistoryControlOpensHistoryCollapsedAtSixRows() throws {
        let harness = makeHarness()
        try openHistory(harness)
        XCTAssertEqual(harness.surface.drawer, .history(.collapsed))
        XCTAssertEqual(harness.model.historyRows, 6)
        try click(control(2, harness), in: harness.panel)
        wait { harness.surface.drawer == nil }
        XCTAssertNil(harness.surface.drawer, "the History control toggles it closed")
        XCTAssertEqual(harness.surface.journal.last?.event, .dismiss(.toggle))
    }

    /// Dismissal wins over the release of a drag that began before it, including an armed Settings pull.
    func test0449OutsideDismissalCannotBeUndoneByAnInFlightDrawerRelease() throws {
        for dy: CGFloat in [-140, 80] {
            let h = makeHarness()
            try openHistory(h)
            let start = notchPoint(h, fromTop: 120)
            try send(.leftMouseDown, at: start, to: h.panel)
            drain()
            let end = NSPoint(x: start.x, y: start.y + dy)
            try send(.leftMouseDragged, at: end, to: h.panel)
            drain(0.05)
            let dismissal = NotchDrawerDismissal { h.surface.send(.dismiss($0)) }
            dismissal.handleGlobalMouseDown()
            // Release in the same turn, before SwiftUI can observe the dismissal.
            XCTAssertNil(h.surface.drawer)
            let count = h.surface.journal.count
            try send(.leftMouseUp, at: end, to: h.panel)
            drain(1)
            XCTAssertNil(h.surface.drawer, "[0449] a late release must not reopen after outside dismissal")
            XCTAssertFalse(h.model.isHistoryPanelOpen, "[0449] no drawn drawer remains after dismissal")
            XCTAssertFalse(h.surface.journal.dropFirst(count).contains { entry in
                if case .openHistory = entry.event { return true }
                if case .openSettings = entry.event { return true }
                return false
            }, "[0449] dismissal wins over an older pointer gesture")
        }
    }

    /// Etan: "drag UP closes it, mirroring drag-down to open". The press lands on the rows, not the band.
    func testDraggingTheOpenHistoryBodyUpClosesIt() throws {
        let harness = makeHarness()
        try openHistory(harness)
        XCTAssertEqual(harness.surface.drawer, .history(.collapsed))
        try drag(from: notchPoint(harness, fromTop: 200), dy: 180, in: harness.panel)
        wait { harness.surface.drawer == nil }
        XCTAssertNil(harness.surface.drawer)
        XCTAssertEqual(harness.surface.journal.last?.event, .dismiss(.dragUp))
        wait { !harness.model.isHistoryPanelOpen }
        XCTAssertFalse(harness.model.isHistoryPanelOpen, "the panel unmounts once the spring settles")
    }

    /// Etan: "drag further down opens Settings". Pull History past open from its body, release: Settings.
    func testPullingHistoryFurtherDownOpensTheSettingsDrawer() throws {
        let harness = makeHarness()
        try openHistory(harness)
        try drag(from: notchPoint(harness, fromTop: 120), dy: -140, in: harness.panel)
        wait { harness.surface.drawer == .settings(.general) }
        XCTAssertEqual(harness.surface.drawer, .settings(.general))
        XCTAssertEqual(harness.model.historyRows, NotchSettingsDrawerPresentation.rows, "Settings has its own height")
    }

    func testTheGearOpensSettingsInTheNotchAndClosesItAgain() throws {
        let harness = makeHarness()
        try click(center(harness.rects[3]), in: harness.panel)
        wait { harness.surface.drawer != nil }
        XCTAssertEqual(harness.surface.drawer, .settings(.general))
        wait { harness.model.isHistoryPanelOpen }
        resize(harness)
        drain(1.0)
        try click(control(3, harness), in: harness.panel)
        wait { harness.surface.drawer == nil }
        XCTAssertNil(harness.surface.drawer)
    }

    /// 0510 R3/N8: a capture starting under an open drawer keeps it, and a drawer opens during one.
    func testRecordingKeepsAnOpenDrawerAndAllowsANewOne() throws {
        let harness = makeHarness()
        try click(center(harness.rects[3]), in: harness.panel)
        wait { harness.surface.drawer != nil }
        harness.surface.send(.recordingChanged(true))
        XCTAssertEqual(harness.surface.drawer, .settings(.general))
        XCTAssertEqual(harness.surface.send(.openHistory).isRefusal, false)
        XCTAssertEqual(harness.surface.drawer, .history(.collapsed))
    }
}

private extension NotchSurfaceOutcome {
    var isRefusal: Bool {
        if case .refused = self { return true }
        return false
    }
}

extension NotchSurfaceHostedFlowTests {
    /// A pull measured from the top of the screen, the panel resized before every event as the app does (its top
    /// stays pinned while the drawer grows it), so the pointer stays where the user's would be.
    private func pull(_ harness: Harness, fromTop start: CGFloat, toTop end: CGFloat, steps: Int = 12) throws {
        resize(harness)
        try send(.leftMouseDown, at: notchPoint(harness, fromTop: start), to: harness.panel)
        drain()
        for step in 1 ... steps {
            resize(harness)
            let top = start + (end - start) * CGFloat(step) / CGFloat(steps)
            try send(.leftMouseDragged, at: notchPoint(harness, fromTop: top), to: harness.panel)
            drain(0.02)
        }
        resize(harness)
        try send(.leftMouseUp, at: notchPoint(harness, fromTop: end), to: harness.panel)
        drain(0.8)
    }

    enum Activity: String, CaseIterable { case launcher, recording, transcribing, typed }

    /// Puts the notch in `activity` the way the app feeds it (VoiceState plus the presentation model's envelope).
    private func enter(_ activity: Activity, _ harness: Harness) {
        let fixed = VoiceBarNotchContract.fixedWingWidth
        switch activity {
        case .launcher:
            return
        case .recording:
            harness.state.mode = .recording
            harness.model.updateOperationalEnvelope(
                hasTeleprompter: false, isRecording: true, hasCompactStatus: false,
                recordingLeadingWingWidth: fixed, recordingTrailingWingWidth: VoiceBarNotchContract.recordingTrailingWingWidth)
        case .transcribing:
            harness.state.mode = .transcribing
            harness.model.updateOperationalEnvelope(
                hasTeleprompter: false, isRecording: false, hasCompactStatus: true,
                compactStatusLeadingWingWidth: fixed, compactStatusTrailingWingWidth: fixed)
        case .typed:
            harness.state.mode = .idle
            harness.state.confirmationText = "Typed"
            harness.model.updateOperationalEnvelope(
                hasTeleprompter: false, isRecording: false, hasCompactStatus: true,
                compactStatusLeadingWingWidth: fixed, compactStatusTrailingWingWidth: 60)
        }
        resize(harness)
        drain(0.6)
    }

    /// 0510 N7 (R3): History pulls down from the notch while recording, transcribing and on Typed, not only from
    /// the launcher; the band keeps the activity's own wings above it.
    func testN7HistoryPullsDownInEveryNonSpeechState() throws {
        for activity in Activity.allCases {
            let harness = makeHarness()
            enter(activity, harness)
            try pull(harness, fromTop: 12, toTop: 230)
            wait { harness.surface.drawer != nil }
            XCTAssertEqual(harness.surface.drawer?.isHistory, true, "[N7] History pulls down while \(activity)")
            if activity != .launcher {
                XCTAssertEqual(harness.model.presentation.visualState, .history, "[N7] the drawer shows (\(activity))")
                XCTAssertNotEqual(harness.model.presentation.bandState, .hoverLauncher,
                                  "[N7] the band keeps the \(activity) wings above the drawer")
            }
            harness.panel.orderOut(nil)
        }
    }

    /// Review F3: with no History rows, the pull is Settings' own route while recording, transcribing and on the
    /// launcher (the recording wing has no gear); History never opens empty.
    func testF3WithNoHistoryThePullOpensSettingsEvenWhileRecording() throws {
        for activity in [Activity.launcher, .recording, .transcribing] {
            let harness = makeHarness(entries: 0)
            enter(activity, harness)
            try pull(harness, fromTop: 12, toTop: 300)
            wait { harness.surface.drawer != nil }
            XCTAssertEqual(harness.surface.drawer, .settings(.general), "[F3] Settings pulls down while \(activity)")
            harness.panel.orderOut(nil)
        }
    }

    /// 0510 N9 (R4): the microphone control is in the same core-side slot in every allowed state that has a left
    /// wing to spare (launcher, transcribing, Typed), and it opens Settings › General at the microphone in the notch.
    func testN9TheMicrophoneControlOpensTheNotchMicrophoneSettingEverywhere() throws {
        for activity in [Activity.launcher, .transcribing, .typed] {
            let harness = makeHarness()
            enter(activity, harness)
            XCTAssertEqual(harness.model.presentation.geometry.leadingWingWidth, VoiceBarNotchContract.fixedWingWidth,
                           "[N9] \(activity): the same two-slot left wing")
            let current = layout(harness.model)
            let chevron = VoiceBarNotchHitRegion(
                geometry: current.presentation.geometry,
                configuration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 1)
            ).rects[0].offsetBy(dx: current.visibleContentRect.minX, dy: current.visibleContentRect.minY)
            try click(center(chevron), in: harness.panel)
            wait { harness.surface.drawer != nil }
            XCTAssertEqual(harness.surface.drawer, .settings(.general), "[N9] \(activity): the chevron opens General")
            wait { harness.paneRequests.all.last??.focus != nil }
            XCTAssertEqual(harness.paneRequests.all.last??.focus, .microphonePriority,
                           "[N9] \(activity): General is asked to scroll to Microphone priority")
            harness.panel.orderOut(nil)
        }
    }

    /// The open History panel's extend handle, in window space (its native AX adapter is a real NSView).
    private func historyHandle(_ harness: Harness) throws -> NSPoint {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "notch-history-extend-handle" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        harness.host.layoutSubtreeIfNeeded()
        let handle = try XCTUnwrap(find(harness.host), "the open panel mounts its extend handle")
        let frame = handle.convert(handle.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// 0510 N5: a quick grab of the handle (two drag samples) extends History to eight rows, like a slow one.
    func testN5AQuickHandleGrabExtendsHistoryLikeASlowOne() throws {
        for steps in [12, 2] {
            let harness = makeHarness()
            try openHistory(harness)
            XCTAssertEqual(harness.surface.drawer, .history(.collapsed))
            try drag(from: historyHandle(harness), dy: -65, steps: steps, in: harness.panel)
            wait { harness.surface.drawer == .history(.expanded) }
            XCTAssertEqual(harness.surface.drawer, .history(.expanded), "[N5] \(steps)-sample grab of the handle")
            harness.panel.orderOut(nil)
        }
    }

    /// 0510 N4: History's handle and Settings' grip, pushed to the top of the screen, close their drawer on release.
    func testN4PushingEitherDrawerToTheTopClosesItOnRelease() throws {
        for (settings, steps) in [(false, 12), (false, 3), (true, 12), (true, 3)] {
            let harness = makeHarness()
            try openHistory(harness)
            var grip = try historyHandle(harness)
            if settings {
                // The gear swaps History for Settings on the same shell; the grip sits two rows lower.
                try click(control(3, harness), in: harness.panel)
                wait { harness.surface.drawer == .settings(.general) }
                resize(harness)
                drain(1.0)
                grip.y -= NotchSettingsDrawerPresentation.lowerSurfaceHeight - NotchHistoryMorph.lowerSurfaceHeight(rows: 6)
            }
            let top = notchPoint(harness, fromTop: 1)
            try drag(from: grip, dy: top.y - grip.y, steps: steps, in: harness.panel)
            wait { harness.surface.drawer == nil }
            XCTAssertNil(harness.surface.drawer, "[N4] \(settings ? "Settings" : "History") \(steps)-sample push to the top")
            XCTAssertEqual(harness.surface.journal.last?.event, .dismiss(.dragUp))
            harness.panel.orderOut(nil)
        }
    }
}

extension NotchSurfaceHostedFlowTests {
    /// 2.4 #813 (E2E `testE2E24HistoryDragUpCloses`): pushing the bottom edge (the extend handle) up past the
    /// collapsed rows closes History, the mirror of pulling it down.
    func testDraggingTheHandleUpPastCollapsedClosesHistory() throws {
        XCTAssertEqual(NotchHistoryMorph.handleCloseRows, 4.75)
        XCTAssertTrue(NotchHistoryMorph.handleClosesHistory(rawRows: 4.5))
        XCTAssertFalse(NotchHistoryMorph.handleClosesHistory(rawRows: 5.5), "a short push only collapses")
        XCTAssertTrue(NotchHistoryMorph.handleClosesHistory(rawRows: -0.54), "[N4] pushed to the top of the screen closes")
        XCTAssertEqual(NotchHistoryPresentation.rowAccessibilityIdentifier(index: 0), "history-row-1")
        XCTAssertEqual(NotchHistoryPresentation.rowAccessibilityIdentifier(index: 19), "history-row-20")
    }
}
