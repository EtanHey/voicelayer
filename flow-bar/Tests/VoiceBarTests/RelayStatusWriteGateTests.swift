@testable import VoiceBar
import XCTest

/// C13 review (Bugbot on PR #193): a relay status probe started before Set up / Reinstall could finish after it and
/// write the pre-install snapshot over the fresh one, flipping the Installed badge back while the new result line
/// said the reinstall worked. Only a probe that started after the latest setup, with no setup running, may write.
final class RelayStatusWriteGateTests: XCTestCase {
    func testAProbeWithNoSetupAroundItWrites() {
        let gate = RelayStatusWriteGate()
        XCTAssertTrue(gate.mayWrite(gate.ticket(), setupInFlight: false))
    }

    func testAProbeThatStartedBeforeASetupFinishedCannotOverwriteIt() {
        var gate = RelayStatusWriteGate()
        let stale = gate.ticket()
        gate.setupFinished()
        XCTAssertFalse(gate.mayWrite(stale, setupInFlight: false), "the pre-install snapshot loses")
        XCTAssertTrue(gate.mayWrite(gate.ticket(), setupInFlight: false), "a probe started afterwards writes")
    }

    func testNoProbeWritesWhileASetupIsRunning() {
        let gate = RelayStatusWriteGate()
        XCTAssertFalse(gate.mayWrite(gate.ticket(), setupInFlight: true))
    }
}
