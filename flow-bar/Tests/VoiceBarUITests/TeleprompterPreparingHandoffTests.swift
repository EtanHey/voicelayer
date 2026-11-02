@testable import VoiceBarUI
import XCTest

/// R2-04 (QA 2026-11-02 recording 2, frame 183 @ 18.2 s): a faded "Preparing speech…" was drawn over the
/// teleprompter's second line as playback started. The status and the text now hand off in sequence; the
/// order-of-events proof is formal/teleprompter-handoff (Old FAIL NoOverlap, Fixed PASS). These are supplemental to
/// the mounted, frame-sampled TeleprompterPreparingHandoffRenderTests.
final class TeleprompterPreparingHandoffTests: XCTestCase {
    private typealias Handoff = TeleprompterPreparingHandoff

    func testTheLeavingViewIsGoneBeforeTheEnteringViewAppears() {
        XCTAssertGreaterThanOrEqual(Handoff.enterDelay, Handoff.exitDuration + 1.0 / 60,
                                    "one clear 60 Hz frame between the two")
        // Every millisecond of the handoff: never both above zero opacity.
        for millisecond in 0 ... 600 {
            let elapsed = Double(millisecond) / 1000
            let leaving = Handoff.opacity(isEntering: false, elapsed: elapsed)
            let entering = Handoff.opacity(isEntering: true, elapsed: elapsed)
            XCTAssertFalse(leaving > 0 && entering > 0, "overlap at \(millisecond) ms: \(leaving) / \(entering)")
        }
        XCTAssertEqual(Handoff.opacity(isEntering: false, elapsed: 0), 1)
        XCTAssertEqual(Handoff.opacity(isEntering: false, elapsed: Handoff.exitDuration), 0)
        XCTAssertEqual(Handoff.opacity(isEntering: true, elapsed: Handoff.enterDelay), 0)
        XCTAssertEqual(Handoff.opacity(isEntering: true, elapsed: Handoff.enterDelay + Handoff.enterDuration), 1)
        XCTAssertLessThanOrEqual(Handoff.enterDelay + Handoff.enterDuration, 0.3, "the reader waits under 300 ms")
    }

    /// The old symmetric 0.2 s crossfade, sampled the same way, overlapped for its whole duration.
    func testTheOldCrossfadeOverlapped() {
        let overlappingFrames = (1 ..< 12).filter { frame in
            let t = Double(frame) / 60
            return (1 - t / 0.2) > 0 && (t / 0.2) > 0
        }
        XCTAssertEqual(overlappingFrames.count, 11, "regression witness for the R2-04 frame")
    }

    /// Both branches of the teleprompter body must use the handoff; a plain `.opacity` crossfade on either
    /// side brings the overlap back.
    func testBothTeleprompterBodyBranchesUseTheHandoff() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/BarView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func notchTeleprompterBody(text: String)"))
        let end = try XCTUnwrap(source.range(of: "private var notchTeleprompterControls", range: start.upperBound ..< source.endIndex))
        let body = source[start.upperBound ..< end.lowerBound]
        XCTAssertEqual(body.components(separatedBy: ".transition(TeleprompterPreparingHandoff.transition)").count - 1, 2)
        XCTAssertFalse(body.contains(".transition(.opacity)"))
        // The insertion transitions alone did not hold the arriving side back (review round 2); the gate does,
        // in both directions. Rendered proof: TeleprompterPreparingHandoffRenderTests.
        XCTAssertTrue(body.contains("preparingHandoff.showsStatus(isPreparing: state.isPreparingSpeech)"))
        XCTAssertTrue(body.contains("preparingHandoff.showsText(isPreparing: state.isPreparingSpeech)"))
    }
}
