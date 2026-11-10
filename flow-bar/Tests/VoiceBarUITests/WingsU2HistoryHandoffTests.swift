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
        let host: NSView
        let panel: FloatingPillPanel
        let bridge: VoiceBarNotchHistoryBridge
        let handoff: VoiceBarNotchSurfaceHandoff
        let historyPoint: NSPoint
    }

    private func makeRig(skipAnimations: Bool = false, held: @escaping (@escaping () -> Void) -> Void, presented: @escaping () -> Void) -> Rig {
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
        ).transaction { if skipAnimations { $0.disablesAnimations = true; $0.animation = nil } })
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
        return Rig(host: host, panel: panel, bridge: bridge, handoff: handoff,
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

    /// The History button's tooltip names the open intent: "Close history" while History is meant to be open,
    /// "History" once a close was applied. Waits (bounded) for the view to show `text`.
    private func waitForHistoryIntent(_ rig: Rig, tooltip text: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        func has(_ view: NSView) -> Bool { view.toolTip == text || view.subviews.contains(where: has) }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            rig.host.layoutSubtreeIfNeeded()
            if has(rig.host) { return }
            drain()
        }
        XCTFail("the History button never showed \"\(text)\"", file: file, line: line)
    }

    func testAListRequestedOverHistoryWaitsUntilTheClosingPanelHasUnmounted() throws {
        for skipAnimations in [false, true] {
            var held: [() -> Void] = []
            var presented = 0
            let rig = makeRig(skipAnimations: skipAnimations, held: { held.append($0) }, presented: { presented += 1 })
            try clickHistory(rig)
            XCTAssertTrue(rig.bridge.isHistoryOpen, "History mounted and reported")

            var unmounted = false
            let forward = rig.bridge.onHistoryPanelChanged
            defer { rig.bridge.onHistoryPanelChanged = forward; rig.handoff.schedule = { _ in } }
            rig.bridge.onHistoryPanelChanged = { mounted in
                if !mounted {
                    XCTAssertEqual(rig.handoff.coordinator.pendingMenu, .microphone)
                    XCTAssertTrue(held.isEmpty, "nothing scheduled before the unmount report")
                    unmounted = true
                }
                forward(mounted)
            }
            rig.handoff.schedule = { work in
                XCTAssertTrue(unmounted, "scheduling follows the panel's unmount report")
                XCTAssertFalse(rig.bridge.isHistoryOpen, "never schedule over mounted History")
                held.append(work)
            }

            rig.handoff.requestMenu(.microphone)
            XCTAssertEqual(rig.handoff.coordinator.pendingMenu, .microphone)
            XCTAssertTrue(rig.bridge.isHistoryOpen, "the close request has not unmounted History")
            XCTAssertTrue(held.isEmpty)
            XCTAssertEqual(presented, 0)

            // An offscreen spring may finish immediately when animations are skipped.
            // Observe the unmount boundary instead of assuming a minimum animation duration.
            let deadline = Date().addingTimeInterval(3)
            while !unmounted, Date() < deadline { drain() }
            XCTAssertTrue(unmounted, "History eventually unmounts (skip animations: \(skipAnimations))")
            XCTAssertFalse(rig.bridge.isHistoryOpen)
            XCTAssertNil(rig.handoff.coordinator.pendingMenu)
            XCTAssertEqual(held.count, 1, "the unmount schedules exactly one menu")
            XCTAssertEqual(presented, 0, "presentation waits for the scheduled turn")
            try XCTUnwrap(held.first)()
            XCTAssertEqual(presented, 1, "the list shows after History has unmounted")
        }
    }

    /// U2×U4 review (P2), view half: every History open intent emits the bridge's open request, unconditionally,
    /// so a reopen during the close spring (no mount change) still reaches the handoff. The full click-reopen-
    /// during-spring sequence is timing-dependent offscreen; its handoff half is
    /// `WingsU2Tests.testAnOpenRequestWhileHistoryIsStillMountedDropsTheWaitingMenu` (the exact sequence on the
    /// real handoff and bridge), and formal/notch-surfaces `MutantNoReopenCancel` models it.
    func testEveryHistoryOpenIntentEmitsAnOpenRequest() throws {
        let rig = makeRig(held: { _ in }, presented: {})
        var openRequests = 0
        let forward = rig.bridge.onHistoryOpenRequested
        rig.bridge.onHistoryOpenRequested = { openRequests += 1; forward() }
        try clickHistory(rig)
        waitForHistoryIntent(rig, tooltip: "Close history")
        XCTAssertEqual(openRequests, 1, "the open intent reached the handoff")
        rig.bridge.requestClose()
        waitForHistoryIntent(rig, tooltip: "History")
        XCTAssertEqual(openRequests, 1, "a close is not an open request")
    }

    private func drain() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}
