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

    private func makeHarness(entries: Int = 20, pane: ((SettingsTab) -> AnyView)? = nil) -> Harness {
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
        let context = NotchSettingsDrawerContext(updates: nil, pane: { tab, request in
            paneRequests.all.append(request)
            return pane?(tab) ?? AnyView(EmptyView())
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

// MARK: - C6 L2c (N16): the Settings drawer grows downwards and keeps its height

extension NotchSurfaceHostedFlowTests {
    /// Opens Settings over History with the gear and returns its grip's centre at eight rows, in window space (History's
    /// handle, found by its accessibility element, moved down by the two rows Settings adds; as in N4 above).
    private func openSettingsFromHistory(_ harness: Harness) throws -> NSPoint {
        try openHistory(harness)
        var grip = try historyHandle(harness)
        try click(control(3, harness), in: harness.panel)
        wait { harness.surface.drawer == .settings(.general) }
        resize(harness)
        drain(1.0)
        grip.y -= NotchHistoryMorph.lowerSurfaceHeight(rows: 8) - NotchHistoryMorph.lowerSurfaceHeight(rows: 6)
        return grip
    }

    /// The grip's centre at `rows`, from its centre at eight rows (window space is unflipped: down is negative).
    private func grip(_ atEight: NSPoint, rows: Int) -> NSPoint {
        NSPoint(x: atEight.x, y: atEight.y - CGFloat(rows - 8) * NotchHistoryMorph.rowHeight)
    }

    /// Etan (N16, 12:40 X1-45): "this should be expandable and it currently is not expandable downwards." The grip
    /// drags the drawer taller one row per 46 pt, stops at the window's eleven rows, and the hit region follows.
    /// The window never resizes. Written against API that exists on the base, so it runs RED there (the grip only
    /// pushed the drawer closed, so a downward drag left it at eight rows).
    func testN16TheSettingsGripDragsTheDrawerTallerWithoutResizingTheWindow() throws {
        let harness = makeHarness()
        let eight = try openSettingsFromHistory(harness)
        XCTAssertEqual(harness.model.historyRows, 8, "Settings opens at expanded History's eight rows")
        let window = harness.panel.frame.size
        let panelSize = layout(harness.model).panelSize

        try drag(from: grip(eight, rows: 8), dy: -2 * NotchHistoryMorph.rowHeight, in: harness.panel)
        wait { harness.model.historyRows == 10 }
        XCTAssertEqual(harness.model.historyRows, 10, "[N16] two rows down: ten rows")
        XCTAssertEqual(harness.surface.drawer, .settings(.general), "a downward drag never closes or swaps the drawer")

        // Past the ceiling the grip stretches and settles back on it.
        try drag(from: grip(eight, rows: 10), dy: -4 * NotchHistoryMorph.rowHeight, in: harness.panel)
        wait { harness.model.historyRows == 11 }
        XCTAssertEqual(harness.model.historyRows, 11, "[N16] the drawer stops at eleven rows")

        XCTAssertEqual(layout(harness.model).panelSize, panelSize, "the window holds every Settings height")
        XCTAssertEqual(harness.panel.frame.size, window)
        let drawn = layout(harness.model)
        let lastRow = grip(eight, rows: 11)
        XCTAssertTrue(drawn.containsVisibleSurface(NSPoint(x: lastRow.x, y: lastRow.y)),
                      "[N16] the hit region covers the drawer down to its grip")
    }

    /// The height it was let go at is remembered: closing and reopening, and a short push up shrinks it. Pushed
    /// above eight rows it still closes the drawer (0510 N4).
    func testN16TheSettingsDrawerReopensAtTheHeightItWasLeftAt() throws {
        let harness = makeHarness()
        let eight = try openSettingsFromHistory(harness)
        try drag(from: grip(eight, rows: 8), dy: -3 * NotchHistoryMorph.rowHeight, in: harness.panel)
        wait { harness.surface.settingsRows == 11 }
        XCTAssertEqual(harness.surface.settingsRows, 11)

        try click(control(3, harness), in: harness.panel) // the gear closes it
        wait { harness.surface.drawer == nil }
        wait { !harness.model.isHistoryPanelOpen }
        harness.surface.send(.openSettings(.general))
        wait { harness.model.historyRows == 11 }
        XCTAssertEqual(harness.model.historyRows, 11, "[N16] it reopens at the height it was left at")
        resize(harness)
        drain(1.0)

        try drag(from: grip(eight, rows: 11), dy: 2 * NotchHistoryMorph.rowHeight, in: harness.panel)
        wait { harness.surface.settingsRows == 9 }
        XCTAssertEqual(harness.surface.settingsRows, 9, "a short push up makes it shorter")
        XCTAssertEqual(harness.surface.drawer, .settings(.general))

        try drag(from: grip(eight, rows: 9), dy: 4 * NotchHistoryMorph.rowHeight, in: harness.panel)
        wait { harness.surface.drawer == nil }
        XCTAssertNil(harness.surface.drawer, "pushed above eight rows the grip still closes the drawer")
        XCTAssertEqual(harness.surface.settingsRows, 9, "closing keeps the remembered height")
    }
}

extension NotchSurfaceHostedFlowTests {
    /// C6 L2c (Q-F48): letting go of the Settings grip tells the app how tall the drawer is drawn, before its rows
    /// change, so the hit gate settles from the drawn shell.
    func testQF48LettingGoOfTheGripReportsTheDrawnDrawerHeight() throws {
        let harness = makeHarness()
        let eight = try openSettingsFromHistory(harness)
        var now: TimeInterval = 0
        harness.model.drawnHistoryClock = { now }
        _ = harness.model.takeDrawnHistoryLowerSurface()
        try drag(from: grip(eight, rows: 8), dy: -2 * NotchHistoryMorph.rowHeight, in: harness.panel)
        wait { harness.model.historyRows == 10 }
        now = 0.1
        let drawn = try XCTUnwrap(harness.model.takeDrawnHistoryLowerSurface(), "the release reported the drawn height")
        XCTAssertEqual(drawn.rows, 10, "bound to the resize it was made for")
        XCTAssertEqual(drawn.lowerSurfaceHeight, NotchHistoryMorph.lowerSurfaceHeight(rows: 10),
                       accuracy: NotchHistoryMorph.rowHeight / 2, "the drawer was drawn about ten rows tall when it was let go")
    }
}

extension NotchSurfaceHostedFlowTests {
    /// R891 P2: a same-row release (the grip stretched past 11 and let go) changes no rows, so it must leave no
    /// drawn-height report behind for a later, unrelated same-size change (a note) to consume. The note's change
    /// must settle from the actual 11-row layout, through the same consumption the app runs.
    func testR891ASameRowReleaseLeavesNothingForALaterNoteChange() throws {
        let harness = makeHarness()
        let eight = try openSettingsFromHistory(harness)
        var now: TimeInterval = 0
        harness.model.drawnHistoryClock = { now }
        try drag(from: grip(eight, rows: 8), dy: -3 * NotchHistoryMorph.rowHeight, in: harness.panel)
        wait { harness.model.historyRows == 11 }
        _ = harness.model.takeDrawnHistoryLowerSurface()

        let settled = layout(harness.model)
        try drag(from: grip(eight, rows: 11), dy: -0.4 * NotchHistoryMorph.rowHeight, steps: 4, in: harness.panel)
        XCTAssertEqual(harness.model.historyRows, 11, "a stretch past the ceiling settles back on the same rows")
        now = 0.2 // inside the 500 ms window

        var gate = VoiceBarPanelHitGate(layout: settled)
        var noted = VoiceBarNotchOperationalInput(mode: .idle, isHovered: true)
        noted.isHistoryPanelOpen = true
        noted.historyRows = 11
        noted.transientNote = "Busy. Selection not read"
        let presentation = VoiceBarPresentation.notchPresentation(from: noted)
        let note = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2),
            canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry
        )
        XCTAssertTrue(gate.settles(into: note))
        XCTAssertNil(harness.model.takeDrawnHistoryLowerSurface(), "a same-row release reports nothing")
        gate.update(to: note, now: 0, takingDrawnReportFrom: harness.model) // the app's consumption
        XCTAssertEqual(gate.settlingFrom, [settled], "the note settles from the drawer as it actually rests")
    }
}

// MARK: - R890 P3: a pulled-taller drawer shows more of a real, scrollable pane

/// Where each row of the probe pane and the pane's scroll viewport are drawn (same nested hosting view, so the
/// `.global` frames are comparable).
final class PaneProbe {
    var viewport: CGRect = .zero
    var rows: [Int: CGRect] = [:]
    /// The highest row drawn entirely inside the viewport.
    var lastFullyVisibleRow: Int? {
        rows.filter { viewport.contains($0.value.insetBy(dx: 1, dy: 1)) }.keys.max()
    }
}

private struct ProbePane: View {
    let probe: PaneProbe
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0 ..< 24, id: \.self) { index in
                    Text("Probe row \(index)").frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .background(GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                                probe.rows[index] = frame
                            }
                        })
                }
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in probe.viewport = frame }
        })
    }
}

extension NotchSurfaceHostedFlowTests {
    /// R890 P3: N16 must reveal more of the real pane, not only a longer background. A populated scrollable
    /// General pane: a row clipped at eight rows is fully visible after the grip pulls the drawer to eleven, and
    /// still after closing and reopening.
    func testN16APulledTallerDrawerShowsRowsTheShortDrawerClipped() throws {
        let probe = PaneProbe()
        let harness = makeHarness(pane: { tab in tab == .general ? AnyView(ProbePane(probe: probe)) : AnyView(EmptyView()) })
        let eight = try openSettingsFromHistory(harness)
        wait { probe.lastFullyVisibleRow != nil }
        let atEight = try XCTUnwrap(probe.lastFullyVisibleRow, "the probe pane is drawn in the drawer")

        try drag(from: grip(eight, rows: 8), dy: -3 * NotchHistoryMorph.rowHeight, in: harness.panel)
        wait { harness.model.historyRows == 11 }
        drain(0.5)
        let atEleven = try XCTUnwrap(probe.lastFullyVisibleRow)
        XCTAssertGreaterThanOrEqual(atEleven, atEight + 2,
                                    "[N16] three more drawer rows (138 pt) reveal at least two more 40 pt pane rows")
        let revealed = atEight + 1
        let revealedFrame = try XCTUnwrap(probe.rows[revealed])
        XCTAssertTrue(probe.viewport.contains(revealedFrame.insetBy(dx: 1, dy: 1)),
                      "row \(revealed), clipped at eight drawer rows, is fully visible at eleven")
        print("[R890 P3] last fully visible pane row: \(atEight) at 8 drawer rows, \(atEleven) at 11; viewport \(probe.viewport.height) pt")

        try click(control(3, harness), in: harness.panel) // the gear closes it
        wait { !harness.model.isHistoryPanelOpen }
        harness.surface.send(.openSettings(.general))
        wait { harness.model.historyRows == 11 }
        resize(harness)
        drain(1.0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(probe.lastFullyVisibleRow), atEight + 2,
                                    "[N16] reopened at eleven rows, the extra pane rows are still visible")
    }
}

