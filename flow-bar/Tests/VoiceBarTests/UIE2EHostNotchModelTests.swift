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
        // Recording reserves three left slots; each wing uses its own content and insets.
        XCTAssertEqual(model.presentation.geometry.leadingWingWidth, 88.5)
        XCTAssertEqual(model.presentation.geometry.trailingWingWidth, VoiceBarNotchContract.recordingTrailingWingWidth)
        XCTAssertGreaterThanOrEqual(VoiceBarNotchContract.recordingTrailingWingWidth,
                                    VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl)
        // One envelope feed: the QA host resolves the same geometry from the same state.
        let host = UIE2EHost.panelLayout(for: state).presentation.geometry
        XCTAssertEqual(host.leadingWingWidth, model.presentation.geometry.leadingWingWidth, accuracy: 0.001)
        XCTAssertEqual(host.trailingWingWidth, model.presentation.geometry.trailingWingWidth, accuracy: 0.001)
        XCTAssertEqual(host.topWidth, model.presentation.geometry.topWidth, accuracy: 0.001)
    }

    /// Real-screen capture r5, item o (B-O1): closing the hovered launcher to hidden drew the whole band about 180 pt
    /// right of the notch for the entire close. The QA host framed its window from a throwaway presentation model, which
    /// never holds the visible canvas through a close, while its BarView draws the bound model, which does: the window
    /// was placed for the core-only idle canvas and the shell landed `canvas.coreOriginX` (180 pt on the M1) right.
    ///
    /// Where the band sits on screen = the window's frame (the host's layout, anchored to the notch) + where the
    /// rendered model draws its core inside that window. At every layout pass of the close, after the hold releases,
    /// and when the band reopens mid-close, the drawn core must sit on the notch and the band where it was open.
    func testTheClosingBandStaysOnTheNotchForTheWholeClose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        setenv("VOICEBAR_UIE2E_GEOMETRY", "host", 1)
        defer { unsetenv("VOICEBAR_UIE2E_GEOMETRY") }
        let host = UIE2EHost(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        let geometry = try XCTUnwrap(host.hostGeometry, "fixture: the host anchors to this Mac's screen")
        var releases: [() -> Void] = []
        let notchModel = VoiceBarNotchPresentationModel()
        notchModel.scheduleClosingCanvasRelease = { _, work in releases.append(work) }
        host.bindNotchModel(notchModel)

        /// The drawn core's left edge and the drawn band's outer edges on screen.
        func drawn(_ band: VoiceBarNotchGeometry? = nil) -> (core: CGFloat, left: CGFloat, right: CGFloat) {
            let frame = host.panelLayout().windowFrame(anchoredTo: geometry)
            let rendered = notchModel.presentation
            let inside = VoiceBarPanelLayout.make(
                presentation: rendered,
                canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: rendered).canvasGeometry)
            let core = frame.minX + inside.visibleContentRect.minX + rendered.geometry.coreOriginX
            let wings = band ?? rendered.geometry
            return (core, core - wings.leadingWingWidth, core + wings.coreWidth + wings.trailingWingWidth)
        }
        /// The pointer arrives (the launcher opens) or leaves and the idle notch collapses (hidden), as in the capture.
        func hover(_ hovering: Bool) {
            host.model.voice.isHovering = hovering
            host.model.voice.isCollapsed = !hovering
            host.updatePillLayout()
        }
        let notch = geometry.housingFrame.minX

        hover(true)
        XCTAssertEqual(notchModel.presentation.visualState, .hoverLauncher)
        let openBand = notchModel.presentation.geometry
        let open = drawn()
        XCTAssertEqual(open.core, notch, accuracy: 0.01, "fixture: the open band's core sits on the notch")

        hover(false)
        XCTAssertEqual(notchModel.presentation.visualState, .idle)
        XCTAssertTrue(notchModel.presentation.holdsClosingCanvas, "fixture: the close holds the visible canvas")
        for pass in 0 ..< 3 {
            let closing = drawn(openBand)
            XCTAssertEqual(closing.core, notch, accuracy: 0.01, "close, layout pass \(pass): the core left the notch")
            XCTAssertEqual(closing.left, open.left, accuracy: 0.01, "close, pass \(pass): the band starts where it was open")
            XCTAssertEqual(closing.right, open.right, accuracy: 0.01, "close, pass \(pass): right edge")
            host.updatePillLayout()
        }
        releases.removeLast()()
        host.updatePillLayout()
        XCTAssertFalse(notchModel.presentation.holdsClosingCanvas)
        XCTAssertEqual(drawn().core, notch, accuracy: 0.01, "after the close lands: the core stays on the notch")

        // Interrupted: reopen mid-close, then the stale release arrives.
        hover(true)
        hover(false)
        XCTAssertEqual(drawn(openBand).core, notch, accuracy: 0.01, "second close: on the notch")
        hover(true)
        XCTAssertEqual(notchModel.presentation.visualState, .hoverLauncher)
        let reopened = drawn()
        XCTAssertEqual(reopened.core, notch, accuracy: 0.01, "reopened mid-close: on the notch")
        XCTAssertEqual(reopened.left, open.left, accuracy: 0.01, "reopened mid-close: where it was open")
        releases.forEach { $0() }
        host.updatePillLayout()
        XCTAssertEqual(drawn().core, notch, accuracy: 0.01, "a stale release moves nothing")
        XCTAssertEqual(drawn().left, open.left, accuracy: 0.01)

        // The closing shell keeps the open band's shape: the black core stays drawn until the band is removed (the
        // recorder saw a 153 pt gap while closing against 168 pt open, the glass under the core's edges uncovered).
        let shell = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/VoiceBarNotchView.swift"), encoding: .utf8)
        let core = try XCTUnwrap(shell.components(separatedBy: "private var fixedHardwareCore").dropFirst().first)
        XCTAssertTrue(core.prefix(600).contains("presentation.visualState != .idle || closing.band != nil"))
    }
}

