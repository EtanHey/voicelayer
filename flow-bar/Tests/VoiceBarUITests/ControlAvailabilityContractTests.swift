import XCTest
@testable import VoiceBarUI

final class ControlAvailabilityContractTests: XCTestCase {
    private var ready: ControlAvailabilityFacts {
        var f = ControlAvailabilityFacts()
        f.connected = true; f.callbackAvailable = true; f.capable = true
        return f
    }

    func testDrainAndUnknownAdmitVoiceButHealthyPreparedAndCommittedRefuseIt() {
        for gate in [ControlVoiceGate.open, .draining, .unknown, .prepared, .committed] {
            var f = ready; f.gate = gate
            XCTAssertEqual(VoiceControlAvailability.evaluate(.record, f).isEnabled, gate.permitsNewVoice)
            XCTAssertTrue(VoiceControlAvailability.evaluate(.navigate, f).isEnabled)
            XCTAssertTrue(VoiceControlAvailability.evaluate(.checkUpdates, f).isEnabled)
        }
    }

    func testBOverAAndDrainKeepEmergencyAndNavigationReachable() {
        var f = ready; f.unfinished = true
        XCTAssertTrue(VoiceControlAvailability.evaluate(.record, f).isEnabled)
        f.draining = true
        XCTAssertTrue(VoiceControlAvailability.evaluate(.record, f).isEnabled)
        f.queued = true
        XCTAssertFalse(VoiceControlAvailability.evaluate(.record, f).isEnabled)
        f.connected = false; f.gate = .committed; f.pending = true
        for control in [VoiceControl.stop, .cancel, .pairedRelease, .navigate, .copy] {
            XCTAssertTrue(VoiceControlAvailability.evaluate(control, f).isEnabled, control.rawValue)
        }
    }

    func testArchivesShareOneRefusalAndHoldIsSeparateFromPause() {
        var f = ready; f.capturing = true; f.unfinished = true
        let results = [VoiceControl.archiveDrawer, .archiveWindow, .archiveLatest].map { VoiceControlAvailability.evaluate($0, f) }
        XCTAssertEqual(Set(results.compactMap(\.reason)).count, 1)
        for c in [VoiceControl.recordingHold, .recordingPause] {
            XCTAssertTrue(VoiceControlAvailability.evaluate(c, f).isEnabled)
            f.pending = true
            XCTAssertEqual(VoiceControlAvailability.evaluate(c, f).reason, "Waiting for acknowledgement")
            f.pending = false
        }
        XCTAssertEqual(VoiceControlAvailability.evaluate(.microphoneEdit, f).reason, "Finish recording to change microphones")
        XCTAssertFalse(VoiceControlAvailability.evaluate(.hide, f).isEnabled)
    }

    func testExplanationIsAcceptedWithoutClaimingMediaOrDeletion() {
        var f = ready; f.gate = .prepared
        let key = VoiceControlAvailability.evaluate(.readSelectionKey, f)
        XCTAssertTrue(key.isEnabled); XCTAssertEqual(key.outcome, .explain("An update owns VoiceBar"))
        XCTAssertFalse(VoiceControlAvailability.evaluate(.readClipboard, f).isEnabled)
        f.ownerReason = "Choose another recognizer first"
        XCTAssertEqual(VoiceControlAvailability.evaluate(.requestDelete, f).outcome, .explain(f.ownerReason!))
    }

    func testSelectedNeighborIdentityAndDataRefusalsHaveBothReasonChannels() {
        var f = ready; f.selectedHealthy = true; f.neighborAvailable = false
        for c in [VoiceControl.selectRecognizer, .previousRead] {
            let a = VoiceControlAvailability.evaluate(c, f)
            XCTAssertFalse(a.isEnabled); XCTAssertNotNil(a.reason)
            XCTAssertEqual(a.tooltip, a.accessibilityHint)
        }
        f.identityCurrent = false
        XCTAssertFalse(VoiceControlAvailability.evaluate(.seek, f).isEnabled)
        f.identityCurrent = true; f.dataAvailable = false
        XCTAssertFalse(VoiceControlAvailability.evaluate(.preview, f).isEnabled)
        f.visible = false
        XCTAssertFalse(VoiceControlAvailability.evaluate(.preview, f).isVisible)
    }
}
