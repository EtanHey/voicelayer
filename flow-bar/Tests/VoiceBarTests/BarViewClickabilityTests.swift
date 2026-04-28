@testable import VoiceBar
import AppKit
import SwiftUI
import XCTest

@MainActor
final class BarViewClickabilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    final class SpyCommandRouter: VoiceBarCommandRouter {
        var cancelCount = 0
        var stopCount = 0
        var primaryTapCount = 0

        init() {
            super.init(voiceState: VoiceState())
        }

        override func handleCancel() {
            cancelCount += 1
        }

        override func handleStop() {
            stopCount += 1
        }

        override func handlePrimaryTap() {
            primaryTapCount += 1
        }
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

    func testIdlePillTapStillRoutesPrimaryAction() {
        let state = VoiceState()
        state.mode = .idle
        state.isConnected = true
        state.isCollapsed = false

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        click(host, at: NSPoint(x: host.bounds.midX, y: host.bounds.midY))

        XCTAssertEqual(router.primaryTapCount, 1)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.stopCount, 0)
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

    private func recordingStopButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.maxX - 14 - 13, y: host.bounds.midY)
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
