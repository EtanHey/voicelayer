@testable import VoiceBarUI
import XCTest

/// Settings › Speech engine row against the V10 contract: lifecycle states, actions, acknowledgements (accept is not
/// success), refusals, a foreign engine, autostart, and unknown data. No socket, clock, process or view.
final class CloneEngineControlTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_GB")
    private let now = ISO8601DateFormatter().date(from: "2026-11-05T09:30:00Z")!
    private let since = ISO8601DateFormatter().date(from: "2026-11-05T09:14:00Z")!

    private func snapshot(_ state: CloneEngineLifecycle, reason: String? = nil, pid: Int? = 123,
                          autostart: Bool = true) -> CloneEngineStatus {
        CloneEngineStatus(state: state, since: since, reason: reason.map(CloneEngineReason.init(code:)), pid: pid,
                            startWithVoiceBar: autostart)
    }

    private func present(_ model: CloneEngineControlModel) -> CloneEnginePresentation {
        model.presentation(now: now, timeZone: utc, locale: posix)
    }

    // MARK: - Unknown / missing data

    func testNoSnapshotIsUnavailableWithNoActionsAndNoAutostartValue() {
        var model = CloneEngineControlModel()
        let shown = present(model)
        XCTAssertEqual(shown.pill, "Unavailable")
        XCTAssertEqual(shown.tone, .grey)
        XCTAssertTrue(shown.actions.isEmpty)
        XCTAssertNil(shown.startWithVoiceBar, "a missing value is unavailable, never the default guessed")
        XCTAssertFalse(shown.startWithVoiceBarEnabled)
        XCTAssertNil(model.press(.start, id: "a", now: now))
        XCTAssertNil(model.setStartWithVoiceBar(false, id: "b", now: now))
    }

    func testSnapshotGoingAwayReturnsToUnavailable() {
        var model = CloneEngineControlModel(snapshot: snapshot(.running))
        model.receive(snapshot: nil)
        XCTAssertEqual(present(model).pill, "Unavailable")
    }

    // MARK: - States from the spec table

    func testEachStateShowsItsPillDescriptionAndActions() {
        let running = present(CloneEngineControlModel(snapshot: snapshot(.running)))
        XCTAssertEqual(running.pill, "Running")
        XCTAssertEqual(running.tone, .green)
        XCTAssertEqual(running.description, "Ready since 09:14.")
        XCTAssertEqual(running.actions.map(\.button), [.restart, .stop])
        XCTAssertTrue(running.actions.allSatisfy(\.isEnabled))
        XCTAssertEqual(running.accessibilityStatus, "Clone engine: running")

        let starting = present(CloneEngineControlModel(snapshot: snapshot(.starting)))
        XCTAssertEqual(starting.pill, "Starting")
        XCTAssertTrue(starting.pulses)
        XCTAssertTrue(starting.showsProgress)
        XCTAssertTrue(starting.actions.isEmpty)

        let restarting = present(CloneEngineControlModel(snapshot: snapshot(.restarting, reason: "engine_exited")))
        XCTAssertEqual(restarting.pill, "Restarting")
        XCTAssertFalse(restarting.pulses)
        XCTAssertTrue(restarting.showsProgress)
        XCTAssertEqual(restarting.description, "It stopped unexpectedly, so VoiceBar is starting it again.")
        XCTAssertTrue(restarting.actions.isEmpty)

        let stopped = present(CloneEngineControlModel(snapshot: snapshot(.stopped, reason: "user_stop", pid: nil)))
        XCTAssertEqual(stopped.pill, "Stopped")
        XCTAssertEqual(stopped.tone, .grey)
        XCTAssertEqual(stopped.description, "Long replies use the fast voice until it runs.")
        XCTAssertEqual(stopped.actions.map(\.button), [.start])
        XCTAssertEqual(CloneEngineButton.start.title, "Start engine")

        let failed = present(CloneEngineControlModel(snapshot: snapshot(.failed, reason: "port_occupied", pid: nil)))
        XCTAssertEqual(failed.pill, "Couldn't start")
        XCTAssertEqual(failed.tone, .red)
        XCTAssertTrue(failed.description.contains("Another program is using the voice engine's port"))
        XCTAssertEqual(failed.actions.map(\.button), [.tryAgain])
    }

    func testRunningSinceAnotherDayNamesTheDay() {
        var old = snapshot(.running)
        old.since = ISO8601DateFormatter().date(from: "2026-11-02T08:05:00Z")
        let text = present(CloneEngineControlModel(snapshot: old)).description
        XCTAssertTrue(text.hasPrefix("Ready since "))
        XCTAssertTrue(text.contains("08:05"))
        XCTAssertTrue(text.contains("2"), text)
    }

    func testRunningClaimsOnlyHealthNotSoundLatency() {
        let text = present(CloneEngineControlModel(snapshot: snapshot(.running))).description
        XCTAssertFalse(text.contains("First sound"), "running means health ok, not weights resident (V10)")
    }

    func testUnknownReasonCodeIsShownNotGuessed() {
        let failed = present(CloneEngineControlModel(snapshot: snapshot(.failed, reason: "brand_new_code", pid: nil)))
        XCTAssertTrue(failed.description.contains("brand_new_code"))
        let none = present(CloneEngineControlModel(snapshot: snapshot(.failed, pid: nil)))
        XCTAssertEqual(none.description, "The voice engine couldn't start, and VoiceBar didn't say why.")
    }

    func testOwnedUnhealthyEngineRetriesWithRestartAndCanBeStopped() {
        var model = CloneEngineControlModel(snapshot: snapshot(.failed, reason: "health_unavailable", pid: 77))
        XCTAssertEqual(present(model).actions.map(\.button), [.tryAgain, .stop])
        XCTAssertEqual(model.press(.tryAgain, id: "r", now: now)?.action, .restart)
        var gone = CloneEngineControlModel(snapshot: snapshot(.failed, reason: "launch_failed", pid: nil))
        XCTAssertEqual(gone.press(.tryAgain, id: "s", now: now)?.action, .start)
    }

    // MARK: - Foreign engine

    func testAdoptedEngineRefusesStopAndRestartAsContract() {
        var model = CloneEngineControlModel(snapshot: snapshot(.running, reason: "adopted_existing", pid: 900))
        let shown = present(model)
        XCTAssertEqual(shown.actions.map(\.button), [.restart, .stop])
        XCTAssertFalse(shown.actions.contains(where: \.isEnabled))
        XCTAssertEqual(shown.note, "VoiceBar didn't start this engine, so it won't stop or restart it.")
        XCTAssertNil(model.press(.stop, id: "x", now: now))
        XCTAssertNil(model.press(.restart, id: "y", now: now))
    }

    func testForeignEngineRejectionDisablesStopForThatPIDOnly() throws {
        var model = CloneEngineControlModel(snapshot: snapshot(.running, pid: 900))
        let stop = try XCTUnwrap(model.press(.stop, id: "stop-1", now: now))
        model.receive(ack: CloneEngineAck(id: stop.id, accepted: false, reason: "foreign_engine"))
        let shown = present(model)
        XCTAssertTrue(shown.noteIsProblem)
        XCTAssertFalse(shown.actions.contains(where: \.isEnabled))
        XCTAssertEqual(shown.pill, "Running", "a refusal leaves the engine as it was")

        model.receive(snapshot: snapshot(.running, pid: 901))
        XCTAssertTrue(present(model).actions.allSatisfy(\.isEnabled))
    }

    // MARK: - Acknowledgement is not success

    func testAcceptedStartKeepsShowingTheLastLifecycleStateUntilAnEventArrives() throws {
        var model = CloneEngineControlModel(snapshot: snapshot(.stopped, pid: nil))
        let command = try XCTUnwrap(model.press(.start, id: "start-1", now: now))
        XCTAssertEqual(command.action, .start)

        let sending = present(model)
        XCTAssertEqual(sending.pill, "Stopped")
        XCTAssertFalse(sending.actions.contains(where: \.isEnabled), "no second press while one is in flight")
        XCTAssertEqual(sending.note, "Asking VoiceBar to start the engine…")

        model.receive(ack: CloneEngineAck(id: "start-1", accepted: true))
        let accepted = present(model)
        XCTAssertEqual(accepted.pill, "Stopped", "accept means accepted, not running")
        XCTAssertFalse(accepted.noteIsProblem)
        XCTAssertNotNil(accepted.note)

        model.receive(snapshot: snapshot(.starting, pid: 321))
        let starting = present(model)
        XCTAssertEqual(starting.pill, "Starting")
        XCTAssertNil(starting.note)
    }

    func testAckForAnotherIDIsIgnored() {
        var model = CloneEngineControlModel(snapshot: snapshot(.stopped, pid: nil))
        _ = model.press(.start, id: "mine", now: now)
        model.receive(ack: CloneEngineAck(id: "someone-else", accepted: false, reason: "quitting"))
        XCTAssertEqual(present(model).note, "Asking VoiceBar to start the engine…")
    }

    func testRejectionsNameTheirReason() {
        for (reason, expected) in [
            ("quitting", "VoiceBar is quitting, so it left the engine as it was."),
            ("isolated_app", "Only the installed VoiceBar can control the voice engine. This copy can't."),
            ("invalid_command", "VoiceBar didn't recognize that request. It may need an update."),
        ] {
            var model = CloneEngineControlModel(snapshot: snapshot(.stopped, pid: nil))
            _ = model.press(.start, id: "c", now: now)
            model.receive(ack: CloneEngineAck(id: "c", accepted: false, reason: reason))
            XCTAssertEqual(present(model).note, expected)
            XCTAssertTrue(present(model).noteIsProblem)
            XCTAssertTrue(present(model).actions.allSatisfy(\.isEnabled), "a refusal re-enables the buttons")
        }
    }

    func testUnansweredRequestExpiresAfterTheAckTimeout() {
        var model = CloneEngineControlModel(snapshot: snapshot(.stopped, pid: nil))
        _ = model.press(.start, id: "c", now: now)
        XCTAssertEqual(model.ackDeadline, now.addingTimeInterval(CloneEngineControlModel.ackTimeout))
        model.expireUnanswered(now: now.addingTimeInterval(4.9))
        XCTAssertFalse(present(model).noteIsProblem)
        model.expireUnanswered(now: now.addingTimeInterval(5))
        XCTAssertTrue(present(model).noteIsProblem)
        XCTAssertNil(model.ackDeadline)
        XCTAssertTrue(present(model).actions.allSatisfy(\.isEnabled))
    }

    // MARK: - Autostart

    func testStartWithVoiceBarShowsThePendingValueUntilTheEventConfirmsIt() throws {
        var model = CloneEngineControlModel(snapshot: snapshot(.running, autostart: true))
        XCTAssertNil(model.setStartWithVoiceBar(true, id: "same", now: now), "no command for the current value")
        let command = try XCTUnwrap(model.setStartWithVoiceBar(false, id: "auto-1", now: now))
        XCTAssertEqual(command.action, .setAutostart(false))
        XCTAssertEqual(present(model).startWithVoiceBar, false)

        model.receive(ack: CloneEngineAck(id: "auto-1", accepted: true))
        XCTAssertEqual(present(model).startWithVoiceBar, false)
        XCTAssertNil(present(model).note, "an accepted autostart change needs no lifecycle note")
        XCTAssertEqual(present(model).pill, "Running", "autostart never starts or stops the engine now")

        model.receive(snapshot: snapshot(.running, autostart: false))
        XCTAssertEqual(present(model).startWithVoiceBar, false)
    }

    func testRejectedAutostartFallsBackToTheReportedValue() {
        var model = CloneEngineControlModel(snapshot: snapshot(.running, autostart: true))
        _ = model.setStartWithVoiceBar(false, id: "auto-2", now: now)
        model.receive(ack: CloneEngineAck(id: "auto-2", accepted: false, reason: "isolated_app"))
        XCTAssertEqual(present(model).startWithVoiceBar, true)
        XCTAssertTrue(present(model).noteIsProblem)
    }

    // MARK: - Wire shape (the V10 command contract)

    func testCommandsMatchTheContractExactly() {
        let start = CloneEngineCommand(action: .start, id: "id-1").wireObject
        XCTAssertEqual(start as NSDictionary, ["cmd": "clone_engine", "action": "start", "id": "id-1"] as NSDictionary)
        XCTAssertEqual(CloneEngineCommand(action: .restart, id: "r").wireObject["action"] as? String, "restart")
        XCTAssertEqual(CloneEngineCommand(action: .stop, id: "s").wireObject["action"] as? String, "stop")
        XCTAssertNil(CloneEngineCommand(action: .stop, id: "s").wireObject["value"], "only set_autostart has value")
        let autostart = CloneEngineCommand(action: .setAutostart(false), id: "a").wireObject
        XCTAssertEqual(autostart["action"] as? String, "set_autostart")
        XCTAssertEqual(autostart["value"] as? Bool, false)
    }

    func testReasonCodesRoundTripTheStableList() {
        XCTAssertEqual(CloneEngineReason(code: "adopted_existing"), .adoptedExisting)
        XCTAssertEqual(CloneEngineReason(code: "voicebar_quit"), .voicebarQuit)
        XCTAssertEqual(CloneEngineReason(code: "nope"), .unrecognized("nope"))
        XCTAssertNil(CloneEngineStatus(state: .stopped, since: nil, reason: nil, pid: 0, startWithVoiceBar: true).pid,
                     "only a positive PID is an identity")
    }

    func testRawV10FieldsMapWithoutGuessing() throws {
        let status = try XCTUnwrap(CloneEngineStatus(state: "running", since: "2026-11-05T00:00:00Z",
                                                     reason: "adopted_existing", pid: 123, startWithVoiceBar: true))
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.since, ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z"))
        XCTAssertTrue(status.isForeign)
        XCTAssertNil(CloneEngineStatus(state: "warming", since: nil, reason: nil, pid: nil, startWithVoiceBar: true),
                     "an unknown state is unavailable, not a guessed one")
        let undated = try XCTUnwrap(CloneEngineStatus(state: "running", since: "not a date", reason: nil, pid: 9,
                                                      startWithVoiceBar: false))
        XCTAssertNil(undated.since)
        XCTAssertEqual(present(CloneEngineControlModel(snapshot: undated)).description, "Ready.")
    }

    // MARK: - View model with a fake sender

    func testViewModelSendsThroughTheInjectedAdapterAndReportsANotSentFailure() {
        var sent: [[String: Any]] = []
        var connected = true
        let viewModel = CloneEngineControlViewModel(
            snapshot: snapshot(.stopped, pid: nil),
            send: { sent.append($0.wireObject); return connected },
            makeID: { "fixed-id" },
            now: { self.now }
        )
        viewModel.press(.start)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["id"] as? String, "fixed-id")
        viewModel.receive(ack: CloneEngineAck(id: "fixed-id", accepted: true))

        connected = false
        viewModel.receive(snapshot: snapshot(.running))
        viewModel.press(.stop)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(viewModel.presentation().note, "VoiceBar isn't connected, so the request wasn't sent.")
        XCTAssertTrue(viewModel.presentation().actions.allSatisfy(\.isEnabled))
    }

    func testSourceKeepsTheViewSideOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI")
        for file in ["CloneEngineControl.swift", "CloneEngineSectionView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["Process(", "kill(", "URLSession", "JSONSerialization", "socket(", "launchctl"] {
                XCTAssertFalse(source.contains(forbidden), "\(file) must not contain \(forbidden)")
            }
        }
    }
}
