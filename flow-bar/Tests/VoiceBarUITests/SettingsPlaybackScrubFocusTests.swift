import SwiftUI
@testable import VoiceBarUI
import XCTest

/// #199: a mouse scrub on the History timeline left the system focus ring around the bar until something else
/// took focus. After a pointer scrub the bar draws no ring, yet ←/→ still step; focus that arrives any other way
/// (Tab, VoiceOver) keeps the ring.
///
/// Deterministic by design: these drive `SettingsScrubDrag`, the same handler the bar's DragGesture calls, and pin
/// how the view wires it. Synthetic drags never reach the gesture on the headless CI runner (#200 run
/// 36452576587), and offscreen Tab cannot move SwiftUI focus, so the real ring stays an installed-app check.
@MainActor
final class SettingsPlaybackScrubFocusTests: XCTestCase {
    private let clipURL = URL(fileURLWithPath: "/tmp/fixture/recording/audio.wav")

    func testAMouseScrubHidesTheFocusRingWhileTheBarKeepsFocus() {
        let seeks = SeekLog()
        let playback = playback(seeks: seeks)
        var drag = SettingsScrubDrag()
        XCTAssertFalse(drag.hidesFocusRing, "before any scrub, Tab focus shows the ring")

        drag.changed(toFraction: 0.3, duration: 100, playback: playback, url: clipURL)
        drag.focusChanged(to: true) // the gesture focuses the bar
        drag.changed(toFraction: 0.6, duration: 100, playback: playback, url: clipURL)
        drag.ended(atFraction: 0.6, duration: 100, playback: playback, url: clipURL)

        XCTAssertEqual(seeks.times, [60], "the scrub still seeks once on release")
        XCTAssertTrue(drag.hidesFocusRing, "a mouse scrub must not leave a focus ring")

        drag.focusChanged(to: true)
        XCTAssertTrue(drag.hidesFocusRing, "staying focused for ←/→ keeps the ring hidden")
    }

    func testArrowKeysStillStepAfterAScrub() {
        let seeks = SeekLog()
        let playback = playback(seeks: seeks)
        var drag = SettingsScrubDrag()
        drag.changed(toFraction: 0.5, duration: 100, playback: playback, url: clipURL)
        drag.ended(atFraction: 0.5, duration: 100, playback: playback, url: clipURL)
        seeks.times.removeAll()

        SettingsScrubDrag.step(
            playback: playback,
            url: clipURL,
            by: SettingsPlaybackScrubBar.seekDelta(for: .rightArrow) ?? 0
        )
        SettingsScrubDrag.step(
            playback: playback,
            url: clipURL,
            by: SettingsPlaybackScrubBar.seekDelta(for: .leftArrow) ?? 0
        )

        XCTAssertEqual(seeks.times, [25, 15])
        XCTAssertTrue(drag.hidesFocusRing, "a key step does not bring the ring back")
    }

    func testTheRingReturnsOnceFocusLeaves() {
        let playback = playback(seeks: SeekLog())
        var drag = SettingsScrubDrag()
        drag.changed(toFraction: 0.5, duration: 100, playback: playback, url: clipURL)
        drag.focusChanged(to: true)

        drag.focusChanged(to: false)
        XCTAssertFalse(drag.hidesFocusRing, "focus left the bar")

        drag.focusChanged(to: true)
        XCTAssertFalse(drag.hidesFocusRing, "focus that comes back by Tab shows the ring")
    }

    func testTabFocusAloneKeepsTheRing() {
        var drag = SettingsScrubDrag()
        drag.focusChanged(to: true)
        XCTAssertFalse(drag.hidesFocusRing)
    }

    func testAScrubWhileTabFocusedHidesTheRing() {
        let playback = playback(seeks: SeekLog())
        var drag = SettingsScrubDrag()
        drag.focusChanged(to: true)

        drag.changed(toFraction: 0.5, duration: 100, playback: playback, url: clipURL)

        XCTAssertTrue(drag.hidesFocusRing, "like a click on a native control after Tab focus")
    }

    func testAScrubOverAClipWithNoDurationYetStillHidesTheRing() {
        let playback = playback(seeks: SeekLog())
        var drag = SettingsScrubDrag()

        drag.changed(toFraction: 0.5, duration: 0, playback: playback, url: clipURL)

        XCTAssertTrue(drag.hidesFocusRing, "the gesture focuses the bar even before the clip reports a duration")
        XCTAssertNil(drag.fraction)
    }

    /// The view side, which offscreen tests cannot drive: the gesture focuses the bar and feeds `changed`, the
    /// focus effect reads the drag state, focus changes reach it, and VoiceOver's adjustable action is unchanged.
    func testTheBarWiresTheDragStateToItsFocusEffect() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/VoiceBarUI/SettingsPlaybackScrubBar.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("""
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled(drag.hidesFocusRing)
                .onChange(of: isFocused) { _, focused in drag.focusChanged(to: focused) }
        """))
        XCTAssertTrue(source.contains("""
                            .onChanged { value in
                                isFocused = true
                                drag.changed(
        """))
        XCTAssertTrue(source.contains("""
                    .accessibilityAdjustableAction { direction in
                        SettingsScrubDrag.step(playback: playback, url: url, by: Self.seekDelta(for: direction))
                    }
        """))
    }

    // MARK: - Helpers

    private func playback(seeks: SeekLog) -> SettingsAudioPlayback {
        let playback = SettingsAudioPlayback(
            start: { _ in true },
            stop: {},
            position: { SettingsAudioPlaybackPosition(currentTime: 20, duration: 100) },
            seek: { seeks.times.append($0) }
        )
        playback.toggle(clipURL)
        return playback
    }
}

private final class SeekLog {
    var times: [TimeInterval] = []
}
