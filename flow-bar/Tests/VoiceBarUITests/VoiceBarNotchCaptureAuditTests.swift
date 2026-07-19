@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchCaptureAuditTests: XCTestCase {
    func testAnnotatedBirthmarkSignatureFailsTheNumericWingGate() {
        var brightness = Array(repeating: 197.0, count: 800 * 100)
        fill(&brightness, width: 800, x: 35 ..< 126, y: 20 ..< 83, with: 30)
        fill(&brightness, width: 800, x: 50 ..< 92, y: 50 ..< 70, with: 65)
        let image = VoiceBarLumaImage(width: 800, height: 100, brightness: brightness)

        let result = VoiceBarNotchCaptureAudit.birthmark(in: image, side: .leading)

        XCTAssertFalse(result.passed)
        XCTAssertGreaterThan(result.largestBlobPixels, 150)
        XCTAssertGreaterThan(result.settledContrast, 18)
    }

    func testUniformExpandedWingPassesTheBirthmarkGate() {
        var brightness = Array(repeating: 197.0, count: 800 * 100)
        fill(&brightness, width: 800, x: 35 ..< 126, y: 20 ..< 83, with: 30)
        let image = VoiceBarLumaImage(width: 800, height: 100, brightness: brightness)

        let result = VoiceBarNotchCaptureAudit.birthmark(in: image, side: .leading)

        XCTAssertTrue(result.passed)
        XCTAssertLessThanOrEqual(result.largestBlobPixels, 150)
        XCTAssertLessThan(result.settledContrast, 10)
    }

    func testBrightBirthmarkCannotEvadeTheNumericWingGate() {
        var brightness = Array(repeating: 197.0, count: 800 * 100)
        fill(&brightness, width: 800, x: 35 ..< 126, y: 20 ..< 83, with: 30)
        fill(&brightness, width: 800, x: 50 ..< 92, y: 50 ..< 70, with: 150)
        let image = VoiceBarLumaImage(width: 800, height: 100, brightness: brightness)

        let result = VoiceBarNotchCaptureAudit.birthmark(in: image, side: .leading)

        XCTAssertFalse(result.passed)
        XCTAssertGreaterThan(result.largestBlobPixels, 150)
        XCTAssertGreaterThan(result.settledContrast, 18)
    }

    func testSmallBrightSymbolStrokeDoesNotCountAsABirthmarkBlob() {
        var brightness = Array(repeating: 197.0, count: 800 * 100)
        fill(&brightness, width: 800, x: 35 ..< 126, y: 20 ..< 83, with: 30)
        fill(&brightness, width: 800, x: 65 ..< 68, y: 48 ..< 62, with: 245)
        let image = VoiceBarLumaImage(width: 800, height: 100, brightness: brightness)

        let result = VoiceBarNotchCaptureAudit.birthmark(in: image, side: .leading)

        XCTAssertTrue(result.passed)
        XCTAssertLessThanOrEqual(result.largestBlobPixels, 150)
        XCTAssertLessThan(result.settledContrast, 10)
    }

    func testIdleHoldRejectsAnyVisibilityToggleAcrossThreeSecondsAtSixtyFPS() {
        let flashing = Array(repeating: 84.0, count: 60)
            + Array(repeating: 197.0, count: 60)
            + Array(repeating: 84.0, count: 60)
        let stable = Array(repeating: 84.0, count: 180)

        let flashingResult = VoiceBarNotchCaptureAudit.idleHold(frameBrightnesses: flashing)
        let stableResult = VoiceBarNotchCaptureAudit.idleHold(frameBrightnesses: stable)

        XCTAssertFalse(flashingResult.passed)
        XCTAssertEqual(flashingResult.visibilityTransitions, 2)
        XCTAssertTrue(stableResult.passed)
        XCTAssertEqual(stableResult.visibilityTransitions, 0)
    }

    func testIdleHoldRequiresFrameMatchedProofThatCursorStayedOutsideTheSurface() {
        let retentionRect = CGRect(x: 300, y: 0, width: 200, height: 60)
        let cursorAbsent = VoiceBarNotchCaptureAudit.cursorAbsent(
            frameCount: 180,
            cursorPositions: Array(repeating: CGPoint(x: 100, y: 200), count: 180),
            retentionRect: retentionRect
        )
        let cursorEntered = VoiceBarNotchCaptureAudit.cursorAbsent(
            frameCount: 180,
            cursorPositions: Array(repeating: CGPoint(x: 350, y: 20), count: 180),
            retentionRect: retentionRect
        )
        let incompleteProof = VoiceBarNotchCaptureAudit.cursorAbsent(
            frameCount: 180,
            cursorPositions: Array(repeating: CGPoint(x: 100, y: 200), count: 179),
            retentionRect: retentionRect
        )

        XCTAssertTrue(cursorAbsent.passed)
        XCTAssertEqual(cursorAbsent.insideFrameCount, 0)
        XCTAssertFalse(cursorEntered.passed)
        XCTAssertEqual(cursorEntered.insideFrameCount, 180)
        XCTAssertFalse(incompleteProof.passed)
    }

    func testCaptureVerifierRequiresBirthmarkAndIdleHoldInputs() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/NotchCaptureContrastVerifier/main.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("--expanded-strip"))
        XCTAssertTrue(source.contains("--idle-hold-frames"))
        XCTAssertTrue(source.contains("--idle-hold-cursor-proof"))
        XCTAssertTrue(source.contains("BIRTHMARK"))
        XCTAssertTrue(source.contains("IDLE-HOLD"))
        XCTAssertTrue(source.contains("CURSOR-ABSENT"))
    }

    private func fill(
        _ brightness: inout [Double],
        width: Int,
        x: Range<Int>,
        y: Range<Int>,
        with value: Double
    ) {
        for row in y {
            for column in x {
                brightness[row * width + column] = value
            }
        }
    }
}
