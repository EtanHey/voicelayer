import Foundation
import XCTest
@testable import VoiceBar
@testable import VoiceBarUI

// Peer-proof probe for draft #686 (U3b Speech) against the merged V10 contract (#682,
// docs/clone-engine/README.md). Lives outside flow-bar/: .github/workflows/swift-proof-686.yml
// copies it into the merge-v10 tree only, after the real suites ran. Synthetic: V10's real
// CloneEngineController driven by fake probe/scheduler/process factory, so no process, socket,
// audio, file or launchd work. Failures here are findings for captain, not a red #686 gate.
final class CloneEngineV10ContractProbeTests: XCTestCase {
    private struct Boom: Error {}

    private struct Harness {
        let controller: CloneEngineController
        let events: () -> [CloneEngineSnapshot]
        let drain: () -> Void
    }

    private func harness(probe: CloneEngineObservation,
                         makeProcess: @escaping () throws -> Process = { throw Boom() }) -> Harness {
        var pending: [() -> Void] = []
        var events: [CloneEngineSnapshot] = []
        let controller = CloneEngineController(
            autostart: true, saveAutostart: { _ in }, probe: { $0(probe) },
            makeProcess: makeProcess, schedule: { _, block in pending.append(block) })
        controller.onChange = { payload in
            if let snapshot = CloneEngineSnapshot(payload: payload) { events.append(snapshot) }
        }
        return Harness(controller: controller, events: { events }, drain: {
            var spins = 0
            while !pending.isEmpty, spins < 8 {
                spins += 1
                pending.removeFirst()()
            }
        })
    }

    /// The one-line adapter #686 documents for integration.
    private func status(_ s: CloneEngineSnapshot) -> CloneEngineStatus? {
        CloneEngineStatus(state: s.state.rawValue, since: s.since, reason: s.reason, pid: s.pid,
                          startWithVoiceBar: s.startWithVoiceBar)
    }

    /// V10 publishes these reason strings (CloneEngineController.swift / README). Each should reach
    /// the Speech row as a known cause, not as `.unrecognized` with the raw code quoted to the user.
    func testEveryReasonV10PublishesMapsToAKnownCause() throws {
        var published: [CloneEngineSnapshot] = []
        let failures: [Error] = [CloneEngineLaunchError.pythonMissing, CloneEngineLaunchError.scriptMissing,
                                 CloneEngineLaunchError.sourceUnavailable, Boom()]
        for failure in failures {
            let h = harness(probe: .absent, makeProcess: { throw failure })
            h.controller.open()
            h.drain()
            XCTAssertEqual(h.events().last?.state, .failed, "V10 latches failed after four startup failures")
            published += h.events()
        }
        // Exit/timeout codes need a real child to produce; use V10's exact format strings instead.
        let since = ISO8601DateFormatter().string(from: Date())
        for code in ["exited_early(1)", "engine_exited(1)", "startup_timeout(15)", "stop_timeout"] {
            published.append(CloneEngineSnapshot(state: .failed, since: since, reason: code, pid: nil,
                                                 startWithVoiceBar: true))
        }
        var unrecognized: [String] = []
        for snapshot in published {
            let mapped = try XCTUnwrap(status(snapshot))
            let row = CloneEngineControlModel(snapshot: mapped).presentation(now: Date())
            print("PROBE reason=\(snapshot.reason ?? "nil") state=\(snapshot.state.rawValue) pill=\(row.pill) description=\(row.description)")
            if case .unrecognized(let code)? = mapped.reason, !unrecognized.contains(code) { unrecognized.append(code) }
        }
        XCTAssertEqual(unrecognized, [], "V10 reason codes #686 maps to .unrecognized")
    }

    /// #686's exact wire objects against V10's real command handler and VoiceState's ack parser.
    func testSettingsCommandsAreAcceptedByTheV10Handler() throws {
        let h = harness(probe: .occupied)
        h.controller.open()
        let actions: [CloneEngineAction] = [.setAutostart(false), .start, .stop, .restart]
        for (index, action) in actions.enumerated() {
            let command = CloneEngineCommand(action: action, id: "probe-\(index)")
            let ack = try XCTUnwrap(SocketAckEvent(event: h.controller.handle(command.wireObject)))
            XCTAssertEqual(ack.command, .cloneEngine)
            XCTAssertEqual(ack.id, "probe-\(index)")
            XCTAssertEqual(ack.outcome, .accept, "\(action) rejected: \(ack.reason ?? "nil")")
        }
        XCTAssertFalse(h.controller.snapshot.startWithVoiceBar, "set_autostart Bool value reached V10")
    }

    /// V10 dedupes publishes on (state, reason, pid). A Try again that lands in the same state sends
    /// an accept ack and no lifecycle event. Records what #686's row then shows.
    func testTryAgainThatLandsInTheSameStatePublishesNoEvent() throws {
        let h = harness(probe: .occupied)
        h.controller.open()
        let failed = try XCTUnwrap(h.events().last)
        XCTAssertEqual(failed.reason, "port_occupied")
        var model = CloneEngineControlModel(snapshot: try XCTUnwrap(status(failed)))
        let command = try XCTUnwrap(model.press(.tryAgain, id: "retry", now: Date()))
        XCTAssertEqual(command.action, .start)
        let ack = h.controller.handle(command.wireObject)
        model.receive(ack: CloneEngineAck(id: ack["id"] as? String ?? "", accepted: ack["outcome"] as? String == "accept",
                                          reason: ack["reason"] as? String))
        h.drain()
        XCTAssertEqual(h.events().count, 1, "V10 published no new lifecycle event for the retry")
        let row = model.presentation(now: Date())
        print("PROBE after-retry pill=\(row.pill) note=\(row.note ?? "nil") actions=\(row.actions.map { "\($0.button.title):\($0.isEnabled)" })")
    }
}
