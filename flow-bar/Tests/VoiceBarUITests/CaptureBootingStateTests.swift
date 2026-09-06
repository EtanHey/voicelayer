import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// The pill flips to `.recording` optimistically at hold-start, 543–1281 ms
/// (median 603) before the recorder delivers its first PCM byte. These tests
/// pin the sub-state that keeps the pill from claiming a live mic it does not
/// have yet: `.recording` + `captureLive == false` is BOOTING, and only the
/// daemon's first audio frame promotes it to live.
final class CaptureBootingStateTests: XCTestCase {
    // MARK: - State

    func testPressToTalkRecordStartsBootingNotLive() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)

        XCTAssertEqual(state.mode, .recording, "the optimistic flip must stay — it is what makes F5 feel instant")
        XCTAssertFalse(state.captureLive, "no audio has landed yet, so the pill must not claim a live mic")
    }

    func testFirstDaemonAudioLevelPromotesCaptureToLive() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)
        XCTAssertFalse(state.captureLive)

        state.handleEvent(["type": "audio_level", "rms": 0.21])

        XCTAssertTrue(state.captureLive)
    }

    func testSilentFirstFrameStillCountsAsLiveCapture() {
        // rms 0 is room tone, not an absent recorder: frames are flowing.
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)
        state.handleEvent(["type": "audio_level", "rms": 0.0])

        XCTAssertTrue(state.captureLive)
    }

    func testLocalAppMeterAloneNeverClaimsCaptureIsLive() {
        // VoiceBar opens its own AVAudioEngine tap the moment mode becomes
        // .recording (VoiceBarApp.swift:1259). That meter hears the room while
        // the daemon's `rec` is still spawning — it is exactly the head-cut
        // lie, so it must not promote the pill.
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)
        state.setLocalRecordingLevel(0.9)

        XCTAssertFalse(state.captureLive)
    }

    func testDaemonInitiatedRecordingAlsoStartsBooting() {
        let state = VoiceState()
        state.handleEvent(["type": "state", "state": "recording"])

        XCTAssertEqual(state.mode, .recording)
        XCTAssertFalse(state.captureLive)

        state.handleEvent(["type": "audio_level", "rms": 0.3])

        XCTAssertTrue(state.captureLive)
    }

    func testCaptureLiveResetsWhenTheRecordingEnds() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)
        state.handleEvent(["type": "audio_level", "rms": 0.4])
        XCTAssertTrue(state.captureLive)

        state.handleEvent(["type": "state", "state": "idle"])

        XCTAssertEqual(state.mode, .idle)
        XCTAssertFalse(state.captureLive)
    }

    func testCaptureLiveResetsOnCancel() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)
        state.handleEvent(["type": "audio_level", "rms": 0.4])
        XCTAssertTrue(state.captureLive)

        state.cancel()

        XCTAssertFalse(state.captureLive)
    }

    func testTheNextPressStartsBootingAgain() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)
        state.handleEvent(["type": "state", "state": "recording"])
        state.handleEvent(["type": "audio_level", "rms": 0.4])
        XCTAssertTrue(state.captureLive)
        state.handleEvent(["type": "state", "state": "idle"])

        state.record(pressToTalk: true)

        XCTAssertEqual(state.mode, .recording)
        XCTAssertFalse(state.captureLive, "every press re-arms the booting state")
    }

    // MARK: - Rendering

    func testBootingWaveformIsGrayAndLiveWaveformIsRed() {
        assertColor(
            VoiceBarNotchWaveform.waveformColor(mode: .recording, isCaptureLive: false),
            equals: Theme.captureBootingColor
        )
        assertColor(
            VoiceBarNotchWaveform.waveformColor(mode: .recording, isCaptureLive: true),
            equals: Theme.recordingColor
        )
        let booting = resolvedSRGBComponents(for: Theme.captureBootingColor)
        XCTAssertLessThan(
            booting.red - max(booting.green, booting.blue),
            0.05,
            "booting must never read as red"
        )
    }

    func testNonRecordingModesIgnoreTheCaptureSubState() {
        assertColor(
            VoiceBarNotchWaveform.waveformColor(mode: .speaking, isCaptureLive: false),
            equals: Theme.speakingColor
        )
        assertColor(
            VoiceBarNotchWaveform.waveformColor(mode: .transcribing, isCaptureLive: false),
            equals: Theme.stateColor(for: .transcribing)
        )
    }

    func testBootingLevelsAreFlat() {
        let levels = WaveformMetrics.bootingLevels(barCount: WaveformLayout.barCount)

        XCTAssertEqual(levels.count, WaveformLayout.barCount)
        XCTAssertTrue(levels.allSatisfy { $0 == 0 }, "a booting waveform carries no amplitude at all")

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
        XCTAssertEqual(Set(frames.map(\.height)).count, 1, "every bar sits at the same flat height")
        XCTAssertEqual(Set(frames.map(\.minY)).count, 1, "and on one centered line")
    }

    func testBootingRenderIsStillSevenBarsWithNoLabel() throws {
        // A booting frame carries no text at all — the notch has no "REC" word
        // today and gains none here.
        let source = try waveformViewSource()
        let notch = try XCTUnwrap(
            source.components(separatedBy: "public struct VoiceBarNotchWaveform").dropFirst().first
        )
        XCTAssertEqual(
            notch.components(separatedBy: "WaveformView(").count - 1,
            1,
            "booting must reuse the one shared renderer, not add a second waveform host"
        )
        XCTAssertFalse(notch.contains("Text("), "no booting label of any kind")
    }

    @MainActor
    func testRenderedBootingWaveformIsFlatGrayAndRenderedLiveWaveformIsNot() throws {
        let booting = try render(
            WaveformView(
                color: Theme.captureBootingColor,
                isListening: true,
                isBooting: true,
                currentLevel: { 1 }
            )
        )
        let live = try render(
            WaveformView(
                color: Theme.recordingColor,
                isListening: false,
                currentLevel: { 1 }
            )
        )

        let bootingBars = litColumnRuns(in: booting)
        XCTAssertEqual(bootingBars.count, WaveformLayout.barCount, "seven dots stay on screen while booting")

        let bootingHeights = Set(barHeights(in: booting, columnRuns: bootingBars))
        XCTAssertEqual(bootingHeights.count, 1, "a booting waveform is flat — every dot the same height")

        let bootingPeak = try XCTUnwrap(bootingHeights.first)
        let livePeak = try XCTUnwrap(barHeights(in: live, columnRuns: litColumnRuns(in: live)).max())
        XCTAssertGreaterThan(livePeak, bootingPeak, "the live waveform must visibly rise above the flat bed")

        let bootingInk = try XCTUnwrap(brightestPixel(in: booting))
        XCTAssertLessThan(
            bootingInk.red - max(bootingInk.green, bootingInk.blue),
            0.05,
            "booting ink is gray, never red"
        )
    }

    // MARK: - Helpers

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

    private func assertColor(
        _ actual: Color,
        equals expected: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualComponents = resolvedSRGBComponents(for: actual)
        let expectedComponents = resolvedSRGBComponents(for: expected)
        XCTAssertEqual(actualComponents.red, expectedComponents.red, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actualComponents.green, expectedComponents.green, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actualComponents.blue, expectedComponents.blue, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actualComponents.alpha, expectedComponents.alpha, accuracy: 0.0001, file: file, line: line)
    }

    private func resolvedSRGBComponents(for color: Color)
        -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else {
            XCTFail("Could not resolve SwiftUI color in sRGB")
            return (0, 0, 0, 0)
        }
        return (nsColor.redComponent, nsColor.greenComponent, nsColor.blueComponent, nsColor.alphaComponent)
    }

    private func isInk(_ pixel: VoiceBarRGB) -> Bool {
        // The render helper paints on a 0.08/0.08/0.10 bed.
        pixel.red > 0.2 || pixel.green > 0.2 || pixel.blue > 0.2
    }

    private func litColumnRuns(in image: VoiceBarRGBImage) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var runStart: Int?
        for x in 0 ..< image.width {
            let lit = (0 ..< image.height).contains { y in
                isInk(image.pixels[y * image.width + x])
            }
            if lit, runStart == nil {
                runStart = x
            } else if !lit, let start = runStart {
                runs.append(start ..< x)
                runStart = nil
            }
        }
        if let start = runStart {
            runs.append(start ..< image.width)
        }
        return runs
    }

    private func barHeights(in image: VoiceBarRGBImage, columnRuns: [Range<Int>]) -> [Int] {
        columnRuns.map { run in
            var lit = 0
            for y in 0 ..< image.height {
                if run.contains(where: { x in isInk(image.pixels[y * image.width + x]) }) {
                    lit += 1
                }
            }
            return lit
        }
    }

    private func brightestPixel(in image: VoiceBarRGBImage) -> VoiceBarRGB? {
        image.pixels.filter(isInk).max { lhs, rhs in
            (lhs.red + lhs.green + lhs.blue) < (rhs.red + rhs.green + rhs.blue)
        }
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
            throw NSError(domain: "CaptureBootingStateTests", code: 1)
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
