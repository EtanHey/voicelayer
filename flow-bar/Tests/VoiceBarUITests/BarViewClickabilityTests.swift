import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class BarViewClickabilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    final class SpyCommandRouter: BarCommandRouting {
        var cancelCount = 0
        var stopCount = 0
        var primaryTapCount = 0

        func handleCancel() {
            cancelCount += 1
        }

        func handleStop() {
            stopCount += 1
        }

        func handlePrimaryTap() {
            primaryTapCount += 1
        }

        func handleReplay() {}

        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    func testRecordingCancelAndStopControlsReceiveClicks() {
        let state = VoiceState()
        state.mode = .recording
        state.isConnected = true
        state.isCollapsed = false

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        click(host, at: recordingCancelButtonCenter(in: host))
        click(host, at: recordingStopButtonCenter(in: host))

        XCTAssertEqual(router.cancelCount, 1)
        XCTAssertEqual(router.stopCount, 1)
        XCTAssertEqual(router.primaryTapCount, 0)
    }

    func testVADRecordingHoldControlReceivesClickAndSendsCommand() {
        let state = VoiceState()
        state.mode = .recording
        state.recordingMode = "vad"
        state.isConnected = true
        state.isCollapsed = false
        var sentCommand: [String: Any]?
        state.sendCommand = { sentCommand = $0 }

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        click(host, at: recordingHoldButtonCenter(in: host))

        XCTAssertEqual(sentCommand?["cmd"] as? String, "set_recording_hold")
        XCTAssertEqual(sentCommand?["engaged"] as? Bool, true)
        XCTAssertTrue(state.isRecordingHoldEngaged)
    }

    func testIdlePillBackgroundTapDoesNotRoutePrimaryAction() {
        let state = VoiceState()
        state.mode = .idle
        state.isConnected = true
        state.isCollapsed = false

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        click(host, at: NSPoint(x: host.bounds.midX, y: host.bounds.midY))

        XCTAssertEqual(router.primaryTapCount, 0)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.stopCount, 0)
    }

    func testIdleMicButtonRoutesPrimaryAction() {
        let state = VoiceState()
        state.mode = .idle
        state.isConnected = true
        state.isCollapsed = false

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        clickFirstPrimaryTap(in: host, router: router)

        XCTAssertEqual(router.primaryTapCount, 1)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.stopCount, 0)
    }

    func testErrorStatusIconRoutesPrimaryAction() {
        let state = VoiceState()
        state.mode = .error
        state.isConnected = true
        state.isCollapsed = false

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        clickFirstPrimaryTap(in: host, router: router)

        XCTAssertEqual(router.primaryTapCount, 1)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.stopCount, 0)
    }

    func testDraggingFromRecordingStopButtonDoesNotClickStop() {
        let state = VoiceState()
        state.mode = .recording
        state.isConnected = true
        state.isCollapsed = false

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)
        let start = recordingStopButtonCenter(in: host)
        let end = NSPoint(x: start.x + 24, y: start.y + 2)

        drag(host, from: start, to: end)

        XCTAssertEqual(router.stopCount, 0)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.primaryTapCount, 0)
    }

    private func makeHost(state: VoiceState, router: SpyCommandRouter) -> NSHostingView<BarView> {
        let host = NSHostingView(rootView: BarView(state: state, commandRouter: router))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func recordingCancelButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.maxX - 14 - 26 - 2 - 13, y: host.bounds.midY)
    }

    private func recordingHoldButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.maxX - 14 - ((26 + 2) * 2) - 13, y: host.bounds.midY)
    }

    private func recordingStopButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.maxX - 14 - 13, y: host.bounds.midY)
    }

    private func statusIconCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.minX + 14 + 3 + 8 + 9, y: host.bounds.midY)
    }

    private func click(_ host: NSView, at point: NSPoint) {
        guard host.hitTest(point) != nil else {
            XCTFail("Expected a hit-test target at \(point)")
            return
        }

        guard let window = host.window,
              let downEvent = mouseEvent(type: .leftMouseDown, at: point, windowNumber: window.windowNumber),
              let upEvent = mouseEvent(type: .leftMouseUp, at: point, windowNumber: window.windowNumber) else {
            XCTFail("Expected to create mouse events")
            return
        }

        window.sendEvent(downEvent)
        window.sendEvent(upEvent)
    }

    private func clickFirstPrimaryTap(in host: NSView, router: SpyCommandRouter) {
        var x = host.bounds.minX
        while x <= host.bounds.midX {
            let before = router.primaryTapCount
            click(host, at: NSPoint(x: x, y: host.bounds.midY))
            if router.primaryTapCount > before {
                return
            }
            x += 4
        }
        XCTFail("Expected to find a clickable status icon in the leading half of the pill; bounds=\(host.bounds)")
    }

    private func drag(_ host: NSView, from start: NSPoint, to end: NSPoint) {
        guard host.hitTest(start) != nil else {
            XCTFail("Expected a hit-test target at \(start)")
            return
        }

        guard let window = host.window,
              let downEvent = mouseEvent(type: .leftMouseDown, at: start, windowNumber: window.windowNumber),
              let dragEvent = mouseEvent(type: .leftMouseDragged, at: end, windowNumber: window.windowNumber),
              let upEvent = mouseEvent(type: .leftMouseUp, at: end, windowNumber: window.windowNumber) else {
            XCTFail("Expected to create mouse events")
            return
        }

        window.sendEvent(downEvent)
        window.sendEvent(dragEvent)
        window.sendEvent(upEvent)
    }

    private func mouseEvent(type: NSEvent.EventType, at point: NSPoint, windowNumber: Int) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        )
    }
}
