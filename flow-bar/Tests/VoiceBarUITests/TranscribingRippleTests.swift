import AppKit
import OffscreenTestSupport
import ObjectiveC
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// c9-P (Etan, 2026-11-12, verbatim): "when recording the right side has the wave form, it would be nice if the red
/// waveform would just become the rippling one when it's transcribing ... make sure that it's more prominent or more
/// obvious that it's like transcribing without putting [prose] like transcribing or processing."
///
/// The production BarView, offscreen, driven by a frozen render clock so every frame is deterministic. The M1 cannot
/// render the M4's glass; these tests measure the bars, their frames and their colours, never the glass.
@MainActor
final class TranscribingRippleTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    /// The decorative clock (`visualRenderTime`) the waveform reads; moving it re-renders the bars at that time.
    private final class RenderClock: ObservableObject {
        @Published var time: Double = 100
    }

    private struct Harness: View {
        @ObservedObject var clock: RenderClock
        let state: VoiceState
        let model: VoiceBarNotchPresentationModel
        let reduceMotion: Bool?
        var scheme: ColorScheme = .dark

        var body: some View {
            // The app's shape (WingsU2ShotsTests): a presentation model and the panel outsets, so the wings render.
            BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                    presentationModel: model, includesPanelOutsets: true)
                .environment(\.colorScheme, scheme)
                .environment(\.visualRenderTime, clock.time)
                .environment(\.voiceBarReduceMotionOverride, reduceMotion)
        }
    }

    private struct Mounted {
        let host: NSHostingView<Harness>
        let window: NSWindow
        let clock: RenderClock
        let state: VoiceState
        let model: VoiceBarNotchPresentationModel
    }

    // MARK: - The meter becomes the ripple in place

    /// The right wing keeps the recording meter's slot: same frame, same seven bar columns; the bars turn the
    /// processing blue and ripple. No spinner, no History/Settings and no words in that slot.
    func testTranscribingRipplesInTheRecordingMetersFrameWithoutControlsOrWords() throws {
        let mounted = try mount()
        defer { unmount(mounted) }
        startRecording(mounted)
        let meter = try frame("Input level", in: mounted.host)
        XCTAssertTrue(elements(mounted.host).contains { $0.label == "Recording time" },
                      "the recording time is drawn while recording")
        let red = try barColumns(in: meter, of: mounted.host, matching: Self.isRed)

        send(mounted, ["type": "state", "state": "transcribing"])
        advance(mounted, by: 1.0) // past the 0.45 s hand-over
        let ripple = try frame("Transcription progress", in: mounted.host)
        XCTAssertEqual(ripple.minX, meter.minX, accuracy: 0.5, "the ripple sits in the meter's slot")
        XCTAssertEqual(ripple.maxX, meter.maxX, accuracy: 0.5)
        XCTAssertEqual(ripple.midY, meter.midY, accuracy: 0.5)
        XCTAssertEqual(ripple.height, meter.height, accuracy: 0.5)
        let blue = try barColumns(in: ripple, of: mounted.host, matching: Self.isRippleBlue)
        XCTAssertEqual(blue.count, WaveformLayout.barCount, "seven blue bars: \(blue)")
        XCTAssertEqual(red.count, WaveformLayout.barCount, "seven red bars: \(red)")
        for (r, b) in zip(red, blue) {
            XCTAssertEqual(r, b, accuracy: 1, "a bar moved sideways in the hand-over: red \(red) blue \(blue)")
        }
        XCTAssertEqual(try barColumns(in: ripple, of: mounted.host, matching: Self.isRed).count, 0,
                       "no red is left once the hand-over has finished")

        let labels = elements(mounted.host).compactMap(\.label)
        XCTAssertFalse(labels.contains("History"), "History left the meter's slot: \(labels)")
        XCTAssertFalse(labels.contains("Settings"), "Settings left the meter's slot: \(labels)")
        XCTAssertFalse(labels.contains("Recording time"), "the time leaves with the take: \(labels)")
        XCTAssertFalse(hasStaticText(mounted.host), "no words while transcribing: \(staticTexts(mounted.host))")
        // The spinner stays where Stop's row was, left of the notch, and never in the meter's slot.
        let spinner = try XCTUnwrap(elements(mounted.host).first { $0.label == "Transcribing" }, "spinner")
        XCTAssertLessThan(localFrame(spinner, in: mounted.host).maxX, ripple.minX - 100)
    }

    /// The bars hand over from the red meter to the ripple as one view: half-way, the very same seven columns are
    /// drawn in a colour between red and blue (never two sets of bars, never a gap).
    func testTheHandOverBlendsTheColourOnTheSameBars() throws {
        let mounted = try mount()
        defer { unmount(mounted) }
        startRecording(mounted)
        let meter = try frame("Input level", in: mounted.host)
        let red = try barColumns(in: meter, of: mounted.host, matching: Self.isRed)
        send(mounted, ["type": "state", "state": "transcribing"])
        advance(mounted, by: 0) // the first transcribing frame: still the red meter
        XCTAssertEqual(try barColumns(in: meter, of: mounted.host, matching: Self.isRed), red,
                       "the bars do not disappear or jump when the take stops")
        advance(mounted, by: WaveformProcessingHandover.duration / 2)
        let mixed = try barColumns(in: meter, of: mounted.host, matching: Self.isMidHandOver)
        XCTAssertEqual(mixed.count, WaveformLayout.barCount, "half-way the same seven bars are mid-colour: \(mixed)")
        for (r, m) in zip(red, mixed) { XCTAssertEqual(r, m, accuracy: 1) }
        XCTAssertEqual(try barColumns(in: meter, of: mounted.host, matching: Self.isRippleBlue).count, 0,
                       "no second, blue set of bars is drawn beside them")
    }

    /// Reduce Motion: no ripple travels. Two frames half a ripple period apart draw identical bar heights, where full
    /// motion draws different ones.
    func testReduceMotionHoldsTheRippleStill() throws {
        func heights(reduceMotion: Bool, at times: [Double]) throws -> [[Int]] {
            let mounted = try mount(reduceMotion: reduceMotion)
            defer { unmount(mounted) }
            send(mounted, ["type": "state", "state": "transcribing"])
            advance(mounted, by: 0)
            let ripple = try frame("Transcription progress", in: mounted.host)
            return try times.map { time in
                mounted.clock.time = time
                settle(mounted.host)
                return try barHeights(in: ripple, of: mounted.host)
            }
        }
        let halfPeriod = .pi / 4.8
        let still = try heights(reduceMotion: true, at: [200, 200 + halfPeriod])
        XCTAssertEqual(still[0].count, WaveformLayout.barCount, "\(still)")
        XCTAssertEqual(still[0], still[1], "Reduce Motion: the bars hold still")
        let moving = try heights(reduceMotion: false, at: [200, 200 + halfPeriod])
        XCTAssertNotEqual(moving[0], moving[1], "full motion: the ripple travels")
    }

    // MARK: - Pure pieces

    func testTheHandOverEasesFromDriveToRippleAndBack() {
        var handover = WaveformProcessingHandover()
        XCTAssertEqual(handover.progress(isProcessing: false, at: 10), 0)
        XCTAssertEqual(handover.progress(isProcessing: true, at: 10), 0, "the switch frame still shows the drive")
        let half = handover.progress(isProcessing: true, at: 10 + WaveformProcessingHandover.duration / 2)
        XCTAssertEqual(half, 0.5, accuracy: 0.001)
        XCTAssertEqual(handover.progress(isProcessing: true, at: 10 + WaveformProcessingHandover.duration), 1)
        XCTAssertEqual(handover.progress(isProcessing: false, at: 11), 0, accuracy: 1e-9, "a new take hands back")

        var fresh = WaveformProcessingHandover()
        XCTAssertEqual(fresh.progress(isProcessing: true, at: 5), 1, "a meter that appears transcribing ripples at once")

        let drive = [0.1, 0.2, 0.3, 0.4, 0.3, 0.2, 0.1]
        let ripple = WaveformMetrics.processingLevels(time: 3, barCount: 7)
        XCTAssertEqual(WaveformMetrics.handoverLevels(from: drive, to: ripple, progress: 0), drive)
        XCTAssertEqual(WaveformMetrics.handoverLevels(from: drive, to: ripple, progress: 1), ripple)
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            let layers = WaveformMetrics.handoverLayerOpacities(progress: p)
            let coverage = layers.ripple + layers.drive * (1 - layers.ripple)
            XCTAssertEqual(coverage, 1, accuracy: 1e-9, "the bars never thin out mid-hand-over (p \(p))")
            if coverage > 0 { XCTAssertEqual(layers.ripple / coverage, p, accuracy: 1e-9, "colour mix at p \(p)") }
        }
        let settled = WaveformMetrics.handoverLayerOpacities(progress: 1)
        XCTAssertEqual(settled.drive, 0, "no red is drawn once the hand-over is done")
        XCTAssertEqual(settled.ripple, 1, "the ripple's ink is fully opaque")
    }

    /// F2 + F3 (pure): the hand-over only runs forward, and its clock starts at the switch.
    func testTheHandOverRunsForwardOnlyAndStartsAtTheSwitch() {
        var handover = WaveformProcessingHandover()
        handover.progress(isProcessing: false, at: 10)
        handover.progress(isProcessing: true, at: 10.1)
        XCTAssertEqual(handover.progress(isProcessing: true, at: 11), 1, "fixture: the ripple has taken over")
        XCTAssertEqual(handover.progress(isProcessing: false, at: 11.016), 0, "F2: the next frame of a new take is red")
        XCTAssertEqual(handover.progress(isProcessing: true, at: 20), 0, "F3: a second with no frame is not hand-over time")
        XCTAssertEqual(handover.progress(isProcessing: true, at: 20 + 0.45 / 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(handover.progress(isProcessing: false, at: 20.3), 0, "F2: cancelling mid-way returns to red at once")
    }

    func testReduceMotionArchIsStillAndBreathesGently() {
        let arch = WaveformMetrics.processingLevelsReducedMotion(barCount: 7)
        XCTAssertEqual(arch.count, 7)
        XCTAssertEqual(arch[3], arch.max(), "centre-weighted like the ripple")
        XCTAssertEqual(arch, arch.reversed(), "symmetric")
        let glows = stride(from: 0.0, to: 6, by: 0.05).map(WaveformMetrics.processingReducedMotionGlowOpacity(time:))
        XCTAssertGreaterThanOrEqual(glows.min() ?? 0, 0.1 - 1e-9)
        XCTAssertLessThanOrEqual(glows.max() ?? 2, 0.6 + 1e-9)
        XCTAssertGreaterThan((glows.max() ?? 0) - (glows.min() ?? 0), 0.4, "the halo visibly breathes")
    }

    /// The ripple's blue holds ≥ 3:1 on the M4's grey glass as recorded on 2026-11-12, where the old processing blue
    /// read 1.4:1, and it stays the processing hue (within 6° of `speakingColor`).
    func testProcessingRippleHoldsThreeToOneOnTheM4Glass() throws {
        let glass = Theme.measuredM4GlassRGB
        let ripple = try rgb(Theme.processingRippleColor)
        let old = try rgb(Theme.speakingColor)
        let contrast = Self.contrast(ripple, (glass.red, glass.green, glass.blue))
        XCTAssertGreaterThanOrEqual(contrast, 3, "ripple \(ripple) on M4 glass: \(contrast):1")
        XCTAssertLessThan(Self.contrast(old, (glass.red, glass.green, glass.blue)), 3, "why the blue was lifted")
        XCTAssertEqual(Self.hue(ripple), Self.hue(old), accuracy: 6, "still the processing blue")
        print("C9P contrast ripple-on-M4-glass \(String(format: "%.2f", contrast)):1")
    }


    // MARK: - Round 2 (review RP-transcribing F1-F7)

    /// F1: with an earlier take still processing, the recording band is wider (its spinner is a fourth left slot).
    /// At Stop the band keeps that width, so the meter keeps its frame and its seven columns.
    func testAnEarlierTakesWiderBandIsKeptAtStop() throws {
        let mounted = try mount()
        defer { unmount(mounted) }
        send(mounted, ["type": "state", "state": "recording", "source": "recording", "mode": "ptt",
                       "take_id": "B", "mic_take_id": "B",
                       "recording_jobs": [["take_id": "A", "kind": "live", "phase": "processing"],
                                          ["take_id": "B", "kind": "live", "phase": "capturing"]]])
        send(mounted, ["type": "audio_level", "rms": 0.45])
        advance(mounted, by: 0.5)
        XCTAssertTrue(VoiceBarPresentation.showsEarlierTakeProcessing(for: mounted.state), "fixture: A is processing")
        XCTAssertNotNil(elements(mounted.host).first { $0.label == "Earlier recording still transcribing" })
        let meter = try frame("Input level", in: mounted.host)
        let red = try barColumns(in: meter, of: mounted.host, matching: Self.isRed)
        // B stops. The daemon's snapshot already counts B as processing when the mode flips.
        send(mounted, ["type": "state", "state": "transcribing", "source": "recording",
                       "recording_jobs": [["take_id": "A", "kind": "live", "phase": "processing"],
                                          ["take_id": "B", "kind": "live", "phase": "processing"]]])
        advance(mounted, by: 1)
        XCTAssertEqual(mounted.state.mode, .transcribing, "fixture")
        let ripple = try frame("Transcription progress", in: mounted.host)
        XCTAssertEqual(ripple.minX, meter.minX, accuracy: 0.5, "the meter must not move at Stop (was \(meter))")
        XCTAssertEqual(ripple.maxX, meter.maxX, accuracy: 0.5)
        let blue = try barColumns(in: ripple, of: mounted.host, matching: Self.isRippleBlue)
        XCTAssertEqual(blue.count, WaveformLayout.barCount, "\(blue)")
        for (r, b) in zip(red, blue) { XCTAssertEqual(r, b, accuracy: 1, "red \(red) blue \(blue)") }
    }

    /// F2: F5 starts take B while A is still transcribing. B's meter is red from its first frame; the ripple never
    /// drives a live recording, even a frame (16 ms) after the last processing frame.
    func testANewTakeStartsRedWhileTheLastOneStillRipples() throws {
        let mounted = try mount()
        defer { unmount(mounted) }
        startRecording(mounted)
        send(mounted, ["type": "state", "state": "transcribing"])
        advance(mounted, by: 1)
        let ripple = try frame("Transcription progress", in: mounted.host)
        XCTAssertEqual(try barColumns(in: ripple, of: mounted.host, matching: Self.isRippleBlue).count, 7, "fixture")
        send(mounted, ["type": "state", "state": "recording", "mode": "ptt"])
        send(mounted, ["type": "audio_level", "rms": 0.45])
        advance(mounted, by: 0.016)
        let meter = try frame("Input level", in: mounted.host)
        XCTAssertEqual(try barColumns(in: meter, of: mounted.host, matching: Self.isRed).count, WaveformLayout.barCount,
                       "take B's meter is red at once")
        XCTAssertEqual(try barColumns(in: meter, of: mounted.host, matching: Self.isBlueInk).count, 0,
                       "no blue rides into take B")
    }

    /// F3: a paused take's meter is not sampled while paused. When it stops, the hand-over still starts from red.
    func testAPausedTakeStillGetsTheWholeHandOver() throws {
        let mounted = try mount()
        defer { unmount(mounted) }
        startRecording(mounted)
        mounted.state.setRecordingPaused(true)
        sync(mounted)
        XCTAssertTrue(mounted.state.isRecordingPaused, "fixture")
        try assertTheHandOverStartsAtTheSwitch(mounted)
    }

    /// F3: any gap before the first transcribing frame (an unsampled second) leaves the whole hand-over to run.
    func testADelayedFirstFrameStillGetsTheWholeHandOver() throws {
        let mounted = try mount()
        defer { unmount(mounted) }
        startRecording(mounted)
        try assertTheHandOverStartsAtTheSwitch(mounted)
    }

    private func assertTheHandOverStartsAtTheSwitch(_ mounted: Mounted, file: StaticString = #filePath,
                                                    line: UInt = #line) throws {
        let meter = try frame(mounted.state.isRecordingPaused ? "Recording paused" : "Input level", in: mounted.host)
        let red = try barColumns(in: meter, of: mounted.host, matching: Self.isRed)
        XCTAssertEqual(red.count, WaveformLayout.barCount, "fixture", file: file, line: line)
        // One second passes with no frame, then the take stops: both land in one render.
        mounted.clock.time += 1
        send(mounted, ["type": "state", "state": "transcribing"])
        XCTAssertEqual(try barColumns(in: meter, of: mounted.host, matching: Self.isRed), red,
                       "the first transcribing frame is still the red meter", file: file, line: line)
        advance(mounted, by: 0.45 / 2)
        XCTAssertEqual(try barColumns(in: meter, of: mounted.host, matching: Self.isMidHandOver).count,
                       WaveformLayout.barCount, "half-way through the hand-over", file: file, line: line)
    }

    /// F4: a 10:00 and a 1:02:03 take. Their wider clock narrows the meter while recording; at Stop the time lane
    /// keeps that width class, so the seven columns do not spread.
    func testALongTakeKeepsItsMeterColumnsAtStop() throws {
        for (seconds, text) in [(600.0, "10:00"), (3723.0, "1:02:03")] {
            var now = 1000.0
            let mounted = try mount(recordingClock: { now })
            defer { unmount(mounted) }
            startRecording(mounted)
            now += seconds
            settle(mounted.host) // the clock's own 0.25 s timeline catches up
            XCTAssertEqual(VoiceBarReadingTimeLabel.text(elapsedMilliseconds: mounted.state.recordingElapsedMilliseconds()),
                           text, "fixture")
            let meter = try frame("Input level", in: mounted.host)
            let red = try barColumns(in: meter, of: mounted.host, matching: Self.isRed)
            XCTAssertEqual(red.count, WaveformLayout.barCount, "\(text) fixture: \(red)")
            send(mounted, ["type": "state", "state": "transcribing"])
            advance(mounted, by: 1)
            let ripple = try frame("Transcription progress", in: mounted.host)
            let blue = try barColumns(in: ripple, of: mounted.host, matching: Self.isRippleBlue)
            XCTAssertEqual(blue.count, WaveformLayout.barCount, "\(text): \(blue)")
            for (r, b) in zip(red, blue) {
                XCTAssertEqual(r, b, accuracy: 1, "\(text): the columns spread at Stop: red \(red) blue \(blue)")
            }
        }
    }

    /// F6: while transcribing the time lane is a still placeholder: no recording clock (and its 0.25 s timeline)
    /// is mounted.
    func testTranscribingMountsNoRecordingClock() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/BarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let row = try XCTUnwrap(source.components(separatedBy: "private var recordingMeterRow").dropFirst().first)
            .components(separatedBy: "} meter: {")[0]
        let recordingBranch = try XCTUnwrap(row.components(separatedBy: "if isRecording {").dropFirst().first,
                                            "the clock is mounted only while recording")
            .components(separatedBy: "} else {")
        XCTAssertTrue(recordingBranch[0].contains("VoiceBarRecordingTimeRegion("))
        XCTAssertGreaterThan(recordingBranch.count, 1)
        XCTAssertFalse(recordingBranch[1].contains("VoiceBarRecordingTimeRegion("), "no clock while transcribing")
        XCTAssertFalse(recordingBranch[1].contains("TimelineView"), "no timeline while transcribing")
    }

    /// F7: Reduce Motion's dimmest frame (the 2.6 s pulse's minimum) keeps the bars' ink: measured on the render as
    /// the ink's coverage against the pulse's brightest frame, then composited over the M4's recorded grey.
    func testReduceMotionKeepsThreeToOneAtItsDimmestFrame() throws {
        let mounted = try mount(reduceMotion: true)
        defer { unmount(mounted) }
        send(mounted, ["type": "state", "state": "transcribing"])
        let period = 2 * Double.pi / 2.4
        let dimmest = 1.5 * Double.pi / 2.4 + 76 * period   // sin(2.4 t) = -1
        let brightest = 0.5 * Double.pi / 2.4 + 76 * period // sin(2.4 t) = +1
        let ripple = try frame("Transcription progress", in: mounted.host)
        mounted.clock.time = brightest
        settle(mounted.host)
        let bright = try barInk(in: ripple, of: mounted.host)
        mounted.clock.time = dimmest
        settle(mounted.host)
        let dim = try barInk(in: ripple, of: mounted.host)
        let coverage = (dim.ink.g - dim.background.g) / (bright.ink.g - bright.background.g)
        let token = try rgb(Theme.processingRippleColor)
        let glass = Theme.measuredM4GlassRGB
        let onM4 = (r: coverage * token.r + (1 - coverage) * glass.red,
                    g: coverage * token.g + (1 - coverage) * glass.green,
                    b: coverage * token.b + (1 - coverage) * glass.blue)
        let contrast = Self.contrast(onM4, (glass.red, glass.green, glass.blue))
        print("C9P F7 reduce-motion dimmest coverage \(String(format: "%.3f", coverage)) on-M4 \(String(format: "%.2f", contrast)):1")
        XCTAssertGreaterThanOrEqual(contrast, 3, "dimmest Reduce Motion frame on the M4 grey: \(contrast):1 (coverage \(coverage))")
    }

    /// F7: the ripple's contrast measured on the render (numbers, not a look): its darkest ripple trough and Reduce
    /// Motion's dimmest frame, in dark and light appearance, against the wing right beside the meter. The offscreen
    /// wing is not the M4's glass; the M4 figure is `testReduceMotionKeepsThreeToOneAtItsDimmestFrame`'s composite.
    func testRippleContrastMeasuredOnTheRender() throws {
        var rows: [String] = []
        for (appearance, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            for reduceMotion in [false, true] {
                let mounted = try mount(reduceMotion: reduceMotion, appearance: appearance)
                defer { unmount(mounted) }
                send(mounted, ["type": "state", "state": "transcribing"])
                let ripple = try frame("Transcription progress", in: mounted.host)
                var worst = Double.infinity
                var worstRow = ""
                // Twelve phases across one 1.31 s ripple period (and through the 2.6 s pulse's minimum).
                let period = 2 * Double.pi / 2.4
                for step in 0 ..< 12 {
                    mounted.clock.time = 1.5 * Double.pi / 2.4 + 76 * period + Double(step) * (2 * Double.pi / 4.8) / 12
                    settle(mounted.host)
                    let sample = try barInk(in: ripple, of: mounted.host)
                    let c = Self.contrast(sample.ink, sample.background)
                    if c < worst {
                        worst = c
                        worstRow = String(format: "%@\t%@\tink (%.0f, %.0f, %.0f)\twing (%.0f, %.0f, %.0f)\t%.2f:1",
                                          name, reduceMotion ? "reduce-motion" : "full-motion",
                                          sample.ink.r, sample.ink.g, sample.ink.b,
                                          sample.background.r, sample.background.g, sample.background.b, c)
                    }
                }
                rows.append(worstRow)
                XCTAssertGreaterThanOrEqual(worst, 3, "\(worstRow)")
            }
        }
        print("C9P F7 render contrast (worst of 12 phases)\n" + rows.joined(separator: "\n"))
        if let path = ProcessInfo.processInfo.environment["VOICEBAR_C9P_SHOTS_DIR"], !path.isEmpty {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try (rows.joined(separator: "\n") + "\n").write(
                to: URL(fileURLWithPath: path).appendingPathComponent("c9p-contrast.tsv"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Opt-in pictures (VOICEBAR_C9P_SHOTS_DIR)

    func testWriteTranscribingShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_C9P_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_C9P_SHOTS_DIR to write the c9-P shots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var receipt: [String] = []
        let mounted = try mount()
        startRecording(mounted)
        try shot(mounted, "after-recording", into: directory)
        receipt.append("recording meter frame \(try frame("Input level", in: mounted.host))")
        send(mounted, ["type": "state", "state": "transcribing"])
        advance(mounted, by: WaveformProcessingHandover.duration / 2)
        try shot(mounted, "after-handover-mid", into: directory)
        advance(mounted, by: 1)
        for (index, step) in [0.0, 0.33, 0.33].enumerated() {
            advance(mounted, by: step)
            try shot(mounted, "after-transcribing-\(index)", into: directory)
        }
        let ripple = try frame("Transcription progress", in: mounted.host)
        receipt.append("transcribing ripple frame \(ripple)")
        receipt.append("ripple core colour \(try coreColour(in: ripple, of: mounted.host))")
        receipt.append("pill beside ripple (offscreen, not glass) \(try backgroundColour(beside: ripple, of: mounted.host))")
        unmount(mounted)
        let reduced = try mount(reduceMotion: true)
        send(reduced, ["type": "state", "state": "transcribing"])
        advance(reduced, by: 0)
        try shot(reduced, "after-transcribing-reduce-motion", into: directory)
        unmount(reduced)
        // Round 2 pictures: light appearance, an earlier take's wider band, a 10:00 take.
        let light = try mount(appearance: .aqua)
        startRecording(light)
        try shot(light, "r2-light-recording", into: directory)
        send(light, ["type": "state", "state": "transcribing"])
        advance(light, by: 1)
        try shot(light, "r2-light-transcribing", into: directory)
        unmount(light)
        let earlier = try mount()
        send(earlier, ["type": "state", "state": "recording", "source": "recording", "mode": "ptt",
                       "take_id": "B", "mic_take_id": "B",
                       "recording_jobs": [["take_id": "A", "kind": "live", "phase": "processing"],
                                          ["take_id": "B", "kind": "live", "phase": "capturing"]]])
        send(earlier, ["type": "audio_level", "rms": 0.45])
        advance(earlier, by: 0.5)
        try shot(earlier, "r2-earlier-take-recording", into: directory)
        receipt.append("earlier take: recording meter \(try frame("Input level", in: earlier.host))")
        send(earlier, ["type": "state", "state": "transcribing", "source": "recording",
                       "recording_jobs": [["take_id": "A", "kind": "live", "phase": "processing"],
                                          ["take_id": "B", "kind": "live", "phase": "processing"]]])
        advance(earlier, by: 1)
        try shot(earlier, "r2-earlier-take-transcribing", into: directory)
        receipt.append("earlier take: transcribing ripple \(try frame("Transcription progress", in: earlier.host))")
        unmount(earlier)
        var now = 1000.0
        let long = try mount(recordingClock: { now })
        startRecording(long)
        now += 600
        settle(long.host)
        try shot(long, "r2-long-take-recording", into: directory)
        send(long, ["type": "state", "state": "transcribing"])
        advance(long, by: 1)
        try shot(long, "r2-long-take-transcribing", into: directory)
        unmount(long)
        try (receipt.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("c9p-shots.txt"),
                                                         atomically: true, encoding: .utf8)
    }

    // MARK: - Harness

    private func mount(reduceMotion: Bool? = false, appearance: NSAppearance.Name = .darkAqua,
                       recordingClock: (() -> TimeInterval)? = nil) throws -> Mounted {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        let app = NSApplication.shared
        let setter = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
        guard app.responds(to: setter) else { throw XCTSkip("Offscreen SwiftUI AX must be available") }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(app.method(for: setter), to: Setter.self)(app, setter, true)
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            keepsExpandedInDevState: false
        )
        state.sendCommand = { _ in }
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        if let recordingClock { state.recordingTimingClock = recordingClock }
        let clock = RenderClock()
        let model = VoiceBarNotchPresentationModel()
        let host = NSHostingView(rootView: Harness(clock: clock, state: state, model: model,
                                                   reduceMotion: reduceMotion,
                                                   scheme: appearance == .aqua ? .light : .dark))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        // The wings' glass only reaches the compositor (cacheDisplay draws them empty), so these windows are captured
        // from the window server like ReadQueueShotsTests' processing shots.
        VLOrderCompositorTestWindow(window)
        let mounted = Mounted(host: host, window: window, clock: clock, state: state, model: model)
        sync(mounted)
        return mounted
    }

    /// The app's one feed from VoiceState into the presentation model (`refreshNotchPresentationModel`).
    private func sync(_ mounted: Mounted) {
        let state = mounted.state
        let resolved = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: state.mode,
            showsRecordingHold: state.mode == .recording && state.recordingMode == "vad",
            showsRecordingPause: state.mode == .recording && state.recordingMode == "ptt",
            isCollapsed: false,
            showsEarlierTakeProcessing: VoiceBarPresentation.showsEarlierTakeProcessing(for: state)
        ))
        let isStatus = resolved.visualState == .compactStatus
        let isRecording = resolved.visualState == .recording
        mounted.model.updateOperationalEnvelope(
            hasTeleprompter: false, isRecording: isRecording, hasCompactStatus: isStatus,
            compactStatusLeadingWingWidth: isStatus ? resolved.geometry.leadingWingWidth : nil,
            compactStatusTrailingWingWidth: isStatus ? resolved.geometry.trailingWingWidth : nil,
            recordingLeadingWingWidth: isRecording ? resolved.geometry.leadingWingWidth : nil,
            recordingTrailingWingWidth: isRecording ? resolved.geometry.trailingWingWidth : nil,
            holdsRecordingWings: state.mode == .transcribing // R2-ONLY
        )
        settle(mounted.host)
    }

    private func send(_ mounted: Mounted, _ event: [String: Any]) {
        mounted.state.handleEvent(event)
        sync(mounted)
    }

    private func unmount(_ mounted: Mounted) {
        mounted.window.orderOut(nil)
        mounted.window.contentView = nil
        mounted.window.close()
    }

    private func startRecording(_ mounted: Mounted) {
        send(mounted, ["type": "state", "state": "recording", "mode": "ptt"])
        send(mounted, ["type": "audio_level", "rms": 0.45])
        advance(mounted, by: 0.5)
    }

    private func advance(_ mounted: Mounted, by seconds: Double) {
        mounted.clock.time += seconds
        settle(mounted.host)
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
    }

    // SwiftUI AccessibilityNode implements the AX selectors without declaring NSAccessibilityProtocol.
    private struct AX {
        let object: NSObject
        var label: String? { object.value(forKey: "accessibilityLabel") as? String }
        var role: String? { object.value(forKey: "accessibilityRole") as? String }
        var value: Any? { object.value(forKey: "accessibilityValue") }
        var frame: CGRect { (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        var children: [Any] { object.value(forKey: "accessibilityChildren") as? [Any] ?? [] }
    }

    private func elements(_ root: Any, depth: Int = 0) -> [AX] {
        guard depth < 30, let object = root as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityRole")) else { return [] }
        let node = AX(object: object)
        return [node] + node.children.flatMap { elements($0, depth: depth + 1) }
    }

    private func staticTexts(_ host: NSView) -> [String] {
        elements(host).filter { $0.role == NSAccessibility.Role.staticText.rawValue }
            .map { "\($0.label ?? "")|\($0.value.map { "\($0)" } ?? "")" }
    }

    private func hasStaticText(_ host: NSView) -> Bool { !staticTexts(host).isEmpty }

    private func localFrame(_ element: AX, in host: NSView) -> CGRect {
        host.convert(host.window!.convertFromScreen(element.frame), from: nil)
    }

    private func frame(_ label: String, in host: NSView) throws -> CGRect {
        let element = try XCTUnwrap(elements(host).first { $0.label == label },
                                    "Missing \(label); AX: \(elements(host).compactMap(\.label))")
        let rect = localFrame(element, in: host)
        XCTAssertGreaterThan(rect.width, 0)
        return rect
    }

    // MARK: - Pixels

    private typealias RGB = (r: Double, g: Double, b: Double)

    private static func isRed(_ c: RGB) -> Bool { c.r > 170 && c.r - c.g > 80 && c.r - c.b > 80 }
    private static func isRippleBlue(_ c: RGB) -> Bool { c.b > 215 && c.g > 170 && c.b - c.r > 50 }
    /// Any of the ripple's blue over the dark wing, dimmed included (Reduce Motion breathes down to 70 %).
    private static func isBlueInk(_ c: RGB) -> Bool { c.b > 110 && c.b - c.r > 30 }
    /// Half-way between #E54D4D and #A3D7FF is about (196, 146, 166): neither red nor blue.
    private static func isMidHandOver(_ c: RGB) -> Bool {
        abs(c.r - 196) < 30 && abs(c.g - 146) < 30 && abs(c.b - 166) < 30
    }

    private func bitmap(_ host: NSView) throws -> NSBitmapImageRep {
        let window = try XCTUnwrap(host.window)
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let lookup = UnsafeMutableRawPointer(bitPattern: -2),
              let symbol = dlsym(lookup, "CGWindowListCreateImage") else {
            throw XCTSkip("CGWindowListCreateImage is unavailable")
        }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let image = try XCTUnwrap(capture(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                                          UInt32(window.windowNumber),
                                          CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution).rawValue)?
            .takeRetainedValue(), "the compositor returned no image of the test window")
        return NSBitmapImageRep(cgImage: image)
    }

    /// The rect in bitmap pixels (top-left origin).
    private func pixelRect(_ rect: CGRect, host: NSView, rep: NSBitmapImageRep) -> (x: Range<Int>, y: Range<Int>) {
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let x1 = min(rep.pixelsWide, Int((rect.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((top * scale).rounded(.down)))
        let y1 = min(rep.pixelsHigh, Int(((top + rect.height) * scale).rounded(.up)))
        return (x0 ..< max(x0, x1), y0 ..< max(y0, y1))
    }

    private func colour(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> RGB {
        let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
        return (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
    }

    /// Centres (in pixels) of each run of columns holding at least one matching pixel.
    private func barColumns(in rect: CGRect, of host: NSView, matching match: (RGB) -> Bool) throws -> [Double] {
        let rep = try bitmap(host)
        let area = pixelRect(rect, host: host, rep: rep)
        var runs: [Double] = []
        var start: Int?
        for x in area.x {
            let ink = area.y.contains { match(colour(rep, x, $0)) }
            if ink, start == nil { start = x }
            if !ink, let s = start { runs.append(Double(s + x - 1) / 2); start = nil }
        }
        if let s = start { runs.append(Double(s + area.x.upperBound - 1) / 2) }
        return runs
    }

    /// Each blue bar's height in pixels (the tallest matching run in its columns), left to right.
    private func barHeights(in rect: CGRect, of host: NSView) throws -> [Int] {
        let rep = try bitmap(host)
        let area = pixelRect(rect, host: host, rep: rep)
        var heights: [Int] = []
        var current = 0
        var inBar = false
        for x in area.x {
            let count = area.y.filter { Self.isBlueInk(colour(rep, x, $0)) }.count
            if count > 0 { current = max(current, count); inBar = true }
            if count == 0, inBar { heights.append(current); current = 0; inBar = false }
        }
        if inBar { heights.append(current) }
        return heights
    }

    /// The bars' ink (median of each column's brightest-blue pixel, bar centres only) and the wing just outside
    /// the meter, both from the render.
    private func barInk(in rect: CGRect, of host: NSView) throws -> (ink: RGB, background: RGB) {
        let rep = try bitmap(host)
        let area = pixelRect(rect, host: host, rep: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let background = colour(rep, max(0, area.x.lowerBound - Int(10 * scale)), (area.y.lowerBound + area.y.upperBound) / 2)
        // Per column, the blue pixel that stands out most from the wing (a bar's core, not its glow or edge); then the
        // upper quartile across columns, so gaps and anti-aliased edges do not decide it.
        var cores: [(RGB, Double)] = []
        for x in area.x {
            let column = area.y.map { colour(rep, x, $0) }.filter { $0.b - $0.r > 30 }
            if let best = column.max(by: { Self.contrast($0, background) < Self.contrast($1, background) }) {
                cores.append((best, Self.contrast(best, background)))
            }
        }
        let sorted = cores.sorted { $0.1 < $1.1 }
        let ink = sorted.isEmpty ? (r: 0, g: 0, b: 0) : sorted[sorted.count * 3 / 4].0
        return (ink, background)
    }

    private func coreColour(in rect: CGRect, of host: NSView) throws -> String {
        let rep = try bitmap(host)
        let area = pixelRect(rect, host: host, rep: rep)
        var best: RGB = (0, 0, 0)
        for x in area.x { for y in area.y {
            let c = colour(rep, x, y)
            if c.b - c.r > best.b - best.r { best = c }
        } }
        return String(format: "(%.0f, %.0f, %.0f)", best.r, best.g, best.b)
    }

    private func backgroundColour(beside rect: CGRect, of host: NSView) throws -> String {
        let rep = try bitmap(host)
        let area = pixelRect(rect.offsetBy(dx: -rect.width / 2 - 4, dy: 0).insetBy(dx: rect.width / 4, dy: 4),
                             host: host, rep: rep)
        let x = (area.x.lowerBound + area.x.upperBound) / 2, y = (area.y.lowerBound + area.y.upperBound) / 2
        let c = colour(rep, x, y)
        return String(format: "(%.0f, %.0f, %.0f)", c.r, c.g, c.b)
    }

    private func shot(_ mounted: Mounted, _ name: String, into directory: URL) throws {
        let rep = try bitmap(mounted.host)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - Colour maths (WCAG 2.x relative luminance)

    private func rgb(_ color: Color) throws -> RGB {
        let c = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
    }

    private static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { let s = v / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func hue(_ c: RGB) -> Double {
        let r = c.r / 255, g = c.g / 255, b = c.b / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard d > 0 else { return 0 }
        let h: Double = mx == r ? (g - b) / d : mx == g ? 2 + (b - r) / d : 4 + (r - g) / d
        return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    }
}
