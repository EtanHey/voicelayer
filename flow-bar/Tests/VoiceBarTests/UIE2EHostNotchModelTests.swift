import Foundation
@testable import VoiceBar
import VoiceBarUI
import XCTest

/// U2×U4 review (P2, U1's earlier finding): the QA host renders BarView from its own VoiceBarNotchPresentationModel,
/// which never received the operational envelope, so recording / speaking / transcribing fixtures moved the hit
/// geometry while the rendered notch stayed on the idle model. The host now feeds the model through the same
/// `AppDelegate.refreshNotchPresentationModel` the app uses, after every fixture.
@MainActor
final class UIE2EHostNotchModelTests: XCTestCase {
    func testAFixtureStateChangeUpdatesTheRenderedNotchPresentation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let host = UIE2EHost(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        let notchModel = VoiceBarNotchPresentationModel()
        host.bindNotchModel(notchModel)

        for (fixture, expected) in [
            ("recording", VoiceBarNotchVisualState.recording),
            ("transcribing", .compactStatus),
            ("speaking", .teleprompter),
            ("speaking-collapsed", .compactStatus),
        ] {
            host.model.fixture(fixture)
            XCTAssertEqual(notchModel.presentation.visualState, expected, fixture)
            // The rendered shell and the host's hit geometry come from the same inputs.
            XCTAssertEqual(notchModel.presentation.geometry.topWidth,
                           UIE2EHost.panelLayout(for: host.model.voice).presentation.geometry.topWidth,
                           accuracy: 0.001, "\(fixture): rendered vs hit geometry")
        }
    }

    func testTheAppAndTheQAHostShareOneEnvelopeFeed() {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        let model = VoiceBarNotchPresentationModel()
        state.handleEvent(["type": "state", "state": "recording", "mode": "ptt"])
        AppDelegate.refreshNotchPresentationModel(model, for: state)
        XCTAssertEqual(model.presentation.visualState, .recording)
        // Recording pause: a PTT take's left wing is Stop · Pause · ✕, the three-control width Lock already uses
        // on a VAD take (73.5 + 4 + 22 = 99.5 pt).
        // C7-W: the time/meter wing (102 pt on a flat display) is the wider of the two and sets both wings.
        XCTAssertEqual(model.presentation.geometry.leadingWingWidth, VoiceBarNotchContract.recordingTrailingWingWidth)
        XCTAssertEqual(model.presentation.geometry.trailingWingWidth, VoiceBarNotchContract.recordingTrailingWingWidth)
        XCTAssertGreaterThanOrEqual(VoiceBarNotchContract.recordingTrailingWingWidth,
                                    VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl)
        // One envelope feed: the QA host resolves the same geometry from the same state.
        let host = UIE2EHost.panelLayout(for: state).presentation.geometry
        XCTAssertEqual(host.leadingWingWidth, model.presentation.geometry.leadingWingWidth, accuracy: 0.001)
        XCTAssertEqual(host.trailingWingWidth, model.presentation.geometry.trailingWingWidth, accuracy: 0.001)
        XCTAssertEqual(host.topWidth, model.presentation.geometry.topWidth, accuracy: 0.001)
    }
}
