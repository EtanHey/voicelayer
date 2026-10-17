import AppKit
import OffscreenTestSupport
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class BrokenMicAlertTests: XCTestCase {
    private var scratchDirectory: URL!
    private var previousDisablePath: String?

    override func setUpWithError() throws {
        previousDisablePath = ProcessInfo.processInfo.environment["QA_VOICE_DISABLE_FLAG_PATH"]
        scratchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hide11-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let flag = scratchDirectory.appendingPathComponent("disabled").path
        setenv("QA_VOICE_DISABLE_FLAG_PATH", flag, 1)
        // Assert routing BEFORE constructing controllers or delivering any events.
        guard VoiceLayerPaths.voiceDisabledFlagPath() == flag else {
            throw NSError(domain: "HIDE11UnsafeDisablePath", code: 1)
        }
    }

    override func tearDownWithError() throws {
        if let previousDisablePath { setenv("QA_VOICE_DISABLE_FLAG_PATH", previousDisablePath, 1) }
        else { unsetenv("QA_VOICE_DISABLE_FLAG_PATH") }
        try FileManager.default.removeItem(at: scratchDirectory)
    }

    @MainActor private func fixture() -> (AppDelegate, SocketServer, VoiceBarDaemonController, AlertQueue) {
        _ = NSApplication.shared
        let app = AppDelegate()
        let server = SocketServer(state: app.voiceState, socketPath: scratchDirectory.appendingPathComponent("unused.sock").path)
        let queue = AlertQueue()
        let controller = VoiceBarDaemonController(
            restartScheduler: { _, _ in },
            microphonePermissionPrompter: { queue.messages.append($0) },
            microphonePromptScheduler: { queue.callbacks.append($0) },
            microphonePromptDisabled: { queue.disabledChecks += 1; return queue.disabled }
        )
        app.configureCaptureFailurePresentation(server, controller: controller)
        return (app, server, controller, queue)
    }

    private func backgroundFailures(_ controller: VoiceBarDaemonController) {
        // Only a caller that positively knows the origin may opt into deferral.
        controller.handleCaptureFailure(type: "broken-mic", userInitiated: false)
        controller.handleCaptureFailure(type: "broken-mic", userInitiated: false)
    }

    @MainActor private func send(_ line: String, to server: SocketServer) {
        for event in line.split(separator: "\n") { server.parseLine(String(event)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private let failure = #"{"type":"error","capture_failure":"broken-mic","show_during_bar_recording":true}"#
    private let recovered = """
    {"type":"state","state":"recording","bar_owned":false}
    {"type":"transcription","text":"Synthetic recovered capture"}
    {"type":"state","state":"idle","source":"recording"}
    """

    @MainActor func testUserCaptureWhileHiddenPresentsImmediatelyForF5AndAsk() {
        for barOwned in [true, false] {
            let (app, server, _, queue) = fixture()
            app.quickMenuActions().first { $0.title == "Hide for 1 hour" }?.perform()
            defer { app.unsnoozeNow() }
            for _ in 0..<2 {
                send("{\"type\":\"state\",\"state\":\"recording\",\"bar_owned\":\(barOwned)}", to: server)
                send(failure, to: server)
            }
            queue.run()
            XCTAssertEqual(queue.messages.count, 1, "bar_owned=\(barOwned)")
            XCTAssertTrue(app.isSnoozed)
        }
    }

    @MainActor func testBackgroundWhileHiddenDefersUntilShow() {
        let (app, _, controller, queue) = fixture()
        app.quickMenuActions().first { $0.title == "Hide for 1 hour" }?.perform()
        backgroundFailures(controller)
        queue.run()
        XCTAssertTrue(queue.messages.isEmpty)
        app.unsnoozeNow()
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
        controller.presentDeferredMicrophonePermissionPrompt()
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
    }

    @MainActor func testDeferredConditionClearedBeforeShowDropsAlert() {
        let (app, server, controller, queue) = fixture()
        app.isSnoozed = true
        backgroundFailures(controller)
        send(recovered, to: server)
        app.isSnoozed = false
        controller.presentDeferredMicrophonePermissionPrompt()
        queue.run()
        XCTAssertTrue(queue.messages.isEmpty)
    }

    @MainActor func testVisibleKeepsExistingSecondFailureBehavior() {
        let (app, server, _, queue) = fixture()
        defer { _ = app }
        send(failure, to: server)
        queue.run()
        XCTAssertTrue(queue.messages.isEmpty)
        send(failure, to: server)
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
    }

    @MainActor func testBackgroundAlertPresentsOnSnoozeExpiry() async {
        let (app, _, controller, queue) = fixture()
        let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100)))
        var expiry: CheckedContinuation<Void, Never>?
        app.configurePanelVisibilityForTesting(panel, snoozeSleep: {
            await withCheckedContinuation { expiry = $0 }
        })
        defer { app.unsnoozeNow(); panel.orderOut(nil) }
        app.quickMenuActions().first { $0.title == "Hide for 1 hour" }?.perform()
        while expiry == nil { await Task.yield() }
        backgroundFailures(controller)
        queue.run()
        XCTAssertTrue(queue.messages.isEmpty)
        expiry?.resume()
        for _ in 0..<100 where app.isSnoozed { await Task.yield() }
        XCTAssertFalse(app.isSnoozed)
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
    }

    @MainActor func testVoiceStateHiddenAlsoDefersAndUserFailureEscalatesPendingBackground() {
        let (app, server, controller, queue) = fixture()
        app.voiceState.snooze()
        defer { app.unsnoozeNow() }
        send(#"{"type":"state","state":"transcribing"}"#, to: server)
        backgroundFailures(controller)
        queue.run()
        XCTAssertTrue(queue.messages.isEmpty)
        send(#"{"type":"state","state":"recording","bar_owned":false}"#, to: server)
        send(failure, to: server)
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
        app.unsnoozeNow()
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
    }

    @MainActor func testIdleAndArchiveResultDoNotClearDeferredMicrophoneCondition() {
        let (app, server, controller, queue) = fixture()
        app.isSnoozed = true
        backgroundFailures(controller)
        send(#"{"type":"state","state":"idle","source":"recording"}"#, to: server)
        send(#"{"type":"transcription","text":"Synthetic archive result","recording_is_latest":false}"#, to: server)
        app.unsnoozeNow()
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
    }

    @MainActor func testSuccessfulAskWithRealArchiveOrderingPayloadClearsDeferredAlert() {
        let (app, server, controller, queue) = fixture()
        app.isSnoozed = true
        controller.handleCaptureFailure(type: "broken-mic", userInitiated: false)
        controller.handleCaptureFailure(type: "broken-mic", userInitiated: false)
        send(#"{"type":"state","state":"recording","mode":"vad","silence_mode":"thoughtful","bar_owned":false}"#, to: server)
        // Same payload shape as input.ts: Ask is excluded from latest dictation ordering.
        send(#"{"type":"state","state":"transcribing"}"#, to: server)
        send(#"{"type":"transcription","text":"Synthetic Ask reply","recording_path":"/fixture/ask/audio.wav","recording_created_at":"2026-10-17T00:00:00Z","recording_is_latest":false}"#, to: server)
        app.unsnoozeNow()
        queue.run()
        XCTAssertTrue(queue.messages.isEmpty)
    }

    @MainActor func testMissingRecordingReceiptWhileHiddenShowsFailureImmediately() {
        let (app, server, _, queue) = fixture()
        app.isSnoozed = true
        send(failure, to: server); send(failure, to: server)
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
        app.unsnoozeNow()
    }

    @MainActor func testFailureAfterDisconnectWhileHiddenStillShowsImmediately() {
        let (app, server, _, queue) = fixture()
        app.isSnoozed = true
        send(#"{"type":"state","state":"recording","bar_owned":true}"#, to: server)
        server.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        send(failure, to: server); send(failure, to: server)
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
        app.unsnoozeNow()
    }

    func testDisabledReadsAreIsolatedAndPresenterPredicateIsInjected() throws {
        XCTAssertEqual(VoiceLayerPaths.voiceDisabledFlagPath(), scratchDirectory.appendingPathComponent("disabled").path)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBar/VoiceBarDaemonController.swift"))
        let presentation = try XCTUnwrap(source.range(of: "func presentDeferredMicrophonePermissionPrompt()"))
        let end = try XCTUnwrap(source.range(of: "func clearDeferredMicrophonePermissionPrompt()", range: presentation.upperBound..<source.endIndex))
        let body = String(source[presentation.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("VoiceLayerPaths.isVoicelayerDisabled()"), "Presentation must use the injected predicate")
        XCTAssertTrue(source.contains("microphonePromptDisabled:"))
    }

    @MainActor func testRecoveryGuardUsesScratchFlagAndQueuedPresenterUsesInjectedPredicate() throws {
        let (app, _, controller, queue) = fixture()
        defer { _ = app }
        let flag = scratchDirectory.appendingPathComponent("disabled")
        XCTAssertEqual(VoiceLayerPaths.voiceDisabledFlagPath(), flag.path)
        try Data().write(to: flag)
        backgroundFailures(controller)
        XCTAssertTrue(queue.callbacks.isEmpty, "Unchanged recovery guard must read the scratch flag")
        try FileManager.default.removeItem(at: flag)
        backgroundFailures(controller)
        queue.disabled = true
        queue.run()
        XCTAssertEqual(queue.disabledChecks, 1)
        XCTAssertTrue(queue.messages.isEmpty)
        controller.presentDeferredMicrophonePermissionPrompt()
        queue.disabled = false
        queue.run()
        XCTAssertTrue(queue.messages.isEmpty, "Disabled callback drops the pending condition")
    }

    @MainActor func testQueuedCallbackRechecksHiddenAndClearedCondition() {
        for clear in [false, true] {
            let (app, server, controller, queue) = fixture()
            backgroundFailures(controller)
            if clear { send(recovered, to: server) } else { app.isSnoozed = true }
            queue.run()
            XCTAssertTrue(queue.messages.isEmpty)
            app.isSnoozed = false
            controller.presentDeferredMicrophonePermissionPrompt()
            queue.run()
            XCTAssertEqual(queue.messages.count, clear ? 0 : 1)
        }
    }
}

private final class AlertQueue {
    var disabled = false
    var disabledChecks = 0
    var callbacks: [() -> Void] = []
    var messages: [String] = []
    func run() {
        let pending = callbacks
        callbacks.removeAll()
        pending.forEach { $0() }
    }
}
