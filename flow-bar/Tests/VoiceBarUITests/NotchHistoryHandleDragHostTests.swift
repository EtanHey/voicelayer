import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.3 U4, the native drag defect (M1 native run 4 + diag1): pulling the open History panel's extend handle down
/// left it at 7 rows. Test host only: the real BarView in the real non-activating FloatingPillPanel, offscreen;
/// events go to the panel with `sendEvent`, the pointer never moves.
@MainActor
final class NotchHistoryHandleDragHostTests: XCTestCase {
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

    private func adapters(in view: NSView) -> [NSView] {
        (view.accessibilityIdentifier() == "notch-history-extend-handle" ? [view] : [])
            + view.subviews.flatMap { adapters(in: $0) }
    }

    func testDraggingTheExtendHandleDownSettlesOnTheExpandedDetent() throws {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true
        state.recentTranscriptionEntries = (0 ..< 14).map { index in
            RecentTranscriptionEntry(text: "Synthetic history row \(index + 1).", recordingPath: "/synthetic/\(index).wav",
                                     createdAt: Date().addingTimeInterval(Double(-60 * index)))
        }
        let model = VoiceBarNotchPresentationModel()
        let configuration = VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2)
        func layout() -> VoiceBarPanelLayout {
            VoiceBarPanelLayout.make(
                presentation: model.presentation, interactionConfiguration: configuration,
                canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
            )
        }
        let host = PillHostingView(rootView: BarView(
            state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
            presentationModel: model, includesPanelOutsets: true
        ))
        host.activeHitTestProvider = { _ in true }
        host.renderedSurfaceHitTestProvider = { _ in true }
        let panel = FloatingPillPanel(content: host)
        panel.isPillDragEnabled = false
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        windows.append(panel)

        // The hovered launcher, then a click on its History control (right wing, core side), then the window sized
        // to the open panel as the UIE2E and resident hosts do on onPanelLayoutChange.
        model.setHovered(true)
        let launcher = layout()
        panel.setContentSize(launcher.panelSize)
        host.frame = NSRect(origin: .zero, size: launcher.panelSize)
        host.layoutSubtreeIfNeeded()
        drain(0.3)
        let rects = VoiceBarNotchHitRegion(geometry: launcher.presentation.geometry, configuration: configuration).rects
            .map { $0.offsetBy(dx: launcher.visibleContentRect.minX, dy: launcher.visibleContentRect.minY) }
        let history = try XCTUnwrap(rects.count > 2 ? rects[2] : nil, "the launcher's History control")
        try send(.leftMouseDown, at: NSPoint(x: history.midX, y: history.midY), to: panel)
        try send(.leftMouseUp, at: NSPoint(x: history.midX, y: history.midY), to: panel)
        var deadline = Date().addingTimeInterval(3)
        while !model.isHistoryPanelOpen, Date() < deadline { drain() }
        XCTAssertTrue(model.isHistoryPanelOpen, "History opened from the launcher")
        panel.setContentSize(layout().panelSize)
        host.frame = NSRect(origin: .zero, size: layout().panelSize)
        deadline = Date().addingTimeInterval(3)
        while adapters(in: host).isEmpty, Date() < deadline {
            host.layoutSubtreeIfNeeded()
            drain()
        }
        drain(1.2) // the open spring settles; the handle takes presses only above 98 % progress
        host.layoutSubtreeIfNeeded()
        let handle = try XCTUnwrap(adapters(in: host).first, "the open panel mounts its extend handle")
        XCTAssertEqual(handle.accessibilityValue() as? String, "6 of 8 rows")
        let frame = handle.convert(handle.bounds, to: nil)
        let start = NSPoint(x: frame.midX, y: frame.midY)

        let hit = host.hitTest(host.superview?.convert(start, from: nil) ?? start)
        let hitName = hit.map { String(describing: type(of: $0)) } ?? "nil"

        try send(.leftMouseDown, at: start, to: panel)
        drain()
        for step in 1 ... 14 {
            // Window space is unflipped: down the screen is a smaller y. 7 rows x 46 pt.
            try send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - CGFloat(step) * 23), to: panel)
            drain(0.02)
        }
        try send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 322), to: panel)
        drain(1)

        XCTAssertEqual(model.historyRows, 8, "pulling the handle 7 rows down settles on the expanded 8 (hit view: \(hitName))")
        XCTAssertEqual(handle.accessibilityValue() as? String, "8 of 8 rows")
    }
}
