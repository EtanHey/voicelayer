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
        var replayCount = 0

        func handleCancel() {
            cancelCount += 1
        }

        func handleStop() {
            stopCount += 1
        }

        func handlePrimaryTap() {
            primaryTapCount += 1
        }

        func handleReplay() {
            replayCount += 1
        }

        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    func testBarViewKeepsTheMergedW2WaveformTruthCallSites() throws {
        let source = try barViewSource()

        XCTAssertTrue(source.contains("currentLevel: { state.recordingWaveformLevel }"))
        XCTAssertTrue(source.contains("isListening: !state.speechDetected"))
        XCTAssertEqual(source.components(separatedBy: "state.playbackAudioLevel()").count - 1, 2)
        XCTAssertTrue(source.contains("WaveformView(processingColor: Theme.stateColor(for: .transcribing))"))
        XCTAssertFalse(source.contains("recordingWaveformLevels"))
        XCTAssertFalse(source.contains("transcribingWaveformLevels"))
        XCTAssertTrue(source.contains("case .transcribing:"))
        XCTAssertTrue(source.contains("commandRouter.handleCancel()"))
    }

    func testNativeNotchShellUsesApprovedBoundsForPrimaryStates() {
        let idle = VoiceState()
        idle.mode = .idle
        idle.isConnected = true
        idle.isCollapsed = false
        XCTAssertEqual(
            makeHost(state: idle, router: SpyCommandRouter()).bounds.size,
            NSSize(width: 185, height: 32)
        )

        let hover = VoiceState()
        hover.mode = .idle
        hover.isConnected = true
        hover.isCollapsed = false
        hover.isHovering = true
        XCTAssertEqual(
            makeHost(state: hover, router: SpyCommandRouter()).bounds.size,
            NSSize(width: 285, height: 32)
        )

        let recording = VoiceState()
        recording.mode = .recording
        recording.recordingMode = "vad"
        recording.isConnected = true
        recording.isCollapsed = false
        XCTAssertEqual(
            makeHost(state: recording, router: SpyCommandRouter()).bounds.size,
            NSSize(width: 409, height: 32)
        )

        let teleprompter = VoiceState()
        teleprompter.isConnected = true
        teleprompter.isCollapsed = false
        teleprompter.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Native teleprompter geometry",
        ])
        XCTAssertEqual(
            makeHost(state: teleprompter, router: SpyCommandRouter()).bounds.size,
            NSSize(width: 465, height: 228)
        )
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

    func testPTTRecordingDoesNotExposeTheVADHoldControl() {
        let state = VoiceState()
        state.mode = .recording
        state.recordingMode = "ptt"
        state.isConnected = true
        state.isCollapsed = false
        var sentCommands: [[String: Any]] = []
        state.sendCommand = { sentCommands.append($0) }

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        click(host, at: recordingHoldButtonCenter(in: host))

        XCTAssertTrue(sentCommands.isEmpty)
        XCTAssertFalse(state.isRecordingHoldEngaged)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.stopCount, 0)
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

    func testReadbackReplayControlFitsInsidePillAndReceivesClickWithAllAccessories() {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.recentTranscriptions = ["Previous transcript"]
        state.transcriptionVocabularyTerms = ["VoiceLayer"]
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Retained readback with every trailing control",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        XCTAssertGreaterThan(host.bounds.width, Theme.pillSpeakingQueueWidth)
        click(host, at: readbackReplayButtonCenter(in: host))

        XCTAssertEqual(router.replayCount, 1)
        XCTAssertEqual(router.primaryTapCount, 0)
    }

    func testReadbackHideShowAndDismissControlsRemainInTheTeleprompterSurface() {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Retained native readback",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        let host = makeHost(state: state, router: SpyCommandRouter())

        click(host, at: readbackVisibilityButtonCenter(in: host))
        XCTAssertTrue(state.isTeleprompterDismissed)

        click(host, at: readbackVisibilityButtonCenter(in: host))
        XCTAssertFalse(state.isTeleprompterDismissed)

        click(host, at: readbackDismissButtonCenter(in: host))
        XCTAssertFalse(state.isTeleprompterReadback)
        XCTAssertNil(state.teleprompterText)
    }

    func testHiddenLiveTeleprompterKeepsAReachableShowControlInCompactStatus() {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Show this live teleprompter again",
        ])
        state.dismissTeleprompter()
        XCTAssertTrue(state.isTeleprompterDismissed)

        let host = makeHost(state: state, router: SpyCommandRouter())
        clickFirstTeleprompterShow(in: host, state: state)

        XCTAssertFalse(state.isTeleprompterDismissed)
    }

    func testIdleMicButtonRoutesPrimaryAction() {
        let state = VoiceState()
        state.mode = .idle
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        clickFirstPrimaryTap(in: host, router: router)

        XCTAssertEqual(router.primaryTapCount, 1)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.stopCount, 0)
    }

    func testTranscribingNotchRendersTheLiveStatusText() throws {
        let source = try barViewSource()
        let start = try XCTUnwrap(source.range(of: "case .transcribing:"))
        let end = try XCTUnwrap(
            source.range(of: "case .speaking:", range: start.upperBound ..< source.endIndex)
        )

        XCTAssertTrue(source[start.lowerBound ..< end.lowerBound].contains("statusLabel"))
    }

    func testQueuedSpeechUsesTheExistingQueuePreviewInTheNativeShell() throws {
        let source = try barViewSource()

        XCTAssertTrue(source.contains("if state.queueItems.count > 1"))
        XCTAssertTrue(source.contains("VoiceBarPresentation.queuePreview(from: state.queueItems)"))
    }

    func testOpenPopoversKeepTheLauncherMountedAfterPointerExit() throws {
        let source = try barViewSource()

        XCTAssertTrue(source.contains("isHistoryPresented || isVocabularyPresented"))
        XCTAssertTrue(source.contains("synchronizeLauncherRetention()"))
    }

    func testBarViewDoesNotOwnRetainedReadbackDismissal() throws {
        let source = try barViewSource()

        XCTAssertFalse(source.contains("presentationModel?.updateRetainedReadback"))
        XCTAssertFalse(source.contains("private func updateRetainedReadbackLifecycle"))
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

    private func makeHost(
        state: VoiceState,
        router: SpyCommandRouter,
        presentationModel: VoiceBarNotchPresentationModel? = nil
    ) -> NSHostingView<BarView> {
        let host = NSHostingView(
            rootView: BarView(
                state: state,
                commandRouter: router,
                presentationModel: presentationModel
            )
        )
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
        NSPoint(x: host.bounds.maxX - 55, y: host.bounds.midY)
    }

    private func recordingHoldButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.maxX - 65, y: host.bounds.midY)
    }

    private func recordingStopButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.maxX - 27, y: host.bounds.midY)
    }

    private func readbackReplayButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.midX - 28, y: 23)
    }

    private func readbackVisibilityButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.midX, y: 23)
    }

    private func readbackDismissButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.midX + 28, y: 23)
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

    private func clickFirstTeleprompterShow(in host: NSView, state: VoiceState) {
        var x = host.bounds.midX
        while x <= host.bounds.maxX {
            click(host, at: NSPoint(x: x, y: host.bounds.midY))
            if !state.isTeleprompterDismissed {
                return
            }
            x += 4
        }
        XCTFail("Expected a clickable Show teleprompter control in compact speaking status; bounds=\(host.bounds)")
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

    private func barViewSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/VoiceBarUI/BarView.swift"),
            encoding: .utf8
        )
    }
}
