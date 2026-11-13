import Foundation
@testable import VoiceBar
import VoiceBarUI
import XCTest

/// 2.4 #813 (REVIEW-813 fixture contract): Lane A's 22 `qa-fixture-2.4-*` providers. Each puts the QA app into the
/// real product state its E2E flow starts from and ends with the receipt `fixture:2.4-<name>`. No device, no audio.
@MainActor
final class UIE2ELaneAFixtureTests: XCTestCase {
    private var root: URL!

    private func makeHost() throws -> UIE2EHost {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let host = UIE2EHost(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        host.bindNotchModel(VoiceBarNotchPresentationModel())
        host.notchSurface.log = { _ in }
        host.model.onNotchSurface = { host.notchSurface.send($0) }
        return host
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    func testTheContractsTwentyTwoProvidersExistOnce() {
        let names = UIE2EModel.laneAFixtures24
        XCTAssertEqual(names.count, 22)
        XCTAssertEqual(Set(names).count, 22)
        for required in ["settings", "history", "recording", "paste-failed", "queued", "typed-feedback",
                         "microphone-priority", "permission-revoked", "history-expanded", "history-20",
                         "recording-long-microphone-name", "record-after-record", "history-dictation", "history-ask",
                         "history-speak", "tooltips-launcher", "tooltips-recording", "tooltips-transcribing",
                         "tooltips-speaking", "tooltips-readback", "tooltips-history", "tooltips-settings"] {
            XCTAssertTrue(names.contains(required), required)
        }
    }

    func testEveryProviderEndsWithItsReceipt() throws {
        let host = try makeHost()
        for name in UIE2EModel.laneAFixtures24 {
            host.model.fixture("2.4-" + name)
            XCTAssertEqual(host.model.events.last, "fixture:2.4-" + name)
        }
    }

    func testRecordingProvidersPresentARealTakeAndExposeItsIdentity() throws {
        let host = try makeHost()
        host.model.fixture("2.4-recording")
        XCTAssertEqual(host.model.voice.mode, .recording)
        XCTAssertEqual(host.model.recordingTakeID, "qa-take-1")
        host.model.fixture("2.4-record-after-record")
        XCTAssertEqual(host.model.voice.mode, .recording)
        XCTAssertEqual(host.model.voice.queueDepth, 1, "take 1 still processing behind take 2")
        XCTAssertEqual(host.model.recordingTakeID, "qa-take-2")
        host.model.fixture("2.4-settings")
        XCTAssertNil(host.model.recordingTakeID, "a non-recording provider clears the take")
    }

    func testHistoryProvidersOpenTheNotchDrawerAtTheirDetent() throws {
        let host = try makeHost()
        host.model.fixture("2.4-history-20")
        XCTAssertEqual(host.model.voice.recentTranscriptionEntries.count, 20)
        XCTAssertEqual(host.notchSurface.drawer, .history(.collapsed))
        host.model.fixture("2.4-history-expanded")
        XCTAssertEqual(host.notchSurface.drawer, .history(.expanded))
        host.model.fixture("2.4-tooltips-settings")
        XCTAssertEqual(host.notchSurface.drawer, .settings(.general), "Settings in the notch: its controls are pill controls")
        host.model.fixture("2.4-tooltips-launcher")
        XCTAssertNil(host.notchSurface.drawer)
    }

    func testSettingsProvidersOpenTheRealSettingsSpot() throws {
        let host = try makeHost()
        var shown = 0
        host.model.onShowSettings = { shown += 1 }
        host.model.fixture("2.4-permission-revoked")
        XCTAssertEqual(host.model.missingPermissions, [.accessibility], "one permission revoked")
        XCTAssertEqual(host.model.voice.setupMissingPermissions, [.accessibility])
        XCTAssertEqual(host.model.tab, .general)
        XCTAssertEqual(host.model.focus, .permissions)
        host.model.fixture("2.4-microphone-priority")
        XCTAssertEqual(host.model.focus, .microphonePriority)
        XCTAssertGreaterThanOrEqual(host.model.microphoneOrder.count, 2)
        XCTAssertEqual(host.model.missingPermissions, [.accessibility, .inputMonitoring], "baseline restored")
        host.model.fixture("2.4-history-ask")
        XCTAssertEqual(host.model.tab, .history)
        XCTAssertEqual(shown, 3)
    }

    func testFeedbackProvidersShowTheProductCopy() throws {
        let host = try makeHost()
        host.model.fixture("2.4-paste-failed")
        XCTAssertEqual(host.model.voice.confirmationText, "Paste failed. Click the text field and press Shift+F5.")
        host.model.fixture("2.4-typed-feedback")
        XCTAssertEqual(host.model.voice.confirmationText, "Typed")
        host.model.fixture("2.4-tooltips-transcribing")
        XCTAssertEqual(host.model.voice.mode, .transcribing)
    }
}
