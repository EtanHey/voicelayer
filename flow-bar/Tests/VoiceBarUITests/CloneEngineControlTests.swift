@testable import VoiceBarUI
import XCTest

/// The Speech engine row's state machine against the V10 contract (docs/clone-engine/README.md): which actions each
/// state offers, acknowledgements (accept is not success), refusals, a foreign engine, autostart and every reason code
/// V10 sends. No socket, clock, process or view.
final class CloneEngineControlTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-05T09:30:00Z")!

    private func snapshot(_ state: CloneEngineSnapshot.State, reason: String? = nil, pid: Int? = 123,
                          autostart: Bool = true) -> CloneEngineSnapshot {
        CloneEngineSnapshot(state: state, since: "2026-11-05T09:14:00Z", reason: reason, pid: pid,
                            startWithVoiceBar: autostart)
    }

    private func enabled(_ model: CloneEngineControlModel) -> [CloneEngineButton] {
        model.buttons().filter(model.isEnabled)
    }

    func testEachStateOffersItsActions() {
        XCTAssertEqual(CloneEngineControlModel().buttons(), [], "no snapshot: nothing to press")
        XCTAssertEqual(CloneEngineControlModel(snapshot: snapshot(.running)).buttons(), [.restart, .stop])
        XCTAssertEqual(CloneEngineControlModel(snapshot: snapshot(.starting)).buttons(), [])
        XCTAssertEqual(CloneEngineControlModel(snapshot: snapshot(.restarting)).buttons(), [])
        XCTAssertEqual(CloneEngineControlModel(snapshot: snapshot(.stopped, pid: nil)).buttons(), [.start])
        XCTAssertEqual(CloneEngineControlModel(snapshot: snapshot(.failed, reason: "port_occupied", pid: nil)).buttons(),
                       [.tryAgain])
        var none = CloneEngineControlModel()
        XCTAssertNil(none.press(.start, id: "a", now: now))
        XCTAssertNil(none.setStartWithVoiceBar(false, id: "b", now: now))
    }

    /// PR #690 mismatch 1: V10 appends a status to some codes and sends codes the draft didn't know.
    func testEveryReasonV10SendsParsesToAKnownCode() {
        let codes = ["adopted_existing", "port_occupied", "python_missing", "script_missing", "script_unresolved",
                     "launch_failed(1)", "exited_early(1)", "engine_exited(1)", "startup_timeout(15)",
                     "health_unavailable", "stop_timeout", "user_stop", "voicebar_quit"]
        for code in codes {
            if case .unrecognized = CloneEngineReason(code: code) { XCTFail("\(code) is a V10 code") }
        }
        XCTAssertEqual(CloneEngineReason(code: "startup_timeout(15)"), .startupTimeout)
        XCTAssertEqual(CloneEngineReason(code: "engine_exited(-9)"), .engineExited)
        XCTAssertEqual(CloneEngineReason(code: "brand_new(2)"), .unrecognized("brand_new(2)"), "kept, not guessed")
    }

    /// PR #690 mismatch 3: after `stop_timeout` VoiceBar still holds the process, so Stop must be offered again.
    func testOwnedProcessAfterAFailureCanBeRestartedOrStopped() {
        for reason in ["health_unavailable", "stop_timeout"] {
            var model = CloneEngineControlModel(snapshot: snapshot(.failed, reason: reason, pid: 77))
            XCTAssertEqual(enabled(model), [.tryAgain, .stop], reason)
            XCTAssertEqual(model.press(.tryAgain, id: "r", now: now)?.action, .restart, reason)
        }
        var stuck = CloneEngineControlModel(snapshot: snapshot(.failed, reason: "stop_timeout", pid: 77))
        XCTAssertEqual(stuck.press(.stop, id: "s", now: now)?.action, .stop)
        var gone = CloneEngineControlModel(snapshot: snapshot(.failed, reason: "launch_failed(2)", pid: nil))
        XCTAssertEqual(gone.press(.tryAgain, id: "s", now: now)?.action, .start)
    }

    func testForeignEngineRefusesStopAndRestart() throws {
        var adopted = CloneEngineControlModel(snapshot: snapshot(.running, reason: "adopted_existing", pid: 900))
        XCTAssertEqual(enabled(adopted), [])
        XCTAssertNil(adopted.press(.stop, id: "x", now: now))

        var model = CloneEngineControlModel(snapshot: snapshot(.running, pid: 900))
        let stop = try XCTUnwrap(model.press(.stop, id: "stop-1", now: now))
        model.receive(ackID: stop.id, accepted: false, reason: "foreign_engine", now: now)
        XCTAssertEqual(model.refusal, .foreignEngine)
        XCTAssertEqual(enabled(model), [], "a foreign_engine reject marks that PID foreign")
        model.receive(snapshot: snapshot(.running, pid: 901))
        XCTAssertEqual(enabled(model), [.restart, .stop], "only for that PID")
    }

    func testAcceptIsNotSuccessAndOtherIDsAreIgnored() throws {
        var model = CloneEngineControlModel(snapshot: snapshot(.stopped, pid: nil))
        let command = try XCTUnwrap(model.press(.start, id: "start-1", now: now))
        XCTAssertEqual(command.action, .start)
        XCTAssertEqual(enabled(model), [], "no second press while one is in flight")
        model.receive(ackID: "someone-else", accepted: false, reason: "quitting", now: now)
        XCTAssertNotNil(model.inFlight, "another ID is ignored")

        model.receive(ackID: "start-1", accepted: true, reason: nil, now: now)
        XCTAssertNil(model.inFlight)
        XCTAssertEqual(model.accepted?.command, command)
        XCTAssertEqual(model.snapshot?.state, .stopped, "accept means accepted, not running")
        model.receive(snapshot: snapshot(.starting, pid: 321))
        XCTAssertNil(model.accepted, "the first lifecycle change ends the accepted request")
    }

    /// PR #690 mismatch 2: V10 publishes only on a change, so a retry that lands in the same state sends no event.
    func testAcceptedRetryThatChangesNothingIsNoticedAfterTheReplyWindow() {
        var model = CloneEngineControlModel(snapshot: snapshot(.failed, reason: "port_occupied", pid: nil))
        _ = model.press(.tryAgain, id: "retry", now: now)
        model.receive(ackID: "retry", accepted: true, reason: nil, now: now)
        XCTAssertEqual(model.nextDeadline, now.addingTimeInterval(CloneEngineControlModel.replyWindow))
        model.expire(now: now.addingTimeInterval(4.9))
        XCTAssertFalse(model.acceptedWithoutChange)
        model.expire(now: now.addingTimeInterval(5))
        XCTAssertTrue(model.acceptedWithoutChange)
        XCTAssertNil(model.nextDeadline)
        XCTAssertEqual(enabled(model), [.tryAgain])
    }

    func testRefusalsAndAMissingAckReEnableTheButtons() {
        for (reason, expected) in [("quitting", CloneEngineRefusal.quitting), ("isolated_app", .isolatedApp),
                                   ("invalid_command", .invalidCommand), ("weird", .unrecognized("weird"))] {
            var model = CloneEngineControlModel(snapshot: snapshot(.stopped, pid: nil))
            _ = model.press(.start, id: "c", now: now)
            model.receive(ackID: "c", accepted: false, reason: reason, now: now)
            XCTAssertEqual(model.refusal, expected)
            XCTAssertEqual(enabled(model), [.start])
        }
        var silent = CloneEngineControlModel(snapshot: snapshot(.stopped, pid: nil))
        _ = silent.press(.start, id: "c", now: now)
        silent.expire(now: now.addingTimeInterval(5))
        XCTAssertEqual(silent.refusal, .noReply)
        var unsent = CloneEngineControlModel(snapshot: snapshot(.stopped, pid: nil))
        _ = unsent.press(.start, id: "c", now: now)
        unsent.sendFailed(id: "c")
        XCTAssertEqual(unsent.refusal, .notSent)
    }

    func testStartWithVoiceBarKeepsThePendingValueUntilTheEventConfirmsIt() throws {
        var model = CloneEngineControlModel(snapshot: snapshot(.running, autostart: true))
        XCTAssertNil(model.setStartWithVoiceBar(true, id: "same", now: now), "no command for the current value")
        let command = try XCTUnwrap(model.setStartWithVoiceBar(false, id: "auto-1", now: now))
        XCTAssertEqual(command.action, .setAutostart(false))
        model.receive(ackID: "auto-1", accepted: true, reason: nil, now: now)
        XCTAssertEqual(model.pendingAutostart, false)
        XCTAssertNil(model.accepted, "an autostart change never starts or stops the engine now")
        model.receive(snapshot: snapshot(.running, autostart: false))
        XCTAssertNil(model.pendingAutostart)

        var rejected = CloneEngineControlModel(snapshot: snapshot(.running, autostart: true))
        _ = rejected.setStartWithVoiceBar(false, id: "auto-2", now: now)
        rejected.receive(ackID: "auto-2", accepted: false, reason: "isolated_app", now: now)
        XCTAssertNil(rejected.pendingAutostart, "a refusal falls back to the reported value")
    }

    func testCommandsMatchTheContractExactly() {
        let start = CloneEngineCommand(action: .start, id: "id-1").wireObject
        XCTAssertEqual(start as NSDictionary, ["cmd": "clone_engine", "action": "start", "id": "id-1"] as NSDictionary)
        XCTAssertEqual(CloneEngineCommand(action: .restart, id: "r").wireObject["action"] as? String, "restart")
        XCTAssertNil(CloneEngineCommand(action: .stop, id: "s").wireObject["value"], "only set_autostart has value")
        let autostart = CloneEngineCommand(action: .setAutostart(false), id: "a").wireObject
        XCTAssertEqual(autostart["action"] as? String, "set_autostart")
        XCTAssertEqual(autostart["value"] as? Bool, false)
    }

    func testSourceKeepsTheViewSideOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("CloneEngine") }
            .filter { $0 != "CloneEngineSnapshot.swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["Process(", "kill(", "URLSession", "JSONSerialization", "socket(", "launchctl"] {
                XCTAssertFalse(source.contains(forbidden), "\(file) must not contain \(forbidden)")
            }
        }
    }
}
