@testable import VoiceBarUI
import XCTest

/// P16: the pill's pause/play control while VoiceBar speaks (Etan, 2026-10-18).
@MainActor
final class PlaybackPauseTests: XCTestCase {
    private var now: TimeInterval = 100

    private func speakingState(text: String = "One two three four five six") -> (VoiceState, () -> [[String: Any]]) {
        let state = VoiceState(playbackAmplitudeClock: { [unowned self] in now })
        state.isConnected = true
        state.isCollapsed = false
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        state.handleEvent(["type": "state", "state": "speaking", "text": text, "duration_ms": 6000])
        return (state, { sent })
    }

    private func pausedEvent(offset: Int = 2500, word: Int = 2) -> [String: Any] {
        [
            "type": "playback_state", "state": "paused", "playback_id": "playback-7", "generation": 3,
            "offset_ms": offset, "chunk_offset_ms": offset, "duration_ms": 6000,
            "word_index": word, "word_count": 6,
        ]
    }

    // MARK: - Visibility per mode

    func testControlShowsOnlyWhileSpeakingOrPaused() {
        let speaking = VoiceBarPresentation.playbackPauseControl(mode: .speaking, isPaused: false, isReadback: false)
        XCTAssertEqual(speaking?.iconName, "pause.fill")
        XCTAssertEqual(speaking?.accessibilityLabel, "Pause speech")

        let paused = VoiceBarPresentation.playbackPauseControl(mode: .speaking, isPaused: true, isReadback: false)
        XCTAssertEqual(paused?.iconName, "play.fill")
        XCTAssertEqual(paused?.accessibilityLabel, "Resume speech")

        for mode in [VoiceMode.idle, .recording, .transcribing, .error, .disconnected] {
            XCTAssertNil(
                VoiceBarPresentation.playbackPauseControl(mode: mode, isPaused: false, isReadback: false),
                "no pause control in \(mode)"
            )
        }
        // An ended readback is idle: nothing is playing, so there is nothing to pause.
        XCTAssertNil(VoiceBarPresentation.playbackPauseControl(mode: .idle, isPaused: false, isReadback: true))
    }

    func testPillHitTargetIsAtLeast24Points() {
        XCTAssertGreaterThanOrEqual(VoiceBarPillControlButton.hitDiameter, 24)
    }

    // MARK: - Commands

    func testClickWhileSpeakingSendsPauseWithTheTeleprompterClock() {
        let (state, sent) = speakingState()
        now += 2.4
        state.togglePlaybackPause()

        let command = sent().last
        XCTAssertEqual(command?["cmd"] as? String, "pause")
        XCTAssertEqual(command?["playback_elapsed_ms"] as? Int, 2400)
        XCTAssertNotNil(command?["id"] as? String)
    }

    func testClickWhilePausedSendsResumeWithThePausedIdentity() {
        let (state, sent) = speakingState()
        state.handleEvent(pausedEvent())
        state.togglePlaybackPause()

        let command = sent().last
        XCTAssertEqual(command?["cmd"] as? String, "resume")
        XCTAssertEqual(command?["playback_id"] as? String, "playback-7")
        XCTAssertEqual(command?["generation"] as? Int, 3)
    }

    func testToggleOutsideSpeakingSendsNothing() {
        let state = VoiceState()
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        for mode in [VoiceMode.idle, .recording, .transcribing] {
            state.mode = mode
            state.togglePlaybackPause()
        }
        XCTAssertTrue(sent.isEmpty)
    }

    func testRejectedPauseExplainsItselfAndKeepsPlaying() {
        let (state, sent) = speakingState()
        state.togglePlaybackPause()
        let id = sent().last?["id"] as? String
        state.handleEvent(["type": "ack", "command": "pause", "id": id as Any, "outcome": "reject", "reason": "unsupported"])

        XCTAssertFalse(state.isPlaybackPaused)
        XCTAssertEqual(state.confirmationText, "This prompt can't be paused")
    }

    // MARK: - Paused state, collapse and expand

    func testPausedEventFreezesTheClockAtTheDaemonOffset() {
        let (state, _) = speakingState()
        now += 2.6
        state.handleEvent(pausedEvent(offset: 2500))
        XCTAssertTrue(state.isPlaybackPaused)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 2500)

        now += 90
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 2500, "a paused read's clock must not run")
        XCTAssertEqual(state.playbackAudioLevel(), 0)
    }

    func testPauseCollapsesTheTeleprompterAndResumeExpandsIt() {
        let (state, _) = speakingState()
        XCTAssertEqual(presentation(for: state).visualState, .teleprompter)

        state.handleEvent(pausedEvent())
        let paused = presentation(for: state)
        XCTAssertEqual(paused.visualState, .compactStatus)
        // Paused shows play + stop only; the eye button belongs to a hidden-but-playing read.
        XCTAssertEqual(
            paused.geometry.trailingWingWidth,
            VoiceBarNotchContract.compactStatusDefaultTrailingWingWidth
        )

        resume(state, offset: 2500)
        XCTAssertFalse(state.isPlaybackPaused)
        XCTAssertEqual(presentation(for: state).visualState, .teleprompter)
    }

    func testPauseToggleNotifiesPanelLayout() {
        let (state, _) = speakingState()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05)) // drain the speaking edge's own notices
        let changed = expectation(description: "panel layout re-resolves on pause")
        changed.assertForOverFulfill = false
        state.onPanelLayoutChange = { changed.fulfill() }
        state.handleEvent(pausedEvent())
        wait(for: [changed], timeout: 1)
    }

    func testResumeContinuesFromThePausedWordWithItsTimings() {
        let (state, _) = speakingState()
        let words = (0 ..< 6).map { ["offset_ms": $0 * 1000, "duration_ms": 800, "text": "w\($0)"] as [String: Any] }
        state.handleEvent(["type": "subtitle", "words": words])
        let timings = state.wordBoundaries
        XCTAssertEqual(timings.count, 6)

        now += 2.5
        state.handleEvent(pausedEvent(offset: 2500))
        now += 30
        resume(state, offset: 2500)

        XCTAssertEqual(state.wordBoundaries, timings, "WORDTIME1 timings survive the pause")
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 2500)
        now += 1
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 3500, "the clock runs again from the paused word")
    }

    func testLeavingSpeakingClearsThePause() {
        let (state, _) = speakingState()
        state.handleEvent(pausedEvent())
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertFalse(state.isPlaybackPaused)

        let (recording, _) = speakingState()
        recording.handleEvent(pausedEvent())
        recording.handleEvent(["type": "state", "state": "recording"])
        XCTAssertFalse(recording.isPlaybackPaused)
    }

    func testStopWhilePausedRetainsTheReadbackAtThePausedPosition() {
        let (state, _) = speakingState()
        state.handleEvent(pausedEvent(offset: 2500))
        now += 40
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertTrue(state.isTeleprompterReadback)
        XCTAssertEqual(state.teleprompterPlaybackPosition.currentTime, 2.5, accuracy: 0.001)
    }

    // MARK: - Geometry

    func testSpeakingTeleprompterGrowsALeadingWingForTheControl() {
        let (state, _) = speakingState()
        let speaking = presentation(for: state)
        XCTAssertEqual(speaking.geometry.leadingWingWidth, VoiceBarNotchContract.teleprompterPauseWingWidth)
        XCTAssertGreaterThanOrEqual(
            VoiceBarNotchContract.teleprompterPauseWingWidth,
            WaveformLayout.coreGap + VoiceBarNotchContract.material.compactControlSize
        )

        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertTrue(state.isTeleprompterReadback)
        XCTAssertEqual(presentation(for: state).geometry.leadingWingWidth, 0, "a readback has nothing to pause")
    }

    // MARK: - Helpers

    private func resume(_ state: VoiceState, offset: Int) {
        state.handleEvent([
            "type": "state", "state": "speaking", "text": state.teleprompterText ?? "",
            "playback_offset_ms": offset, "duration_ms": 6000,
        ])
        state.handleEvent([
            "type": "playback_state", "state": "resumed", "playback_id": "playback-7", "generation": 4,
            "offset_ms": offset, "chunk_offset_ms": offset,
        ])
    }

    private func presentation(for state: VoiceState) -> VoiceBarNotchPresentation {
        VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: state.mode,
            hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isTeleprompterReadback: state.isTeleprompterReadback,
            isPlaybackPaused: state.isPlaybackPaused,
            isCollapsed: state.isCollapsed
        ))
    }
}
