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

    func testBirthmarkGateFailsClosedWhenTheAuditRegionHasNoPixels() {
        XCTAssertFalse(
            VoiceBarNotchCaptureAudit.passesBirthmarkGate(
                baselinePixelCount: 10,
                auditPixelCount: 0,
                brightInteriorPixelCount: 10,
                largestBlobPixels: 0,
                blobPixelLimit: 150,
                settledContrast: 0
            )
        )
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

    func testWingContentSharpnessRejectsTheRoundTwoBlurSignature() {
        var brightness = Array(repeating: 30.0, count: 80 * 20)
        // The wing foreground has only a seven-point edge while the same-frame
        // menu glyph reference has the 133-point edge measured by Round 2 QA.
        fill(&brightness, width: 80, x: 15 ..< 25, y: 4 ..< 16, with: 37)
        fill(&brightness, width: 80, x: 55 ..< 65, y: 4 ..< 16, with: 163)
        let image = VoiceBarLumaImage(width: 80, height: 20, brightness: brightness)

        let result = VoiceBarNotchCaptureAudit.edgeSharpness(
            in: image,
            wingContentRect: CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.80),
            referenceGlyphRect: CGRect(x: 0.60, y: 0.10, width: 0.30, height: 0.80)
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.wingContentMaxGradient, 7, accuracy: 0.001)
        XCTAssertEqual(result.referenceGlyphMaxGradient, 133, accuracy: 0.001)
        XCTAssertGreaterThan(result.referenceToWingRatio, 2)
    }

    func testWingContentSharpnessPassesWhenItIsWithinTwoTimesTheMenuGlyphReference() {
        var brightness = Array(repeating: 30.0, count: 80 * 20)
        fill(&brightness, width: 80, x: 15 ..< 25, y: 4 ..< 16, with: 100)
        fill(&brightness, width: 80, x: 55 ..< 65, y: 4 ..< 16, with: 150)
        let image = VoiceBarLumaImage(width: 80, height: 20, brightness: brightness)

        let result = VoiceBarNotchCaptureAudit.edgeSharpness(
            in: image,
            wingContentRect: CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.80),
            referenceGlyphRect: CGRect(x: 0.60, y: 0.10, width: 0.30, height: 0.80)
        )

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.referenceToWingRatio, 120.0 / 70.0, accuracy: 0.001)
    }

    func testSharpnessGateRejectsAUniformlySoftHarnessEvenWhenTheRatioMatches() {
        var brightness = Array(repeating: 30.0, count: 80 * 20)
        fill(&brightness, width: 80, x: 15 ..< 25, y: 4 ..< 16, with: 44)
        fill(&brightness, width: 80, x: 55 ..< 65, y: 4 ..< 16, with: 44)
        let image = VoiceBarLumaImage(width: 80, height: 20, brightness: brightness)

        let result = VoiceBarNotchCaptureAudit.edgeSharpness(
            in: image,
            wingContentRect: CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.80),
            referenceGlyphRect: CGRect(x: 0.60, y: 0.10, width: 0.30, height: 0.80)
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.referenceToWingRatio, 1, accuracy: 0.001)
        XCTAssertLessThan(
            result.referenceGlyphMaxGradient,
            VoiceBarNotchCaptureAudit.minimumReferenceGlyphGradient
        )
    }

    func testCaptureVerifierRequiresBirthmarkIdleHoldAndRenderedSharpnessInputs() throws {
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
        XCTAssertTrue(source.contains("--sharpness-frame"))
        XCTAssertTrue(source.contains("--sharpness-wing-region"))
        XCTAssertTrue(source.contains("--sharpness-reference-region"))
        XCTAssertTrue(source.contains("BIRTHMARK"))
        XCTAssertTrue(source.contains("IDLE-HOLD"))
        XCTAssertTrue(source.contains("CURSOR-ABSENT"))
        XCTAssertTrue(source.contains("EDGE-SHARPNESS"))
        XCTAssertTrue(source.contains("--waveform-recording-frames"))
        XCTAssertTrue(source.contains("--waveform-transcribing-frames"))
        XCTAssertTrue(source.contains("--waveform-speaking-frames"))
        XCTAssertTrue(source.contains("--fade-leading-frame"))
        XCTAssertTrue(source.contains("--fade-trailing-frame"))
        XCTAssertTrue(source.contains("WAVEFORM-CENSUS"))
        XCTAssertTrue(source.contains("SEAM-FADE"))
        XCTAssertTrue(source.contains("GLYPH-CONTRAST-PARITY"))
        XCTAssertTrue(source.contains("COMPACT-PADDING"))
        XCTAssertTrue(source.contains("layerScales"))
    }

    func testWaveformCensusRejectsMissingSlotsAndOffCenterRecordingGrowth() {
        let speaking = waveformFrame(
            color: .blue,
            heights: [12, 16, 20, 24, 20, 16, 12],
            verticalOffset: 0
        )
        let clippedTranscribing = waveformFrame(
            color: .blue,
            heights: [12, 16, 20, 24, 20],
            verticalOffset: 0
        )
        let pinnedRecording = waveformFrame(
            color: .red,
            heights: [8, 8, 10, 10, 10, 8, 8],
            verticalOffset: -5
        )

        let result = VoiceBarNotchCaptureAudit.waveformCensus(
            recordingFrames: [pinnedRecording],
            transcribingFrames: [clippedTranscribing],
            speakingFrames: [speaking]
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.minimumTranscribingBarCount, 5)
        XCTAssertLessThan(result.recordingToSpeakingPeakRatio, 0.8)
        XCTAssertGreaterThan(result.recordingMaximumCenterDeviation, 2)
    }

    func testWaveformCensusPassesSevenCenteredPixelIdenticalSlots() {
        let speaking = waveformFrame(
            color: .blue,
            heights: [12, 16, 20, 24, 20, 16, 12],
            verticalOffset: 0
        )
        let transcribing = waveformFrame(
            color: .blue,
            heights: [10, 14, 18, 22, 18, 14, 10],
            verticalOffset: 0
        )
        let recording = waveformFrame(
            color: .red,
            heights: [10, 14, 18, 22, 18, 14, 10],
            verticalOffset: 0
        )

        let result = VoiceBarNotchCaptureAudit.waveformCensus(
            recordingFrames: [recording],
            transcribingFrames: [transcribing],
            speakingFrames: [speaking]
        )

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.minimumTranscribingBarCount, 7)
        XCTAssertGreaterThanOrEqual(result.recordingToSpeakingPeakRatio, 0.8)
        XCTAssertLessThanOrEqual(result.recordingMaximumCenterDeviation, 1)
        XCTAssertLessThanOrEqual(result.maximumSlotOffsetDelta, 1)
    }

    func testTranscribingCensusRequiresCompleteSevenBarsInAtLeastNinetyFivePercentOfFrames() {
        let full = waveformFrame(
            color: .blue,
            heights: [12, 16, 20, 24, 20, 16, 12],
            verticalOffset: 0
        )
        let clipped = waveformFrame(
            color: .blue,
            heights: [12, 16, 20, 24, 20],
            verticalOffset: 0
        )
        let recording = waveformFrame(
            color: .red,
            heights: [12, 16, 20, 24, 20, 16, 12],
            verticalOffset: 0
        )

        let passing = VoiceBarNotchCaptureAudit.waveformCensus(
            recordingFrames: [recording],
            transcribingFrames: Array(repeating: full, count: 19) + [clipped],
            speakingFrames: [full]
        )
        let failing = VoiceBarNotchCaptureAudit.waveformCensus(
            recordingFrames: [recording],
            transcribingFrames: Array(repeating: full, count: 18) + [clipped, clipped],
            speakingFrames: [full]
        )

        XCTAssertTrue(passing.passed)
        XCTAssertEqual(passing.transcribingCompleteFraction, 0.95, accuracy: 0.001)
        XCTAssertFalse(failing.passed)
        XCTAssertEqual(failing.transcribingCompleteFraction, 0.90, accuracy: 0.001)
    }

    func testCompactPaddingRejectsTheMeasuredNineTimesSpinnerAsymmetry() {
        var pixels = Array(
            repeating: VoiceBarRGB(red: 0.08, green: 0.08, blue: 0.10),
            count: 200 * 40
        )
        fillBlue(&pixels, width: 200, x: 3 ..< 9, y: 10 ..< 30)
        fillBlue(&pixels, width: 200, x: 127 ..< 173, y: 8 ..< 32)
        let image = VoiceBarRGBImage(width: 200, height: 40, pixels: pixels)

        let result = VoiceBarNotchCaptureAudit.compactPadding(
            in: image,
            leadingWingRect: CGRect(x: 0, y: 0, width: 0.25, height: 1),
            trailingWingRect: CGRect(x: 0.50, y: 0, width: 0.50, height: 1),
            backingScale: 2
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.spinnerLeadingPadding, 1.5, accuracy: 0.001)
        XCTAssertEqual(result.waveformLeadingPadding, 13.5, accuracy: 0.001)
    }

    func testCompactPaddingPassesWhenSpinnerAndWaveformInsetsMatch() {
        var pixels = Array(
            repeating: VoiceBarRGB(red: 0.08, green: 0.08, blue: 0.10),
            count: 200 * 40
        )
        fillBlue(&pixels, width: 200, x: 24 ..< 30, y: 10 ..< 30)
        fillBlue(&pixels, width: 200, x: 124 ..< 170, y: 8 ..< 32)
        let image = VoiceBarRGBImage(width: 200, height: 40, pixels: pixels)

        let result = VoiceBarNotchCaptureAudit.compactPadding(
            in: image,
            leadingWingRect: CGRect(x: 0, y: 0, width: 0.25, height: 1),
            trailingWingRect: CGRect(x: 0.50, y: 0, width: 0.50, height: 1),
            backingScale: 2
        )

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.paddingDelta, 0, accuracy: 0.001)
    }

    func testWingGlyphContrastMustMeetSameFrameNativeMenuGlyphContrast() {
        let darkGlass = VoiceBarRGB(red: 0.12, green: 0.13, blue: 0.16)
        let lightGlass = VoiceBarRGB(red: 0.84, green: 0.86, blue: 0.90)
        let white = VoiceBarRGB(red: 0.98, green: 0.98, blue: 0.99)
        let black = VoiceBarRGB(red: 0.04, green: 0.04, blue: 0.05)

        let darkPass = VoiceBarNotchCaptureAudit.glyphContrastParity(
            wingForegroundPixels: Array(repeating: white, count: 20),
            wingBackgroundPixels: Array(repeating: darkGlass, count: 20),
            referenceForegroundPixels: Array(repeating: white, count: 20),
            referenceBackgroundPixels: Array(repeating: darkGlass, count: 20)
        )
        let lightFail = VoiceBarNotchCaptureAudit.glyphContrastParity(
            wingForegroundPixels: Array(repeating: white, count: 20),
            wingBackgroundPixels: Array(repeating: lightGlass, count: 20),
            referenceForegroundPixels: Array(repeating: black, count: 20),
            referenceBackgroundPixels: Array(repeating: lightGlass, count: 20)
        )

        XCTAssertTrue(darkPass.passed)
        XCTAssertFalse(lightFail.passed)
        XCTAssertLessThan(lightFail.wingContrastRatio, lightFail.referenceContrastRatio)
    }

    func testSeamFadeRequiresVisibleGradualBlackToGlassProgression() {
        let gradual = VoiceBarLumaImage(
            width: 16,
            height: 4,
            brightness: (0 ..< 4).flatMap { _ in (0 ..< 16).map { Double($0) * 2 } }
        )
        let abrupt = VoiceBarLumaImage(
            width: 16,
            height: 4,
            brightness: (0 ..< 4).flatMap { _ in
                (0 ..< 16).map { $0 < 15 ? 0 : 30 }
            }
        )

        XCTAssertTrue(
            VoiceBarNotchCaptureAudit.seamFade(in: gradual, blackEdge: .leading).passed
        )
        XCTAssertFalse(
            VoiceBarNotchCaptureAudit.seamFade(in: abrupt, blackEdge: .leading).passed
        )
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

    private enum TestWaveformColor {
        case red
        case blue
    }

    private func waveformFrame(
        color: TestWaveformColor,
        heights: [Int],
        verticalOffset: Int
    ) -> VoiceBarRGBImage {
        let width = 46
        let height = 24
        var pixels = Array(
            repeating: VoiceBarRGB(red: 0.08, green: 0.08, blue: 0.10),
            count: width * height
        )
        for (index, barHeight) in heights.enumerated() {
            let minX = index * 7
            let centerY = height / 2 + verticalOffset
            let minY = max(0, centerY - barHeight / 2)
            let maxY = min(height, minY + barHeight)
            for y in minY ..< maxY {
                for x in minX ..< min(width, minX + 4) {
                    pixels[y * width + x] = color == .red
                        ? VoiceBarRGB(red: 0.95, green: 0.20, blue: 0.22)
                        : VoiceBarRGB(red: 0.20, green: 0.55, blue: 0.98)
                }
            }
        }
        return VoiceBarRGBImage(width: width, height: height, pixels: pixels)
    }

    private func fillBlue(
        _ pixels: inout [VoiceBarRGB],
        width: Int,
        x: Range<Int>,
        y: Range<Int>
    ) {
        for row in y {
            for column in x {
                pixels[row * width + column] = VoiceBarRGB(
                    red: 0.20,
                    green: 0.55,
                    blue: 0.98
                )
            }
        }
    }
}
