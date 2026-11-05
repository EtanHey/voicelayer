import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.3 U2 × U4: the notch surface handoff reads History's MOUNTED state (the morph-B panel is on screen while it
/// springs closed), not the open intent. A microphone list asked for over an open History must not be scheduled
/// until the closing panel has unmounted: shown on the intent change it would hang over a half-closed panel, and
/// SwiftUI does not animate that panel away while the AppKit menu tracks. Test host only: the real BarView in the
/// real FloatingPillPanel, offscreen; the click is sent to the panel, the pointer never moves.
@MainActor
final class WingsU2HistoryHandoffTests: XCTestCase {
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

    private struct Rig {
        let panel: FloatingPillPanel
        let bridge: VoiceBarNotchHistoryBridge
        let handoff: VoiceBarNotchSurfaceHandoff
        let historyPoint: NSPoint
    }

    private func makeRig(held: @escaping (@escaping () -> Void) -> Void, presented: @escaping () -> Void) -> Rig {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true
        state.recentTranscriptionEntries = [
            RecentTranscriptionEntry(text: "A synthetic row for the handoff test.", recordingPath: "/synthetic/a.wav",
                                     createdAt: Date().addingTimeInterval(-60)),
        ]
        let bridge = VoiceBarNotchHistoryBridge()
        let handoff = VoiceBarNotchSurfaceHandoff(bridge: bridge) { _ in presented() }
        handoff.schedule = held

        let configuration = VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2)
        let presentation = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(mode: .idle, isHovered: true, isCollapsed: false)
        )
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: configuration,
            canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry
        )
        let host = PillHostingView(rootView: BarView(
            state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
            includesPanelOutsets: true,
            onOpenMicrophonePicker: { handoff.requestMenu(.microphone) },
            historyBridge: bridge
        ))
        host.frame = NSRect(origin: .zero, size: layout.panelSize)
        host.activeHitTestProvider = { layout.containsInteractiveContent($0) }
        host.renderedSurfaceHitTestProvider = { layout.containsVisibleSurface($0) }
        let panel = FloatingPillPanel(content: host)
        panel.activeHitTestProvider = { layout.containsInteractiveContent($0) }
        panel.isPillDragEnabled = false
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        windows.append(panel)
        host.layoutSubtreeIfNeeded()
        // History: right wing, core side (index 2 after the chevron and the mic).
        let rects = VoiceBarNotchHitRegion(geometry: presentation.geometry, configuration: configuration).rects
            .map { $0.offsetBy(dx: layout.visibleContentRect.minX, dy: layout.visibleContentRect.minY) }
        return Rig(panel: panel, bridge: bridge, handoff: handoff,
                   historyPoint: NSPoint(x: rects[2].midX, y: rects[2].midY))
    }

    private func clickHistory(_ rig: Rig) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: rig.historyPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0
            ))
            rig.panel.sendEvent(event)
        }
        drain()
    }

    func testAListRequestedOverHistoryWaitsUntilTheClosingPanelHasUnmounted() throws {
        var held: [() -> Void] = []
        var presented = 0
        let rig = makeRig(held: { held.append($0) }, presented: { presented += 1 })
        try clickHistory(rig)
        XCTAssertTrue(rig.bridge.isHistoryOpen, "History mounted and reported")

        // The chevron's request asks History to close; the panel now springs closed but is still mounted.
        rig.handoff.requestMenu(.microphone)
        drain()
        XCTAssertEqual(rig.handoff.coordinator.pendingMenu, .microphone, "waiting for History to leave the screen")
        XCTAssertTrue(rig.bridge.isHistoryOpen, "still mounted while the close spring runs")
        XCTAssertTrue(held.isEmpty, "nothing is scheduled over the closing panel")
        XCTAssertEqual(presented, 0)
    }

    /// U2×U4 review (P2): open History, request the list, then click History again before its close spring
    /// settles. The panel never unmounts, so no mount change fires; the reopen itself must drop the waiting list,
    /// or a later close opens a stale one (formal/notch-surfaces, MutantNoReopenCancel).
    func testReopeningAClosingHistoryCancelsTheWaitingList() throws {
        var held: [() -> Void] = []
        let rig = makeRig(held: { held.append($0) }, presented: {})
        try clickHistory(rig)
        rig.handoff.requestMenu(.microphone)
        drain()
        XCTAssertEqual(rig.handoff.coordinator.pendingMenu, .microphone)
        try clickHistory(rig) // reopen while the close spring runs
        XCTAssertTrue(rig.bridge.isHistoryOpen, "never unmounted")
        XCTAssertNil(rig.handoff.coordinator.pendingMenu, "the reopen dropped the waiting list")
        XCTAssertTrue(held.isEmpty)
    }

    private func drain() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}
