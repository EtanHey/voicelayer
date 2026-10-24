import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// H1-b: the History scrub bar. Logic is proven on the model (SettingsAudioPlaybackTests); these
/// pin the bar's key/VoiceOver steps, that its fill follows the clip, where SettingsView mounts
/// it, and write the light/dark shots to look at.
@MainActor
final class SettingsPlaybackScrubBarTests: XCTestCase {
    private let clipURL = URL(fileURLWithPath: "/tmp/recording-latest/audio.wav")

    func testArrowKeysStepByTheKeyboardSeekStep() {
        XCTAssertEqual(SettingsPlaybackScrubBar.seekDelta(for: .leftArrow), -5)
        XCTAssertEqual(SettingsPlaybackScrubBar.seekDelta(for: .rightArrow), 5)
        XCTAssertNil(SettingsPlaybackScrubBar.seekDelta(for: .upArrow))
        XCTAssertNil(SettingsPlaybackScrubBar.seekDelta(for: .space))
    }

    func testVoiceOverIncrementAndDecrementStepTheSameAmount() {
        XCTAssertEqual(SettingsPlaybackScrubBar.seekDelta(for: .increment), 5)
        XCTAssertEqual(SettingsPlaybackScrubBar.seekDelta(for: .decrement), -5)
    }

    /// #160 review MUST-FIX: a drag that overshoots the end stopped the clip and unmounted the bar mid-drag.
    /// While dragging only the knob moves (clamped short of the end); the seek happens once, on release, and the
    /// clip then ends only by playing to its end.
    func testADragPastTheEndKeepsTheClipPlayingAndSeeksOnceOnRelease() {
        let seeks = SeekLog()
        let playback = recordingPlayback(currentTime: 20, duration: 65, seeks: seeks)
        playback.toggle(clipURL)
        var drag = SettingsScrubDrag()

        drag.changed(toFraction: 0.5, duration: 65, playback: playback, url: clipURL)
        drag.changed(toFraction: 1.4, duration: 65, playback: playback, url: clipURL)

        XCTAssertEqual(seeks.times, [], "dragging moves only the knob")
        XCTAssertTrue(playback.isPlaying(clipURL), "the bar stays mounted while dragging")
        let knob = try? XCTUnwrap(drag.fraction)
        XCTAssertEqual(knob ?? 1, (65 - SettingsScrubDrag.endMargin) / 65, accuracy: 0.0001)

        drag.ended(atFraction: 1.4, duration: 65, playback: playback, url: clipURL)

        XCTAssertEqual(seeks.times, [65 - SettingsScrubDrag.endMargin])
        XCTAssertTrue(playback.isPlaying(clipURL), "the clip ends only by playing to its end")
        XCTAssertNil(drag.fraction)
    }

    func testHeldTargetStaysAtFiftySecondsWhenReadyDurationDoubles() {
        let seeks = SeekLog()
        let playback = recordingPlayback(currentTime: 20, duration: 200, seeks: seeks)
        playback.toggle(clipURL)
        var drag = SettingsScrubDrag()

        drag.changed(toFraction: 0.5, duration: 100, playback: playback, url: clipURL)
        let grownPosition = SettingsAudioPlaybackPosition(currentTime: 21, duration: 200)
        let shown = drag.previewPosition(grownPosition)
        XCTAssertEqual(shown.currentTime, 50)
        XCTAssertEqual(shown.duration, 200, "the ready total still updates")
        XCTAssertEqual(shown.fraction, 0.25, "the knob represents 50 seconds on the grown track")
        XCTAssertEqual(SettingsAudioPlaybackPosition.clockLabel(shown.currentTime), "0:50")
        XCTAssertEqual(shown.spokenValue, "50 seconds of 3 minutes 20 seconds")

        // A stationary pointer can still produce another changed callback after growth.
        drag.changed(toFraction: 0.5, duration: 200, playback: playback, url: clipURL)
        XCTAssertEqual(drag.previewPosition(grownPosition).currentTime, 50)
        XCTAssertEqual(seeks.times, [], "duration updates and drag previews never seek")
        drag.ended(atFraction: 0.5, duration: 200, playback: playback, url: clipURL)

        XCTAssertEqual(seeks.times, [50], "one release commits the original absolute target once")
        XCTAssertTrue(playback.isPlaying(clipURL))
        XCTAssertNil(drag.fraction)
        XCTAssertEqual(drag.previewPosition(grownPosition), grownPosition, "release returns to the sampled clock")
    }

    func testReleaseWithoutAnotherDragCallbackKeepsTheTargetThroughGrowth() {
        var drag = SettingsScrubDrag()
        var seeks: [TimeInterval] = []
        drag.changed(toFraction: 0.5, duration: 100)

        drag.ended(atFraction: 0.5, duration: 200, seek: { seeks.append($0) })

        XCTAssertEqual(seeks, [50])
    }

    func testPointerMovementAndReleaseUseTheOriginalGestureScaleAfterGrowth() {
        var drag = SettingsScrubDrag()
        var seeks: [TimeInterval] = []
        drag.changed(toFraction: 0.5, duration: 100)
        drag.changed(toFraction: 0.75, duration: 200)
        let shown = drag.previewPosition(SettingsAudioPlaybackPosition(currentTime: 20, duration: 200))
        XCTAssertEqual(shown.currentTime, 75, "movement deliberately changes the target on the 100-second scale")
        XCTAssertEqual(shown.fraction, 0.375)
        XCTAssertTrue(seeks.isEmpty)

        // Include final pointer movement delivered only by onEnded, and another duration update.
        drag.ended(atFraction: 0.8, duration: 300, seek: { seeks.append($0) })

        XCTAssertEqual(seeks, [80])
        XCTAssertNil(drag.fraction)
    }

    func testTheNextDragAndTrackClickUseTheNewCurrentDuration() {
        var drag = SettingsScrubDrag()
        var seeks: [TimeInterval] = []
        drag.changed(toFraction: 0.5, duration: 100)
        drag.ended(atFraction: 0.5, duration: 200, seek: { seeks.append($0) })

        drag.changed(toFraction: 0.5, duration: 200)
        XCTAssertEqual(drag.previewPosition(SettingsAudioPlaybackPosition(currentTime: 50, duration: 200)).currentTime, 100)
        XCTAssertEqual(seeks, [50])
        drag.ended(atFraction: 0.5, duration: 200, seek: { seeks.append($0) })
        drag.ended(atFraction: 0.25, duration: 80, seek: { seeks.append($0) })

        XCTAssertEqual(seeks, [50, 100, 20], "each new gesture rebases, including an end-only track click")
    }

    func testPreviewAndReleaseClampToShrunkenAvailabilityWithoutPointerMovement() {
        for duration in [TimeInterval(40), 0.05] {
            var drag = SettingsScrubDrag()
            var seeks: [TimeInterval] = []
            drag.changed(toFraction: 0.8, duration: 100)
            let shown = drag.previewPosition(SettingsAudioPlaybackPosition(currentTime: 20, duration: duration))
            let expected = max(duration - SettingsScrubDrag.endMargin, 0)
            XCTAssertEqual(shown.currentTime, expected)
            XCTAssertEqual(shown.duration, duration)
            XCTAssertLessThanOrEqual(shown.fraction, 1)
            XCTAssertTrue(seeks.isEmpty)

            drag.ended(atFraction: 0.8, duration: duration, seek: { seeks.append($0) })

            XCTAssertEqual(seeks, [expected], "release cannot seek audio that is no longer available")
        }
    }

    func testGrowingAvailabilityDoesNotExtendTheHeldGesturesEndMargin() {
        var drag = SettingsScrubDrag()
        var seeks: [TimeInterval] = []
        drag.changed(toFraction: 1.4, duration: 100)
        drag.changed(toFraction: 1.4, duration: 200)
        let shown = drag.previewPosition(SettingsAudioPlaybackPosition(currentTime: 20, duration: 200))
        XCTAssertEqual(shown.currentTime, 100 - SettingsScrubDrag.endMargin)
        XCTAssertTrue(seeks.isEmpty)

        drag.ended(atFraction: 1.4, duration: 200, seek: { seeks.append($0) })

        XCTAssertEqual(seeks, [100 - SettingsScrubDrag.endMargin])
    }

    func testFiniteClipDragsStillClampBothEndsAndCommitThePreview() {
        for (fraction, expected) in [(-0.5, 0.0), (0.25, 16.25), (1.0, 64.9), (1.4, 64.9)] {
            var drag = SettingsScrubDrag()
            var seeks: [TimeInterval] = []
            drag.changed(toFraction: fraction, duration: 65)
            let shown = drag.previewPosition(SettingsAudioPlaybackPosition(currentTime: 20, duration: 65))
            XCTAssertEqual(shown.currentTime, expected, accuracy: 0.0001)
            XCTAssertTrue(seeks.isEmpty)

            drag.ended(atFraction: fraction, duration: 65, seek: { seeks.append($0) })

            XCTAssertEqual(seeks, [shown.currentTime])
        }
    }

    func testInvalidDurationsDoNotDispatchAndReleaseClearsTheOldGestureScale() {
        for duration in [TimeInterval(0), -1, .nan, .infinity, -.infinity] {
            var drag = SettingsScrubDrag()
            var seeks: [TimeInterval] = []
            drag.changed(toFraction: 0.5, duration: duration)
            XCTAssertNil(drag.fraction, "invalid availability cannot start a gesture scale")
            drag.changed(toFraction: 0.5, duration: 100)
            drag.changed(toFraction: 0.9, duration: duration)
            XCTAssertEqual(drag.previewPosition(SettingsAudioPlaybackPosition(currentTime: 20, duration: 100)).currentTime, 50)
            XCTAssertEqual(drag.previewPosition(SettingsAudioPlaybackPosition(currentTime: 20, duration: duration)).currentTime, 0)

            drag.ended(atFraction: 0.5, duration: duration, seek: { seeks.append($0) })
            XCTAssertTrue(seeks.isEmpty)
            XCTAssertNil(drag.fraction)
            drag.changed(toFraction: 0.5, duration: 200)
            drag.ended(atFraction: 0.5, duration: 200, seek: { seeks.append($0) })
            XCTAssertEqual(seeks, [100])
        }
    }

    func testNonfinitePointerValuesDoNotDispatchOrPoisonTheNextDrag() {
        for fraction in [Double.nan, .infinity, -.infinity] {
            var drag = SettingsScrubDrag()
            var seeks: [TimeInterval] = []
            drag.changed(toFraction: fraction, duration: 100)
            XCTAssertNil(drag.fraction)
            drag.changed(toFraction: 0.5, duration: 100)
            drag.changed(toFraction: fraction, duration: 200)
            XCTAssertEqual(drag.previewPosition(SettingsAudioPlaybackPosition(currentTime: 20, duration: 200)).currentTime, 50)

            drag.ended(atFraction: fraction, duration: 200, seek: { seeks.append($0) })
            XCTAssertTrue(seeks.isEmpty)
            XCTAssertNil(drag.fraction)
            drag.changed(toFraction: 0.5, duration: 200)
            drag.ended(atFraction: 0.5, duration: 200, seek: { seeks.append($0) })
            XCTAssertEqual(seeks, [100])
        }
    }

    func testADragCannotSeekOrRestartItsHistoryClipAfterPlaybackSwitchesURL() {
        let seeks = SeekLog()
        let playback = recordingPlayback(currentTime: 20, duration: 200, seeks: seeks)
        playback.toggle(clipURL)
        var drag = SettingsScrubDrag()
        drag.changed(toFraction: 0.5, duration: 100, playback: playback, url: clipURL)
        let otherURL = URL(fileURLWithPath: "/tmp/other-recording/audio.wav")
        playback.toggle(otherURL)

        drag.ended(atFraction: 0.5, duration: 200, playback: playback, url: clipURL)

        XCTAssertEqual(seeks.times, [])
        XCTAssertTrue(playback.isPlaying(otherURL))
        XCTAssertFalse(playback.isPlaying(clipURL))
        XCTAssertNil(drag.fraction)
    }

    func testAKeyboardOrVoiceOverStepPastTheEndKeepsTheClipPlaying() {
        let seeks = SeekLog()
        let playback = recordingPlayback(currentTime: 63, duration: 65, seeks: seeks)
        playback.toggle(clipURL)

        SettingsScrubDrag.step(playback: playback, url: clipURL, by: 5)
        SettingsScrubDrag.step(playback: playback, url: clipURL, by: -500)

        XCTAssertEqual(seeks.times, [65 - SettingsScrubDrag.endMargin, 0])
        XCTAssertTrue(playback.isPlaying(clipURL), "VoiceOver focus stays on a mounted bar")
    }

    func testTheEndMarginNeverGoesBelowZeroOnAShortClip() {
        XCTAssertEqual(SettingsScrubDrag.clampedTime(5, duration: 0.05), 0)
        XCTAssertEqual(SettingsScrubDrag.clampedTime(-1, duration: 10), 0)
        XCTAssertEqual(SettingsScrubDrag.clampedTime(4, duration: 10), 4)
    }

    func testTheFillFollowsTheClipPosition() throws {
        let early = try renderBar(currentTime: 10, duration: 100)
        let late = try renderBar(currentTime: 90, duration: 100)
        let midX = early.pixelsWide / 2
        let midY = early.pixelsHigh / 2

        let earlyMid = try XCTUnwrap(early.colorAt(x: midX, y: midY))
        let lateMid = try XCTUnwrap(late.colorAt(x: midX, y: midY))

        // At 10 % the track's midpoint is unfilled; at 90 % it is the accent fill.
        XCTAssertGreaterThan(colorDistance(earlyMid, lateMid), 0.2)
    }

    // SCRUB1 R2 (Opus UI #1): the teleprompter track sits on the panel's centre axis, growing or not.
    func testTeleprompterTrackIsCentredAndGrowingDoesNotMoveIt() throws {
        func bitmap(time: Double, growing: Bool) throws -> NSBitmapImageRep {
            try render(SettingsPlaybackScrubBar(position: { SettingsAudioPlaybackPosition(currentTime: time, duration: 100) },
                seek: { _ in }, accessibilityNoun: "agent speech", isPlaying: false, isGrowing: growing,
                allowsSeeking: true, isTeleprompter: true).frame(width: 400, height: 24),
                size: CGSize(width: 400, height: 24), appearance: NSAppearance(named: .darkAqua))
        }
        func row(_ image: NSBitmapImageRep) -> [NSColor] {
            (0..<image.pixelsWide).map { image.colorAt(x: $0, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB) ?? .clear }
        }
        func fillStart(_ image: NSBitmapImageRep) throws -> Int {
            try XCTUnwrap(row(image).firstIndex { $0.blueComponent - $0.redComponent > 0.25 })
        }
        let full = try bitmap(time: 100, growing: false)
        let scale = CGFloat(full.pixelsWide) / 400
        let knob = row(full).indices.filter { index in
            let c = row(full)[index]
            return min(c.redComponent, c.greenComponent, c.blueComponent) > 0.68
        }
        let trackStart = CGFloat(try fillStart(full)), trackEnd = CGFloat(try XCTUnwrap(knob.first) + XCTUnwrap(knob.last)) / 2
        XCTAssertEqual((trackStart + trackEnd) / 2 / scale, 200, accuracy: 2, "track midpoint on the row's centre axis")
        XCTAssertEqual(try fillStart(bitmap(time: 50, growing: true)), try fillStart(bitmap(time: 50, growing: false)),
                       "the growing note must not widen one label slot")
    }

    private func scrubBitmap(time: Double, duration: Double, growing: Bool, isPlaying: Bool = false,
                             allowsSeeking: Bool = true, teleprompter: Bool = true,
                             width: CGFloat = 437) throws -> NSBitmapImageRep {
        try render(SettingsPlaybackScrubBar(position: { SettingsAudioPlaybackPosition(currentTime: time, duration: duration) },
            seek: { _ in }, accessibilityNoun: "agent speech", isPlaying: isPlaying, isGrowing: growing,
            allowsSeeking: allowsSeeking, isTeleprompter: teleprompter)
            .frame(width: width, height: 24).background(Color(white: 0.13)),
            size: CGSize(width: width, height: 24), appearance: NSAppearance(named: .darkAqua))
    }

    private func srgb(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
    }

    /// The minute and hour clock boundaries, growing and final.
    private let boundaryDurations: [TimeInterval] = [36, 599, 600, 3599, 3600, 35999, 36000]

    /// NOTCH2 (Etan: "Solid bar + 'so far'", no ellipsis): while the total grows, the track is the same solid
    /// bar as a final one, with no dotted tail, and "so far" sits next to the total. Final drops the label.
    func testGrowingTrackIsTheSolidFinalBarAndOnlyTheSoFarLabelDiffers() throws {
        XCTAssertEqual(SettingsPlaybackScrubBar.growingNote, "so far")
        let width: CGFloat = 437
        for duration in boundaryDurations {
            let label = "duration \(SettingsAudioPlaybackPosition.clockLabel(duration))"
            let growing = try scrubBitmap(time: duration / 2, duration: duration, growing: true)
            let final = try scrubBitmap(time: duration / 2, duration: duration, growing: false)
            let scale = CGFloat(final.pixelsWide) / width
            let slotWidth = SettingsPlaybackScrubBar.teleprompterLabelWidth(for: duration)
            // The whole track lane, between the label slots: identical pixels, so no reserved or dashed tail and
            // no change in track geometry when the total turns final.
            let slot = slotWidth + SettingsPlaybackScrubBar.teleprompterLabelSpacing
            let laneStart = Int(slot * scale), laneEnd = Int((width - slot) * scale)
            var differing = 0
            for y in 0..<final.pixelsHigh {
                for x in laneStart..<laneEnd where colorDistance(srgb(growing, x, y), srgb(final, x, y)) >= 0.02 {
                    differing += 1
                }
            }
            XCTAssertEqual(differing, 0, "\(label): the growing bar must be the solid final bar")
            // "so far" is ink right of the total; a final total has none there.
            let totalWidth = SettingsPlaybackScrubBar.teleprompterTextWidth(
                SettingsPlaybackScrubBar.teleprompterDurationLabel(duration), size: 10)
            let noteStart = Int((width - slotWidth + totalWidth + 2) * scale)
            func ink(_ image: NSBitmapImageRep, from start: Int) -> Int {
                var count = 0
                for y in 0..<image.pixelsHigh {
                    for x in start..<image.pixelsWide where srgb(image, x, y).brightnessComponent > 0.4 { count += 1 }
                }
                return count
            }
            XCTAssertGreaterThan(ink(growing, from: noteStart), 0, "\(label): growing shows \"so far\"")
            XCTAssertEqual(ink(final, from: noteStart), 0, "\(label): a final total has no label")
            // The whole label fits its slot: no ink reaches the bar's trailing edge, where the shell would clip it.
            XCTAssertEqual(ink(growing, from: growing.pixelsWide - Int(2 * scale)), 0, "\(label): \"so far\" clips")
        }
    }

    func testEachLabelSlotHoldsTheWidestLabelOfItsClockFormat() {
        for duration in boundaryDurations {
            let slot = SettingsPlaybackScrubBar.teleprompterLabelWidth(for: duration)
            let total = SettingsPlaybackScrubBar.teleprompterDurationLabel(duration)
            let growing = SettingsPlaybackScrubBar.teleprompterTextWidth(total, size: 10) +
                SettingsPlaybackScrubBar.teleprompterTextWidth(" so far", size: 9)
            XCTAssertLessThanOrEqual(growing, slot, "\(total) so far")
            // The leading slot shows the current time, never longer than the total.
            XCTAssertLessThanOrEqual(SettingsPlaybackScrubBar.teleprompterTextWidth(total, size: 10), slot, total)
        }
        XCTAssertEqual(SettingsPlaybackScrubBar.teleprompterLabelWidth(for: 36),
                       SettingsPlaybackScrubBar.teleprompterLabelWidth(for: 3599), "one width for every minute read")
        XCTAssertGreaterThanOrEqual(SettingsPlaybackScrubBar.teleprompterLabelWidth(for: 3600), 82.22,
                                    "Sol measured \"1:00:00 so far\" at 82.22 pt")
    }

    /// Etan (10-14, 10-20): "the dotted end of seek". No scrub state, teleprompter or Settings History, draws dots
    /// or dashes: along every row the bar's ink is one unbroken run.
    func testNoScrubStateDrawsADashOrDotPattern() throws {
        let states: [(String, Double, Double, Bool, Bool, Bool, Bool)] = [
            // name, time, duration, growing, playing, seekable, teleprompter
            ("growing", 12, 36, true, true, true, true),
            ("final", 12, 36, false, true, true, true),
            ("paused", 12, 36, false, false, true, true),
            ("ended", 36, 36, false, false, true, true),
            ("replay", 0, 36, false, true, true, true),
            ("untimed", 12, 36, false, true, false, true),
            ("hour growing", 1800, 3600, true, true, true, true),
            ("History", 12, 36, false, true, true, false),
            ("History growing", 12, 36, true, true, true, false),
        ]
        let width: CGFloat = 437
        for (name, time, duration, growing, playing, seekable, teleprompter) in states {
            let image = try scrubBitmap(time: time, duration: duration, growing: growing, isPlaying: playing,
                                        allowsSeeking: seekable, teleprompter: teleprompter, width: width)
            let scale = CGFloat(image.pixelsWide) / width
            let slot = teleprompter
                ? SettingsPlaybackScrubBar.teleprompterLabelWidth(for: duration) + SettingsPlaybackScrubBar.teleprompterLabelSpacing
                : 34 + 8
            // Teleprompter slots are fixed; History's labels hug their text, so start past the widest of them.
            let laneStart = Int((teleprompter ? slot : 60) * scale), laneEnd = Int((width - (teleprompter ? slot : 80)) * scale)
            let background = srgb(image, 1, 1)
            var inkRows = 0
            for y in 0..<image.pixelsHigh {
                let ink = (laneStart..<laneEnd).map { colorDistance(srgb(image, $0, y), background) > 0.01 }
                guard let first = ink.firstIndex(of: true), let last = ink.lastIndex(of: true) else { continue }
                inkRows += 1
                // A dash or dot pattern leaves background gaps inside the bar; a knob's antialiased ring leaves at
                // most one pixel. (The removed growing tail was 3 pt on, 3 pt off.)
                var gap = 0, widestGap = 0
                for index in first...last {
                    gap = ink[index] ? 0 : gap + 1
                    widestGap = max(widestGap, gap)
                }
                XCTAssertLessThan(widestGap, 2, "\(name): row \(y) has a \(widestGap) px gap, a dash or dot pattern")
            }
            XCTAssertGreaterThan(inkRows, 0, "\(name): no bar rendered")
        }
    }

    func testTeleprompterDurationLabelNeverReadsZeroForARealRead() {
        XCTAssertEqual(SettingsPlaybackScrubBar.teleprompterDurationLabel(0.8), "0:01")
        XCTAssertEqual(SettingsPlaybackScrubBar.teleprompterDurationLabel(18.3), "0:18")
        XCTAssertEqual(SettingsPlaybackScrubBar.teleprompterDurationLabel(0), "0:00")
    }

    func testCloneTrackIsUniformAcrossPlaybackPositions() throws {
        func bitmap(at time: Double) throws -> NSBitmapImageRep {
            try render(SettingsPlaybackScrubBar(position: { SettingsAudioPlaybackPosition(currentTime: time, duration: 100) },
                seek: { _ in }, accessibilityNoun: "agent speech", isPlaying: false,
                allowsSeeking: false, isTeleprompter: true).frame(width: 400, height: 24),
                size: CGSize(width: 400, height: 24), appearance: NSAppearance(named: .darkAqua))
        }
        let early = try bitmap(at: 10)
        let late = try bitmap(at: 90)
        let midX = early.pixelsWide / 2
        let midY = early.pixelsHigh / 2
        XCTAssertLessThan(colorDistance(try XCTUnwrap(early.colorAt(x: midX, y: midY)),
            try XCTUnwrap(late.colorAt(x: midX, y: midY))), 0.01, "untimed track must have no moving fill")
    }

    func testTheBarIsMountedOnlyUnderThePlayingPart() throws {
        let source = try source(named: "SettingsView.swift")

        XCTAssertTrue(source.contains(
            "if let audioPath = part.audioPath, historyPlayback.isPlaying(audioPath) {\n"
                + "                SettingsPlaybackScrubBar("
        ))
    }

    /// The bar samples the clock several times a second. SettingsView must never read the
    /// position itself, or every tick re-renders the whole Settings window.
    func testSettingsViewNeverSamplesThePlaybackPosition() throws {
        let source = try source(named: "SettingsView.swift")

        XCTAssertFalse(source.contains(".position(of:"))
        XCTAssertFalse(source.contains("TimelineView"))
    }

    func testWritesScrubBarArtifactsInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("design")
            .appendingPathComponent("2026-09-25-h1b-scrub")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for (scope, scopeName, playingURL) in [
            (SettingsHistoryScope.recording, "dictations", clipURL),
            (SettingsHistoryScope.ask, "ask", URL(fileURLWithPath: "/tmp/ask-latest/agent-audio.mp3")),
        ] {
            for (appearance, appearanceName) in [
                (NSAppearance(named: .aqua), "light"),
                (NSAppearance(named: .darkAqua), "dark"),
            ] {
                let playback = fakePlayback(currentTime: 23, duration: 65)
                playback.toggle(playingURL)
                let view = settingsView(scope: scope, playback: playback)
                    .frame(width: 900, height: 620)
                let bitmap = try render(view, size: CGSize(width: 900, height: 620), appearance: appearance)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: outputDirectory.appendingPathComponent("history-\(scopeName)-playing-\(appearanceName).png"),
                    options: .atomic
                )
            }
        }
    }

    // MARK: - Helpers

    private func fakePlayback(currentTime: TimeInterval, duration: TimeInterval) -> SettingsAudioPlayback {
        SettingsAudioPlayback(
            start: { _ in true },
            stop: {},
            position: { SettingsAudioPlaybackPosition(currentTime: currentTime, duration: duration) },
            seek: { _ in }
        )
    }

    private func recordingPlayback(
        currentTime: TimeInterval,
        duration: TimeInterval,
        seeks: SeekLog
    ) -> SettingsAudioPlayback {
        SettingsAudioPlayback(
            start: { _ in true },
            stop: {},
            position: { SettingsAudioPlaybackPosition(currentTime: currentTime, duration: duration) },
            seek: { seeks.times.append($0) }
        )
    }

    private func renderBar(currentTime: TimeInterval, duration: TimeInterval) throws -> NSBitmapImageRep {
        let playback = fakePlayback(currentTime: currentTime, duration: duration)
        playback.toggle(clipURL)
        // Both time labels share one min width, so the track's midpoint is the image's midpoint.
        let bar = SettingsPlaybackScrubBar(playback: playback, url: clipURL, accessibilityNoun: "recording audio")
            .frame(width: 400, height: 20)
        return try render(bar, size: CGSize(width: 400, height: 20), appearance: NSAppearance(named: .aqua))
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance?) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else { return 0 }
        return abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    private func settingsView(scope: SettingsHistoryScope, playback: SettingsAudioPlayback) -> SettingsView {
        let askGroups = [
            SettingsAskHistoryDayGroup(
                dayKey: "2026-09-25",
                date: Self.sampleDate(hour: 0),
                entries: [
                    SettingsAskHistoryEntry(
                        id: "/tmp/ask-latest",
                        dayKey: "2026-09-25",
                        askID: "2026-09-25T09-40-00-000Z-latest",
                        createdAt: Self.sampleDate(hour: 9, minute: 40),
                        questionText: "Do you want the scrub bar under the clip or next to Play?",
                        questionAudioPath: URL(fileURLWithPath: "/tmp/ask-latest/agent-audio.mp3"),
                        responseTranscript: "Under the clip, full width, so I can drag it.",
                        responseAudioPath: URL(fileURLWithPath: "/tmp/ask-latest/audio.wav")
                    ),
                ]
            ),
        ]
        return SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")] },
            selectedDeviceID: { "built-in" },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            initialHistoryPage: SettingsHistoryPage(
                groups: [
                    SettingsHistoryDayGroup(
                        dayKey: "2026-09-25",
                        date: Self.sampleDate(hour: 0),
                        entries: [
                            SettingsHistoryEntry(
                                id: clipURL.path,
                                dayKey: "2026-09-25",
                                recordingID: "2026-09-25T09-30-00-000Z-latest",
                                createdAt: Self.sampleDate(hour: 9, minute: 30),
                                transcript: "History playback finally has a scrub bar I can drag.",
                                audioPath: clipURL
                            ),
                        ]
                    ),
                ],
                hasMore: false
            ),
            askHistoryPage: { _ in SettingsAskHistoryPage(groups: askGroups, hasMore: false) },
            initialAskHistoryPage: SettingsAskHistoryPage(groups: askGroups, hasMore: false),
            initialTab: .history,
            initialHistoryScope: scope,
            historyPlayback: playback
        )
    }

    private static func sampleDate(hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 9
        components.day = 25
        components.hour = hour
        components.minute = minute
        return components.date ?? Date(timeIntervalSince1970: 0)
    }

    private func source(named name: String) throws -> String {
        try String(
            contentsOf: repoRoot()
                .appendingPathComponent("flow-bar/Sources/VoiceBarUI")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class SeekLog {
    var times: [TimeInterval] = []
}
