import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C6 L2 (Q-F02 / N15 / E4 / Q-F26): "core, wings and drawer move together" and "now it goes back to its place".
///
/// Root cause: the resident app's mode-change handler wrote `isPillDragEnabled = anchorMode.allowsFreeDrag` (always
/// true: `loadAnchorMode()` returns `.follow`) straight onto the notch panel after `configureNotchDragging` had
/// turned it off. A mode change whose presentation keeps the window's size (a drawer mounted during a take) skips
/// `applyPanelLayout`, so nothing turned it off again. From then on `FloatingPillPanel.sendEvent` handed every
/// `leftMouseDragged` that started on the notch to `performDrag`: the whole window followed the pointer, the
/// SwiftUI pull never saw the drag, and the next layout pass snapped the window back.
///
/// Every hosted notch test sets `isPillDragEnabled = false` by hand, which is why none of them saw it.
///
/// Fix: a panel configured as a notch surface refuses window dragging whatever is written later, so the app's
/// mode-change writes are inert (VoiceBarApp.swift is left alone: it belongs to L4/L8 and hashes into 7 models).
@MainActor
final class NotchPullWindowAnchorTests: XCTestCase {
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

    /// What the resident app's `handleVoiceModeChange` writes on every mode change (the default `.follow` anchor).
    private func applyModeChangeWrites(_ panel: FloatingPillPanel) {
        let anchor = VoiceBarAnchorMode(defaultsValue: nil)
        panel.isMovableByWindowBackground = anchor.allowsFreeDrag
        panel.isPillDragEnabled = anchor.allowsFreeDrag
    }

    func testANotchPanelNeverHandsAPullToTheWindowAfterAModeChange() {
        for kind in [VoiceBarNotchScreenKind.hardwareNotch, .flatDisplayFallback] {
            let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 48)))
            panel.configureNotchDragging(screenKind: kind, allowsFreeDrag: true, mode: .idle)
            applyModeChangeWrites(panel)
            XCTAssertFalse(panel.shouldHandlePillDrag(startedInVisiblePill: true),
                           "\(kind): a notch drag belongs to the notch's own gestures, never to the window")
            XCTAssertFalse(panel.isMovableByWindowBackground, "\(kind): the window background never moves the notch")
        }
    }

    func testAPullStartedAfterAModeChangeOpensHistoryAndTheWindowStaysPut() throws {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true
        state.recentTranscriptionEntries = (0 ..< 8).map { index in
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
        // The resident sequence: layout configures the notch, then a voice-mode change writes the anchor's flags.
        panel.configureNotchDragging(screenKind: .hardwareNotch, allowsFreeDrag: true, mode: .idle)
        applyModeChangeWrites(panel)
        let origin = NSPoint(x: -100_000, y: -100_000)
        panel.setFrameOrigin(origin)
        panel.orderBack(nil)
        windows.append(panel)

        model.setHovered(true)
        let launcher = layout()
        panel.setContentSize(launcher.panelSize)
        panel.setFrameOrigin(origin)
        host.frame = NSRect(origin: .zero, size: launcher.panelSize)
        host.layoutSubtreeIfNeeded()
        drain(0.3)
        // The window server clamps far-offscreen origins; anchor to where the window actually rests.
        // The hosting view may grow the window downward as History mounts; the anchor is its top edge and x.
        let restingTop = panel.frame.maxY
        let restingX = panel.frame.minX

        // A pull from the bare notch: the core's centre, inside the top band (window space is unflipped).
        let coreX = launcher.visibleContentRect.minX + launcher.presentation.geometry.coreMidX
        let start = NSPoint(x: coreX, y: host.frame.height - 10)
        try send(.leftMouseDown, at: start, to: panel)
        drain()
        for step in 1 ... 16 {
            try send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - CGFloat(step) * 16), to: panel)
            drain(0.02)
        }
        try send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 256), to: panel)
        let deadline = Date().addingTimeInterval(3)
        while !model.isHistoryPanelOpen, Date() < deadline { drain() }

        XCTAssertEqual(panel.frame.maxY, restingTop, "the pull never moves the window's top edge (the core stays anchored)")
        XCTAssertEqual(panel.frame.minX, restingX, "the pull never slides the window sideways")
        XCTAssertTrue(model.isHistoryPanelOpen, "the pull reaches the notch's own gesture and opens History")
    }
}
