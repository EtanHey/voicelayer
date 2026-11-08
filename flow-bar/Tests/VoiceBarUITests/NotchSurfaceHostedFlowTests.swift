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
        var opened: [(SettingsTab, SettingsFocus?)]
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

    private func makeHarness() -> Harness {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: false
        )
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true
        state.recentTranscriptionEntries = (0 ..< 20).map { index in
            RecentTranscriptionEntry(text: "Synthetic history row \(index + 1).", recordingPath: "/synthetic/\(index).wav",
                                     createdAt: Date().addingTimeInterval(Double(-60 * index)))
        }
        let model = VoiceBarNotchPresentationModel()
        let surface = NotchSurfaceModel()
        surface.log = { _ in }
        var opened: [(SettingsTab, SettingsFocus?)] = []
        let context = NotchSettingsDrawerContext(
            shortcutHint: { "Hold F5 to dictate" }, defaultMicrophoneName: { "Synthetic microphone" },
            updates: nil, openSettingsWindow: { opened.append(($0, $1)) }
        )
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
        _ = opened
        return Harness(state: state, model: model, surface: surface, host: host, panel: panel, rects: rects, opened: [])
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
        XCTAssertEqual(harness.model.historyRows, NotchHistoryMorph.maximumRows, "Settings sits at the expanded height")
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

    func testRecordingClosesAnOpenDrawerSoTheWingsShow() throws {
        let harness = makeHarness()
        try click(center(harness.rects[3]), in: harness.panel)
        wait { harness.surface.drawer != nil }
        harness.surface.send(.recordingChanged(true))
        XCTAssertNil(harness.surface.drawer)
        XCTAssertEqual(harness.surface.send(.openHistory), .refused(.recording))
    }
}
