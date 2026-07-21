import AppKit
import Darwin
import SwiftUI
@testable import VoiceBarUI
import XCTest

final class WaveformViewTests: XCTestCase {
    private final class NoOpCommandRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    func testSharedWaveformViewportFitsExactlySevenBarsWithoutCompression() {
        XCTAssertEqual(WaveformLayout.barCount, 7)
        XCTAssertEqual(WaveformLayout.barWidth, 4)
        XCTAssertEqual(WaveformLayout.barSpacing, 3)
        XCTAssertEqual(WaveformLayout.viewportWidth, 46)
        XCTAssertEqual(WaveformLayout.viewportHeight, 24)
        XCTAssertEqual(
            CGFloat(WaveformLayout.barCount) * WaveformLayout.barWidth
                + CGFloat(WaveformLayout.barCount - 1) * WaveformLayout.barSpacing,
            WaveformLayout.viewportWidth
        )
    }

    func testEveryNotchWaveformUsesOneCoreGapViewportAndOuterInset() {
        XCTAssertEqual(WaveformLayout.coreGap, 24)
        XCTAssertEqual(WaveformLayout.viewportWidth, 46)
        XCTAssertEqual(WaveformLayout.viewportHeight, 24)
        XCTAssertEqual(WaveformLayout.outerInset, 8)
        XCTAssertEqual(WaveformLayout.leadingX(coreMaxX: 220), 244)
    }

    func testWaveformHostsUseTheSameCoreRelativePlacementInEveryState() {
        let material = VoiceBarNotchContract.material
        let processing = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .transcribing,
                statusText: "Transcribing"
            )
        )
        let expectedProcessingWidth = WaveformLayout.coreGap +
            material.waveformSlotWidth + material.compactControlSpacing +
            material.compactControlSize + WaveformLayout.outerInset

        XCTAssertEqual(
            processing.geometry.trailingWingWidth,
            expectedProcessingWidth,
            "the cancel control follows the shared waveform without an invisible leading reserve"
        )

        let calibratedInset = VoiceBarNotchContract.hardwareHorizontalCalibrationInset
        let speaking = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .speaking,
                hasTeleprompterText: true,
                statusText: "Speaking",
                visibleCoreOcclusionInset: calibratedInset
            )
        )
        let speakingSlot = material.wingContentLayout(
            for: .trailing,
            state: .teleprompter,
            visibleCoreOcclusionInset: calibratedInset
        )

        XCTAssertEqual(speakingSlot.coreInset, WaveformLayout.coreGap)
        XCTAssertEqual(speakingSlot.outerInset, WaveformLayout.outerInset)
        XCTAssertEqual(
            speaking.geometry.trailingWingWidth,
            speakingSlot.coreInset + material.waveformSlotWidth + speakingSlot.outerInset,
            "the live speaking waveform keeps the shared core gap when calibration changes"
        )
    }

    func testOneStateDrivenNotchWaveformFeedsTheSharedRenderer() throws {
        let waveformSource = try waveformViewSource()
        let barSource = try barViewSource()
        let component = try XCTUnwrap(
            waveformSource.components(separatedBy: "public struct VoiceBarNotchWaveform").dropFirst().first
        )

        XCTAssertEqual(component.components(separatedBy: "WaveformView(").count - 1, 1)
        XCTAssertEqual(barSource.components(separatedBy: "VoiceBarNotchWaveform(").count - 1, 1)
        XCTAssertFalse(barSource.contains("Color.clear\n                    .frame"))
        XCTAssertFalse(barSource.contains("horizontalPadding:"))
        XCTAssertTrue(barSource.contains("case .speaking:\n            HStack"))
    }

    @MainActor
    func testRenderedProcessingAndSpeakingWaveformsShareTheCoreGap() throws {
        let calibratedInset = VoiceBarNotchContract.hardwareHorizontalCalibrationInset

        let processingState = VoiceState()
        processingState.mode = .transcribing
        processingState.isConnected = true
        processingState.isCollapsed = false
        let processingPresentation = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .transcribing,
                statusText: "Transcribing",
                visibleCoreOcclusionInset: calibratedInset
            )
        )

        let speakingState = VoiceState()
        speakingState.isConnected = true
        speakingState.isCollapsed = false
        speakingState.handleEvent(
            [
                "type": "state",
                "state": "speaking",
                "text": "Centered waveform verification",
            ],
            playbackAmplitude: PlaybackAmplitudeEnvelope(
                source: .decodedRMS,
                sampleIntervalMilliseconds: 50,
                samples: Array(repeating: 0.8, count: 200)
            )
        )
        let speakingPresentation = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .speaking,
                hasTeleprompterText: true,
                statusText: "Speaking",
                visibleCoreOcclusionInset: calibratedInset
            )
        )

        var renderedCoreGaps: [Int] = []
        for (state, presentation, label) in [
            (processingState, processingPresentation, "processing"),
            (speakingState, speakingPresentation, "speaking"),
        ] {
            let image = try renderBar(
                state: state,
                presentation: presentation
            )
            let scale = CGFloat(image.width) / presentation.geometry.totalWidth
            let wingMinX = Int(
                ((presentation.geometry.coreOriginX + presentation.geometry.coreWidth) * scale)
                    .rounded()
            )
            let wingMaxX = Int(
                ((presentation.geometry.coreOriginX + presentation.geometry.coreWidth +
                        presentation.geometry.trailingWingWidth) * scale).rounded()
            )
            let blueBounds = try XCTUnwrap(
                blueHorizontalBounds(
                    in: image,
                    xRange: wingMinX ..< min(wingMaxX, image.width)
                ),
                "expected blue waveform pixels in the \(label) trailing wing"
            )
            let leadingPadding = blueBounds.lowerBound - wingMinX
            renderedCoreGaps.append(leadingPadding)
            XCTAssertEqual(
                leadingPadding,
                Int((WaveformLayout.coreGap * scale).rounded()),
                accuracy: max(2, Int((2 * scale).rounded())),
                "\(label) waveform must begin at the shared core-relative gap"
            )
        }
        XCTAssertEqual(renderedCoreGaps[0], renderedCoreGaps[1], accuracy: 2)
    }

    func testEnvelopeFollowerUsesLightAttackAndA200MillisecondRelease() {
        var envelope = WaveformEnvelopeFollower()

        XCTAssertEqual(envelope.sample(rawLevel: 0, at: 0), 0)
        let firstSpeechFrame = envelope.sample(rawLevel: 1, at: 0.016)
        XCTAssertGreaterThan(firstSpeechFrame, 0)
        XCTAssertLessThan(firstSpeechFrame, 1)
        XCTAssertGreaterThan(envelope.sample(rawLevel: 1, at: 0.080), 0.9)

        let firstSilentFrame = envelope.sample(rawLevel: 0, at: 0.097)
        XCTAssertGreaterThan(
            firstSilentFrame,
            0.5,
            "silence must retain a visible tail after one 120fps/60fps frame"
        )
        XCTAssertGreaterThan(envelope.sample(rawLevel: 0, at: 0.197), 0)
        XCTAssertGreaterThan(envelope.sample(rawLevel: 0, at: 0.247), 0)
        XCTAssertEqual(envelope.sample(rawLevel: 0, at: 0.280), 0, accuracy: 0.0001)
    }

    func testEnvelopeReleaseDurationDoesNotShrinkForQuietUtteranceEndings() {
        for startingLevel in [0.2, 0.4, 1.0] {
            var envelope = WaveformEnvelopeFollower()
            XCTAssertEqual(envelope.sample(rawLevel: startingLevel, at: 0), startingLevel)
            XCTAssertGreaterThan(envelope.sample(rawLevel: 0, at: 0.150), 0)
            XCTAssertGreaterThan(envelope.sample(rawLevel: 0, at: 0.199), 0)
            XCTAssertEqual(envelope.sample(rawLevel: 0, at: 0.200), 0, accuracy: 0.0001)
        }
    }

    func testEnvelopeFollowerSmoothsSpeechWithoutDependingOnFrameRate() {
        var sixtyFPS = WaveformEnvelopeFollower()
        var oneTwentyFPS = WaveformEnvelopeFollower()
        _ = sixtyFPS.sample(rawLevel: 0, at: 0)
        _ = oneTwentyFPS.sample(rawLevel: 0, at: 0)

        for frame in 1 ... 6 {
            _ = sixtyFPS.sample(rawLevel: 0.8, at: Double(frame) / 60)
        }
        for frame in 1 ... 12 {
            _ = oneTwentyFPS.sample(rawLevel: 0.8, at: Double(frame) / 120)
        }

        XCTAssertEqual(sixtyFPS.level, oneTwentyFPS.level, accuracy: 0.0001)
        XCTAssertGreaterThan(sixtyFPS.level, 0.75)
        XCTAssertLessThanOrEqual(sixtyFPS.level, 0.8)
    }

    func testRecordingSpeechUsesFullGainGoldMapping() throws {
        let level = 0.82
        let time = 0.63
        let listening = WaveformMetrics.audioDrivenLevels(
            level: level,
            time: time,
            barCount: 7,
            isListening: true
        )
        let speech = WaveformMetrics.audioDrivenLevels(
            level: level,
            time: time,
            barCount: 7,
            isListening: false
        )

        XCTAssertGreaterThan(try XCTUnwrap(speech.max()), try XCTUnwrap(listening.max()))
        let independentFullGainPeak = (0 ..< 7).map {
            m1GoldLevel(level: level, time: time, index: $0, barCount: 7)
        }.max()
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(speech.max()),
            try XCTUnwrap(independentFullGainPeak) * 0.8
        )
    }

    func testAudioDrivenFormulaMatchesM1GoldForEveryBar() {
        for level in [0.1, 0.43, 0.8, 1.0] {
            for time in [0.0, 0.42, 1.7] {
                let actual = WaveformMetrics.audioDrivenLevels(
                    level: level,
                    time: time,
                    barCount: 7,
                    isListening: false
                )

                for index in 0 ..< 7 {
                    XCTAssertEqual(
                        actual[index],
                        m1GoldLevel(level: level, time: time, index: index, barCount: 7),
                        accuracy: 0.000_000_1,
                        "bar \(index), level \(level), time \(time) must equal 5beaf34"
                    )
                }
            }
        }
    }

    func testListeningUsesM1GoldDampingBeforeTheFormula() {
        let level = 0.72
        let time = 0.63
        let actual = WaveformMetrics.audioDrivenLevels(
            level: level,
            time: time,
            barCount: 7,
            isListening: true
        )

        for index in 0 ..< 7 {
            XCTAssertEqual(
                actual[index],
                m1GoldLevel(
                    level: level * 0.7,
                    time: time,
                    index: index,
                    barCount: 7
                ),
                accuracy: 0.000_000_1
            )
        }
    }

    func testSharedEnvelopeUsesBoundedAttackAndA200MillisecondRelease() {
        XCTAssertEqual(WaveformMetrics.envelopeAttackDuration, 0.08, accuracy: 0.0001)
        XCTAssertEqual(WaveformMetrics.envelopeReleaseDuration, 0.20, accuracy: 0.0001)
        XCTAssertEqual(WaveformMetrics.listeningDamping, 0.7, accuracy: 0.0001)
        XCTAssertEqual(
            WaveformMetrics.envelopeTransitionDuration(from: 0.2, to: 0.8),
            0.08,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WaveformMetrics.envelopeTransitionDuration(from: 0.8, to: 0.2),
            0.20,
            accuracy: 0.0001
        )
    }

    func testTruthfulSilenceIsExactlyFlatDespiteGoldShimmer() {
        for level in [nil, 0] as [Double?] {
            for time in [0.0, 0.42, 1.0] {
                XCTAssertEqual(
                    WaveformMetrics.audioDrivenLevels(
                        level: level,
                        time: time,
                        barCount: 7,
                        isListening: false
                    ),
                    Array(repeating: 0, count: 7)
                )
            }
        }
    }

    func testGoldenRatioShimmerIsPerBarAndNotAChronologicalSweep() {
        let first = WaveformMetrics.audioDrivenLevels(
            level: 0.6,
            time: 0.42,
            barCount: 7,
            isListening: false
        )
        let sameCurrentMagnitude = WaveformMetrics.audioDrivenLevels(
            level: 0.6,
            time: 0.42,
            barCount: 7,
            isListening: false
        )

        XCTAssertEqual(first, sameCurrentMagnitude)
        XCTAssertTrue(zip(first.prefix(3), first.suffix(3).reversed()).contains { pair in
            abs(pair.0 - pair.1) > 0.01
        })

        let averages = (0 ..< 7).map { index in
            let samples = stride(from: 0.0, through: 4.0, by: 0.05).map { time in
                WaveformMetrics.audioDrivenLevels(
                    level: 0.6,
                    time: time,
                    barCount: 7,
                    isListening: false
                )[index]
            }
            return samples.reduce(0, +) / Double(samples.count)
        }
        XCTAssertGreaterThan(averages[3], averages[0])
        XCTAssertGreaterThan(averages[3], averages[6])
    }

    func testProcessingFormulaMatchesM1Gold() {
        for time in [0.0, 0.42, 1.7] {
            let actual = WaveformMetrics.processingLevels(time: time, barCount: 7)
            for index in 0 ..< 7 {
                XCTAssertEqual(
                    actual[index],
                    m1GoldProcessingLevel(time: time, index: index, barCount: 7),
                    accuracy: 0.000_000_1
                )
            }
        }
    }

    func testRecordingSourceMapsObservedRoomToneToSilence() {
        let roomTone = AudioLevelMonitor.normalizeAveragePower(-50)

        XCTAssertEqual(WaveformMetrics.recordingLevel(from: nil), 0)
        XCTAssertEqual(WaveformMetrics.recordingLevel(from: roomTone), 0)
        XCTAssertGreaterThan(
            WaveformMetrics.recordingLevel(from: AudioLevelMonitor.normalizeAveragePower(-20)),
            0
        )
    }

    func testRecordingSourcePreservesOrderingAboveFixedSilenceFloor() {
        let quiet = WaveformMetrics.recordingLevel(
            from: AudioLevelMonitor.normalizeAveragePower(-40)
        )
        let loud = WaveformMetrics.recordingLevel(
            from: AudioLevelMonitor.normalizeAveragePower(-10)
        )

        XCTAssertGreaterThan(quiet, 0)
        XCTAssertGreaterThan(loud, quiet)
    }

    func testBarViewFeedsCurrentTruthSourcesIntoOneGoldFormula() throws {
        let source = try barViewSource()

        XCTAssertTrue(source.contains("recordingLevel: { state.recordingWaveformLevel }"))
        XCTAssertTrue(source.contains("isListening: !state.speechDetected"))
        XCTAssertEqual(source.components(separatedBy: "state.playbackAudioLevel()").count - 1, 1)
        XCTAssertFalse(source.contains("recordingWaveformLevels"))
        XCTAssertFalse(source.contains("playbackWaveformLevels"))
        XCTAssertFalse(source.contains("centerOutHistory"))
    }

    func testTranscribingKeepsOneGoldWaveformInTheRecordingWingAndMorphsTheIndicator() throws {
        let source = try barViewSource()
        let leadingCompactStatusBranch = source
            .components(separatedBy: "case .compactStatus:")
            .dropFirst()
            .first?
            .components(separatedBy: "case .teleprompter:")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingBranch = source
            .components(separatedBy: "private var notchTrailingContent")
            .dropFirst()
            .first?
            .components(separatedBy: "private var notchCompactStatusContent")
            .first

        XCTAssertTrue(leadingCompactStatusBranch?.contains("if state.mode == .transcribing") == true)
        XCTAssertTrue(leadingCompactStatusBranch?.contains("ProcessingSpinner()") == true)
        XCTAssertFalse(leadingCompactStatusBranch?.contains("statusLabel") == true)
        XCTAssertFalse(leadingCompactStatusBranch?.contains("WaveformView(") == true)
        XCTAssertTrue(trailingBranch?.contains("notchWaveform") == true)
        XCTAssertTrue(source.contains("private var notchWaveform"))
        XCTAssertTrue(source.contains("VoiceBarNotchWaveform("))
    }

    func testEveryWaveformModeUsesTheSharedFixedViewport() throws {
        let source = try waveformViewSource()

        XCTAssertTrue(source.contains(".frame(width: WaveformLayout.viewportWidth"))
        XCTAssertTrue(source.contains("height: WaveformLayout.viewportHeight"))
        XCTAssertTrue(source.contains(".fixedSize(horizontal: true, vertical: true)"))
        XCTAssertFalse(
            source
                .components(separatedBy: ".fixedSize(horizontal: true, vertical: true)")
                .dropFirst()
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix(".clipped()") == true,
            "the shared viewport must reserve bounds without clipping full-height bars or their antialiasing"
        )
        XCTAssertTrue(source.contains("WaveformBarGeometry.frame("))
        XCTAssertTrue(source.contains("roundedRect: frame"))
    }

    func testProcessingAndAudioModesShareOneStableBarRendererHierarchy() throws {
        let source = try waveformViewSource()

        XCTAssertTrue(source.contains("private func normalizedLevels(time:"))
        XCTAssertEqual(
            source.components(separatedBy: "WaveformBars(").count - 1,
            1,
            "recording, processing, and speaking must feed one permanently mounted bar renderer"
        )
        XCTAssertFalse(
            source.contains("private struct AudioDrivenBars"),
            "a mode-specific wrapper changes the SwiftUI hierarchy during recording-to-processing"
        )
    }

    func testAudioDrivenWaveformSamplesItsTruthSourceInsideTheAnimationTimeline() throws {
        let source = try waveformViewSource()
        let timeline = try XCTUnwrap(
            source
                .components(separatedBy: "TimelineView(.animation(minimumInterval: 1.0 / 60.0))")
                .dropFirst()
                .first?
                .components(separatedBy: ".frame(width: WaveformLayout.viewportWidth")
                .first
        )

        XCTAssertTrue(
            timeline.contains("rawLevel: currentLevel()"),
            "the animation tick must resample time-derived playback amplitude"
        )
    }

    func testWaveformBarsRenderAsOneAtomicCanvasInsteadOfIndependentSubviews() throws {
        let source = try waveformViewSource()
        let barsStart = try XCTUnwrap(source.range(of: "private struct WaveformBars"))
        let bars = source[barsStart.lowerBound ..< source.endIndex]

        XCTAssertTrue(
            bars.contains("Canvas { context, _ in"),
            "glass must composite the waveform as one atomic raster surface"
        )
        XCTAssertFalse(
            bars.contains("ForEach("),
            "individual bar views can be independently relaid out or clipped during the compact-state morph"
        )
    }

    func testBarGeometryPinsEveryBarCenterAndSpreadsBottomsAtAmplitudePeak() {
        let levels = [0.15, 0.35, 0.65, 1.0, 0.65, 0.35, 0.15]
        let frames = levels.enumerated().map { index, level in
            WaveformBarGeometry.frame(
                index: index,
                normalizedLevel: level,
                barWidth: WaveformLayout.barWidth,
                barSpacing: WaveformLayout.barSpacing,
                maxHeight: WaveformLayout.viewportHeight,
                minHeight: 3
            )
        }

        XCTAssertTrue(frames.allSatisfy { abs($0.midY - 12) < 0.001 })
        XCTAssertGreaterThan(
            try XCTUnwrap(frames.map(\.maxY).max()) -
                XCTUnwrap(frames.map(\.maxY).min()),
            2,
            "varying bars must spread below the centerline instead of sharing one bottom floor"
        )
        XCTAssertTrue(frames.allSatisfy { $0.minY >= 0 && $0.maxY <= 24 })
    }

    @MainActor
    func testRenderedWaveformsPassTheSevenBarCenteredCensus() throws {
        let recording = try render(
            WaveformView(
                color: Theme.recordingColor,
                isListening: false,
                currentLevel: { 1 }
            )
        )
        let transcribing = try render(
            WaveformView(processingColor: Theme.stateColor(for: .transcribing))
        )
        let speaking = try render(
            WaveformView(color: Theme.speakingColor, currentLevel: { 1 })
        )

        let result = VoiceBarNotchCaptureAudit.waveformCensus(
            recordingFrames: [recording],
            transcribingFrames: [transcribing],
            speakingFrames: [speaking]
        )

        XCTAssertTrue(result.passed, "\(result)")
        XCTAssertEqual(result.minimumRecordingBarCount, 7)
        XCTAssertEqual(result.minimumTranscribingBarCount, 7)
        XCTAssertEqual(result.minimumSpeakingBarCount, 7)
        XCTAssertGreaterThanOrEqual(result.recordingToSpeakingPeakRatio, 0.8)
        XCTAssertLessThanOrEqual(result.recordingMaximumCenterDeviation, 2)
        XCTAssertLessThanOrEqual(result.transcribingMaximumCenterDeviation, 2)
        XCTAssertGreaterThanOrEqual(result.transcribingMaximumBottomSpread, 2)
        XCTAssertLessThanOrEqual(result.maximumSlotOffsetDelta, 2)
    }

    private func m1GoldLevel(
        level: Double,
        time: Double,
        index: Int,
        barCount: Int
    ) -> Double {
        let phi = 1.618033988749895
        let phaseOffset = Double(index) * phi
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        let centerWeight = 1 - distance * 0.35
        let fast = sin(time * 7 + phaseOffset * 2.5) * 0.08
        let jitter = sin(time * 12 + phaseOffset * 6) * 0.05
        let motionScale = 0.4 + level * 0.6
        let base = 0.04 + level * 0.12
        let envelope = pow(level, 0.9) * centerWeight
        return max(0, min(1, base + envelope * 0.82 + (fast + jitter) * motionScale))
    }

    private func m1GoldProcessingLevel(
        time: Double,
        index: Int,
        barCount: Int
    ) -> Double {
        let center = Double(barCount - 1) / 2
        let distanceFromCenter = abs(Double(index) - center)
        let normalizedDistance = center == 0 ? 0 : distanceFromCenter / center
        let inwardOutward = sin(time * 4.8 - normalizedDistance * .pi) * 0.5 + 0.5
        let centerPulse = sin(time * 2.4) * 0.5 + 0.5
        let centerWeight = 1 - normalizedDistance * 0.35
        return max(0, min(1, 0.12 + inwardOutward * 0.38 + centerPulse * 0.16 * centerWeight))
    }

    private func barViewSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let barViewURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBarUI")
            .appendingPathComponent("BarView.swift")
        return try String(contentsOf: barViewURL, encoding: .utf8)
    }

    private func waveformViewSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot
                .appendingPathComponent("flow-bar")
                .appendingPathComponent("Sources")
                .appendingPathComponent("VoiceBarUI")
                .appendingPathComponent("WaveformView.swift"),
            encoding: .utf8
        )
    }

    @MainActor
    private func renderBar(
        state: VoiceState,
        presentation: VoiceBarNotchPresentation
    ) throws -> VoiceBarRGBImage {
        let model = VoiceBarNotchPresentationModel()
        model.setReducedMotion(true)
        model.updateOperationalEnvelope(
            hasTeleprompter: presentation.visualState == .teleprompter,
            isRecording: presentation.visualState == .recording,
            hasCompactStatus: presentation.visualState == .compactStatus,
            compactStatusLeadingWingWidth: presentation.visualState == .compactStatus
                ? presentation.geometry.leadingWingWidth
                : nil,
            compactStatusTrailingWingWidth: presentation.visualState == .compactStatus
                ? presentation.geometry.trailingWingWidth
                : nil,
            visibleCoreOcclusionInset: presentation.visibleCoreOcclusionInset
        )
        let size = CGSize(
            width: presentation.geometry.totalWidth,
            height: presentation.geometry.totalHeight
        )
        let host = NSHostingView(
            rootView: BarView(
                state: state,
                commandRouter: NoOpCommandRouter(),
                presentationModel: model
            )
            .frame(width: size.width, height: size.height)
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        guard let cgImage = captureWindowImage(windowNumber: window.windowNumber) else {
            throw NSError(domain: "WaveformViewTests", code: 2)
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let pixels = (0 ..< bitmap.pixelsHigh).flatMap { y in
            (0 ..< bitmap.pixelsWide).map { x -> VoiceBarRGB in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    return VoiceBarRGB(red: 0, green: 0, blue: 0)
                }
                return VoiceBarRGB(
                    red: color.redComponent,
                    green: color.greenComponent,
                    blue: color.blueComponent
                )
            }
        }
        return VoiceBarRGBImage(
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh,
            pixels: pixels
        )
    }

    private func captureWindowImage(windowNumber: Int) -> CGImage? {
        // The compositor is the only reliable way to capture native glass in an
        // entirely offscreen window. Resolve the legacy symbol dynamically so
        // this pixel regression stays warning-free on the macOS 14 SDK.
        typealias CaptureFunction = @convention(c) (
            CGRect,
            UInt32,
            UInt32,
            UInt32
        ) -> Unmanaged<CGImage>?
        guard let defaultLookup = UnsafeMutableRawPointer(bitPattern: -2),
              let symbol = dlsym(defaultLookup, "CGWindowListCreateImage") else {
            return nil
        }
        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution)
        return capture(
            CGRect.null,
            CGWindowListOption.optionIncludingWindow.rawValue,
            UInt32(windowNumber),
            options.rawValue
        )?.takeRetainedValue()
    }

    private func blueHorizontalBounds(
        in image: VoiceBarRGBImage,
        xRange: Range<Int>
    ) -> Range<Int>? {
        var minX = Int.max
        var maxX = Int.min
        for y in 0 ..< image.height {
            for x in xRange {
                let pixel = image.pixels[y * image.width + x]
                if pixel.blue > 0.50,
                   pixel.blue - pixel.red >= 0.18,
                   pixel.blue - pixel.green >= 0.08 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        return minX <= maxX ? minX ..< (maxX + 1) : nil
    }

    @MainActor
    private func render(_ waveform: WaveformView) throws -> VoiceBarRGBImage {
        let size = CGSize(
            width: WaveformLayout.viewportWidth,
            height: WaveformLayout.viewportHeight
        )
        let host = NSHostingView(
            rootView: waveform
                .frame(width: size.width, height: size.height)
                .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        )
        host.frame = CGRect(origin: .zero, size: size)
        host.layerContentsRedrawPolicy = .onSetNeedsDisplay
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "WaveformViewTests", code: 1)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let pixels = (0 ..< bitmap.pixelsHigh).flatMap { y in
            (0 ..< bitmap.pixelsWide).map { x -> VoiceBarRGB in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    return VoiceBarRGB(red: 0, green: 0, blue: 0)
                }
                return VoiceBarRGB(
                    red: color.redComponent,
                    green: color.greenComponent,
                    blue: color.blueComponent
                )
            }
        }
        return VoiceBarRGBImage(width: bitmap.pixelsWide, height: bitmap.pixelsHigh, pixels: pixels)
    }
}
