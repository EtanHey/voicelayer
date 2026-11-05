@testable import VoiceBarUI
import XCTest

/// What the Speech engine row says: pill, description and notes for every V10 state and reason, and the view model
/// the pane observes (fake sender, fixed clock).
final class CloneEnginePresentationTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let gb = Locale(identifier: "en_GB")
    private let now = ISO8601DateFormatter().date(from: "2026-11-05T09:30:00Z")!

    private func snapshot(_ state: CloneEngineSnapshot.State, reason: String? = nil, pid: Int? = 123,
                          since: String = "2026-11-05T09:14:00Z") -> CloneEngineSnapshot {
        CloneEngineSnapshot(state: state, since: since, reason: reason, pid: pid, startWithVoiceBar: true)
    }

    private func present(_ model: CloneEngineControlModel) -> CloneEnginePresentation {
        model.presentation(now: now, timeZone: utc, locale: gb)
    }

    func testNoSnapshotIsUnavailableWithNoAutostartValue() {
        let shown = present(CloneEngineControlModel())
        XCTAssertEqual(shown.pill, "Unavailable")
        XCTAssertTrue(shown.actions.isEmpty)
        XCTAssertNil(shown.startWithVoiceBar, "a missing value is unavailable, never the default guessed")
        XCTAssertFalse(shown.startWithVoiceBarEnabled)
    }

    func testEachStateShowsItsPillAndDescription() {
        let running = present(CloneEngineControlModel(snapshot: snapshot(.running)))
        XCTAssertEqual([running.pill, running.description], ["Running", "Ready since 09:14."])
        XCTAssertEqual(running.accessibilityStatus, "Clone engine: running")
        XCTAssertFalse(running.description.contains("First sound"), "running means health ok, not weights resident")

        let starting = present(CloneEngineControlModel(snapshot: snapshot(.starting)))
        XCTAssertTrue(starting.pulses && starting.showsProgress)
        XCTAssertEqual(starting.description, "Loading your voice model. This can take up to two minutes.")

        let restarting = present(CloneEngineControlModel(snapshot: snapshot(.restarting, reason: "engine_exited(1)")))
        XCTAssertFalse(restarting.pulses)
        XCTAssertEqual(restarting.description, "It stopped unexpectedly, so VoiceBar is starting it again.")

        let stopped = present(CloneEngineControlModel(snapshot: snapshot(.stopped, reason: "user_stop", pid: nil)))
        XCTAssertEqual([stopped.pill, stopped.description], ["Stopped", "Long replies use the fast voice until it runs."])

        let failed = present(CloneEngineControlModel(snapshot: snapshot(.failed, reason: "port_occupied", pid: nil)))
        XCTAssertEqual(failed.pill, "Couldn't start")
        XCTAssertEqual(failed.tone, .red)
        XCTAssertEqual(CloneEngineButton.start.title, "Start engine")
    }

    func testSinceOnAnotherDayNamesTheDayAndAnUnreadableSinceIsNotGuessed() {
        let old = present(CloneEngineControlModel(snapshot: snapshot(.running, since: "2026-11-02T08:05:00Z")))
        XCTAssertTrue(old.description.contains("08:05") && old.description.contains("2"), old.description)
        let undated = present(CloneEngineControlModel(snapshot: snapshot(.running, since: "not a date")))
        XCTAssertEqual(undated.description, "Ready.")
    }

    /// PR #690 mismatch 1: no V10 reason reaches the user as a raw code; an unknown one is shown, not guessed.
    func testEveryV10ReasonHasItsOwnWords() {
        let codes = ["port_occupied", "python_missing", "script_missing", "script_unresolved", "launch_failed(1)",
                     "exited_early(1)", "engine_exited(1)", "startup_timeout(15)", "health_unavailable", "stop_timeout"]
        var seen = Set<String>()
        for code in codes {
            let text = present(CloneEngineControlModel(snapshot: snapshot(.failed, reason: code))).description
            XCTAssertFalse(text.contains(code), "\(code) must not reach the user raw: \(text)")
            XCTAssertFalse(text.contains("didn't say why"), code)
            seen.insert(text)
        }
        XCTAssertGreaterThanOrEqual(seen.count, 8, "causes are told apart")
        let unknown = present(CloneEngineControlModel(snapshot: snapshot(.failed, reason: "brand_new", pid: nil)))
        XCTAssertTrue(unknown.description.contains("brand_new"))
        let none = present(CloneEngineControlModel(snapshot: snapshot(.failed, pid: nil)))
        XCTAssertEqual(none.description, "The voice engine couldn't start, and VoiceBar didn't say why.")
    }

    func testNotesFollowTheRequest() {
        var model = CloneEngineControlModel(snapshot: snapshot(.failed, reason: "port_occupied", pid: nil))
        _ = model.press(.tryAgain, id: "r", now: now)
        XCTAssertEqual(present(model).note, "Asking VoiceBar to start the engine…")
        model.receive(ackID: "r", accepted: true, reason: nil, now: now)
        XCTAssertEqual(present(model).note,
                       "VoiceBar is starting the engine. The status above updates as it reports in.")
        XCTAssertFalse(present(model).noteIsProblem)
        model.expire(now: now.addingTimeInterval(5))
        XCTAssertEqual(present(model).note, "VoiceBar tried, and the engine is still as shown above.")
        XCTAssertTrue(present(model).noteIsProblem)
        XCTAssertEqual(present(model).pill, "Couldn't start")

        let adopted = present(CloneEngineControlModel(snapshot: snapshot(.running, reason: "adopted_existing")))
        XCTAssertEqual(adopted.note, "VoiceBar didn't start this engine, so it won't stop or restart it.")
        XCTAssertFalse(adopted.actions.contains(where: \.isEnabled))
    }

    func testViewModelReadsCloneEngineAcksOnlyAndReportsANotSentFailure() {
        var sent: [[String: Any]] = []
        var connected = true
        let model = CloneEngineControlViewModel(
            snapshot: snapshot(.stopped, pid: nil),
            send: { sent.append($0.wireObject); return connected }, makeID: { "fixed-id" }, now: { self.now }
        )
        model.press(.start)
        XCTAssertEqual(sent.first?["id"] as? String, "fixed-id")
        model.receive(ack: SocketAckEvent(event: ["command": "stop", "outcome": "reject", "id": "fixed-id"])!)
        XCTAssertEqual(model.presentation().note, "Asking VoiceBar to start the engine…", "other commands are ignored")
        model.receive(ack: SocketAckEvent(event: ["command": "clone_engine", "outcome": "accept", "id": "fixed-id"])!)
        XCTAssertFalse(model.presentation().noteIsProblem)

        connected = false
        model.receive(snapshot: snapshot(.running))
        model.press(.stop)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(model.presentation().note, "VoiceBar isn't connected, so the request wasn't sent.")
        XCTAssertTrue(model.presentation().actions.allSatisfy(\.isEnabled))
    }
}
