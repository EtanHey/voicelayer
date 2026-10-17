import AppKit
import OffscreenTestSupport
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class BrokenMicAlertTests: XCTestCase {
    @MainActor private func fixture() -> (AppDelegate, SocketServer, VoiceBarDaemonController, AlertQueue) {
        _ = NSApplication.shared
        let app = AppDelegate()
        let server = SocketServer(state: app.voiceState)
        let queue = AlertQueue()
        let controller = VoiceBarDaemonController(
            restartScheduler: { _, _ in },
            microphonePermissionPrompter: { queue.messages.append($0) },
            microphonePromptScheduler: { queue.callbacks.append($0) }
        )
        app.configureCaptureFailurePresentation(server, controller: controller)
        return (app, server, controller, queue)
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
        let (app, server, controller, queue) = fixture()
        app.quickMenuActions().first { $0.title == "Hide for 1 hour" }?.perform()
        send(failure, to: server); send(failure, to: server)
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
        send(failure, to: server); send(failure, to: server)
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
        let (app, server, _, queue) = fixture()
        let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100)))
        var expiry: CheckedContinuation<Void, Never>?
        app.configurePanelVisibilityForTesting(panel, snoozeSleep: {
            await withCheckedContinuation { expiry = $0 }
        })
        defer { app.unsnoozeNow(); panel.orderOut(nil) }
        app.quickMenuActions().first { $0.title == "Hide for 1 hour" }?.perform()
        while expiry == nil { await Task.yield() }
        send(failure, to: server); send(failure, to: server)
        queue.run()
        XCTAssertTrue(queue.messages.isEmpty)
        expiry?.resume()
        for _ in 0..<100 where app.isSnoozed { await Task.yield() }
        XCTAssertFalse(app.isSnoozed)
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
    }

    @MainActor func testVoiceStateHiddenAlsoDefersAndUserFailureEscalatesPendingBackground() {
        let (app, server, _, queue) = fixture()
        app.voiceState.snooze()
        defer { app.unsnoozeNow() }
        send(#"{"type":"state","state":"transcribing"}"#, to: server)
        send(failure, to: server); send(failure, to: server)
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
        let (app, server, _, queue) = fixture()
        app.isSnoozed = true
        send(failure, to: server); send(failure, to: server)
        send(#"{"type":"state","state":"idle","source":"recording"}"#, to: server)
        send(#"{"type":"transcription","text":"Synthetic archive result","recording_is_latest":false}"#, to: server)
        app.unsnoozeNow()
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
    }

    @MainActor func testDisconnectDoesNotLeaveUserCapturePresentationFlagStuck() {
        let (app, server, _, queue) = fixture()
        app.isSnoozed = true
        send(#"{"type":"state","state":"recording","bar_owned":false}"#, to: server)
        XCTAssertTrue(server.captureAwaitingPresentationResult)
        server.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertFalse(server.captureAwaitingPresentationResult)
        send(failure, to: server); send(failure, to: server)
        queue.run()
        XCTAssertTrue(queue.messages.isEmpty)
        app.unsnoozeNow()
        queue.run()
        XCTAssertEqual(queue.messages.count, 1)
    }

    @MainActor func testQueuedCallbackRechecksHiddenAndClearedCondition() {
        for clear in [false, true] {
            let (app, server, controller, queue) = fixture()
            send(failure, to: server); send(failure, to: server)
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
    var callbacks: [() -> Void] = []
    var messages: [String] = []
    func run() {
        let pending = callbacks
        callbacks.removeAll()
        pending.forEach { $0() }
    }
}
