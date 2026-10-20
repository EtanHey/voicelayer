@testable import VoiceBarUI
import XCTest

/// P16: the pill's pause/play control while VoiceBar speaks (Etan, 2026-10-18).
@MainActor
final class PlaybackPauseTests: XCTestCase {
    private var now: TimeInterval = 100

    private func speakingState(
        text: String = "One two three four five six",
        playbackID: String = "playback-7"
    ) -> (VoiceState, () -> [[String: Any]]) {
        let state = VoiceState(playbackAmplitudeClock: { [unowned self] in now })
        state.isConnected = true
        state.isCollapsed = false
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        state.handleEvent(speakingEvent(text: text, playbackID: playbackID))
        return (state, { sent })
    }

    private func speakingEvent(
        text: String = "One two three four five six",
        playbackID: String = "playback-7",
        generation: Int = 2,
        offset: Int? = nil
    ) -> [String: Any] {
        var event: [String: Any] = [
            "type": "state", "state": "speaking", "text": text, "duration_ms": 6000,
            "playback_id": playbackID, "generation": generation,
        ]
        if let offset { event["playback_offset_ms"] = offset }
        return event
    }

    private func pausedEvent(
        offset: Int = 2500,
        word: Int = 2,
        playbackID: String = "playback-7",
        generation: Int = 3
    ) -> [String: Any] {
        [
            "type": "playback_state", "state": "paused", "playback_id": playbackID, "generation": generation,
            "offset_ms": offset, "chunk_offset_ms": offset, "duration_ms": 6000,
            "word_index": word, "word_count": 6,
        ]
    }

    private func resumedEvent(playbackID: String = "playback-7", generation: Int = 4, offset: Int = 2500) -> [String: Any] {
        [
            "type": "playback_state", "state": "resumed", "playback_id": playbackID, "generation": generation,
            "offset_ms": offset, "chunk_offset_ms": offset,
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
        XCTAssertEqual(command?["playback_id"] as? String, "playback-7", "Pause is scoped to the player on screen")
        XCTAssertEqual(command?["generation"] as? Int, 2)
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

    func testPlaybackIdleOrDisconnectRetiresThePark() {
        let (state, _) = speakingState()
        state.handleEvent(pausedEvent())
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertFalse(state.isPlaybackPaused)
        drainMainQueue()
        XCTAssertEqual(state.mode, .idle)

        let (other, _) = speakingState()
        other.handleEvent(pausedEvent())
        other.mode = .disconnected
        other.mode = .idle
        drainMainQueue()
        XCTAssertEqual(other.mode, .idle, "a disconnect retires the park")
    }

    // MARK: - S2: the park survives a capture

    func testCaptureHidesTheControlKeepsTheParkAndPlayReturnsOnTheSameWord() {
        let (state, sent) = speakingState()
        let words = (0 ..< 6).map { ["offset_ms": $0 * 1000, "duration_ms": 800, "text": "w\($0)"] as [String: Any] }
        state.handleEvent(["type": "subtitle", "words": words])
        let timings = state.wordBoundaries
        state.handleEvent(pausedEvent(offset: 2500))

        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        XCTAssertEqual(state.mode, .recording)
        XCTAssertFalse(state.isPlaybackPaused)
        XCTAssertNil(VoiceBarPresentation.playbackPauseControl(
            mode: state.mode, isPaused: state.isPlaybackPaused, isReadback: state.isTeleprompterReadback
        ), "no playback control during capture")
        state.mode = .transcribing
        XCTAssertNil(VoiceBarPresentation.playbackPauseControl(mode: state.mode, isPaused: false, isReadback: false))

        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        drainMainQueue()
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertTrue(state.isPlaybackPaused, "Play is back after the capture")
        XCTAssertEqual(state.teleprompterText, "One two three four five six")
        XCTAssertEqual(state.wordBoundaries, timings)
        now += 60
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 2500, "the same word, still frozen")
        XCTAssertFalse(sent().contains { $0["cmd"] as? String == "resume" }, "never auto-resumes")

        state.togglePlaybackPause()
        XCTAssertEqual(sent().last?["cmd"] as? String, "resume")
        XCTAssertEqual(sent().last?["playback_id"] as? String, "playback-7")
        XCTAssertEqual(sent().last?["generation"] as? Int, 3)
    }

    func testPausedConfirmationLandingMidCaptureStillParksTheRead() {
        let (state, sent) = speakingState()
        now += 1.8
        state.togglePlaybackPause()
        XCTAssertEqual(sent().last?["cmd"] as? String, "pause")
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": false])
        state.handleEvent(pausedEvent(offset: 1800))
        XCTAssertFalse(state.isPlaybackPaused)

        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        drainMainQueue()
        XCTAssertTrue(state.isPlaybackPaused)
        XCTAssertEqual(state.teleprompterText, "One two three four five six")
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 1800)
    }

    func testStopOrReplacementDuringCaptureRetiresThePark() {
        let (stopped, _) = speakingState()
        stopped.handleEvent(pausedEvent())
        stopped.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        stopped.handleEvent(["type": "playback_outcome", "playback_id": "playback-7", "status": "interrupted", "reason": "replaced"])
        stopped.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        drainMainQueue()
        XCTAssertEqual(stopped.mode, .idle)
        XCTAssertFalse(stopped.isPlaybackPaused)
    }

    func testRestoreWaitsForTheDictationsOwnFeedback() {
        let (state, _) = speakingState()
        state.handleEvent(pausedEvent())
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        state.confirmationText = "Pasted"
        drainMainQueue()
        XCTAssertEqual(state.mode, .idle, "the paste note keeps the surface")
        state.confirmationText = nil
        drainMainQueue()
        XCTAssertTrue(state.isPlaybackPaused)
    }

    // MARK: - S3: controls bind to the player on screen

    func testStalePausedForARetiredReadNeverParksTheNewOne() {
        let (state, sent) = speakingState(playbackID: "playback-A")
        state.togglePlaybackPause()
        // Stop → new read B, then A's late confirmation.
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.handleEvent(speakingEvent(text: "Different new read", playbackID: "playback-B"))
        now += 2
        state.handleEvent(pausedEvent(offset: 900, playbackID: "playback-A"))
        XCTAssertFalse(state.isPlaybackPaused)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 2000, "B's clock keeps running")
        XCTAssertEqual(presentation(for: state).visualState, .teleprompter)

        state.togglePlaybackPause()
        XCTAssertEqual(sent().last?["cmd"] as? String, "pause")
        XCTAssertEqual(sent().last?["playback_id"] as? String, "playback-B")
    }

    func testStaleResumedNeverUnpausesANewerPause() {
        let (state, _) = speakingState(playbackID: "playback-A")
        state.handleEvent(speakingEvent(text: "Read B", playbackID: "playback-B"))
        state.handleEvent(pausedEvent(playbackID: "playback-B"))
        state.handleEvent(resumedEvent(playbackID: "playback-A"))
        XCTAssertTrue(state.isPlaybackPaused)
        // An older generation of the same player is retired too.
        state.handleEvent(resumedEvent(playbackID: "playback-B", generation: 1))
        XCTAssertTrue(state.isPlaybackPaused)
    }

    func testPauseAfterAReplacementTargetsTheReplacement() {
        let (state, sent) = speakingState(playbackID: "playback-A")
        state.handleEvent(speakingEvent(text: "Replacement", playbackID: "playback-C", generation: 1))
        state.togglePlaybackPause()
        XCTAssertEqual(sent().last?["playback_id"] as? String, "playback-C")
        XCTAssertEqual(sent().last?["generation"] as? Int, 1)
    }

    func testRepeatedClicksAcrossATransitionKeepTheirOwnScope() {
        let (state, sent) = speakingState(playbackID: "playback-A")
        state.togglePlaybackPause()
        state.togglePlaybackPause() // a second click before the confirmation: still a scoped Pause of A
        XCTAssertEqual(sent().suffix(2).map { $0["cmd"] as? String }, ["pause", "pause"])
        XCTAssertEqual(sent().suffix(2).map { $0["playback_id"] as? String }, ["playback-A", "playback-A"])
        state.handleEvent(speakingEvent(text: "Next chunk", playbackID: "playback-B"))
        state.togglePlaybackPause()
        XCTAssertEqual(sent().last?["playback_id"] as? String, "playback-B")
        state.handleEvent(pausedEvent(playbackID: "playback-A"))
        XCTAssertFalse(state.isPlaybackPaused, "A's late confirmation does not park B")
        state.handleEvent(pausedEvent(playbackID: "playback-B"))
        XCTAssertTrue(state.isPlaybackPaused)
        state.togglePlaybackPause()
        XCTAssertEqual(sent().last?["cmd"] as? String, "resume")
        XCTAssertEqual(sent().last?["playback_id"] as? String, "playback-B")
        XCTAssertEqual(sent().last?["generation"] as? Int, 3)
    }

    func testDaemonWithoutSpeakingIdentityAcceptsOnlyItsOwnPauseConfirmation() {
        let state = VoiceState(playbackAmplitudeClock: { [unowned self] in now })
        state.isConnected = true
        state.sendCommand = { _ in }
        state.handleEvent(["type": "state", "state": "speaking", "text": "Old daemon read"])
        state.handleEvent(pausedEvent())
        XCTAssertFalse(state.isPlaybackPaused, "an unrequested paused event is not ours")
        state.togglePlaybackPause()
        state.handleEvent(pausedEvent())
        XCTAssertTrue(state.isPlaybackPaused)
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

    /// Etan, 2026-10-20: "centered like the idle hover state has the microphone". The pause slot is the
    /// mic's slot: same lane width, same insets, same distance from the core, in every speaking layout.
    func testPauseGlyphSlotMatchesTheIdleHoverMicrophone() {
        let (state, _) = speakingState()
        let mic = VoiceBarPresentation.notchPresentation(from: .init(mode: .idle, isHovered: true))
        XCTAssertEqual(mic.visualState, .hoverLauncher)
        let material = VoiceBarNotchContract.material
        let micSlot = material.wingContentLayout(for: .leading, state: mic.visualState)

        let teleprompter = presentation(for: state)
        state.dismissTeleprompter()
        let compact = presentation(for: state)
        for speaking in [teleprompter, compact] {
            XCTAssertEqual(speaking.geometry.leadingWingWidth, mic.geometry.leadingWingWidth, "\(speaking.visualState)")
            XCTAssertEqual(material.wingContentLayout(for: .leading, state: speaking.visualState), micSlot)
            let micLayout = VoiceBarNotchShapeLayout(geometry: mic.geometry)
            let layout = VoiceBarNotchShapeLayout(geometry: speaking.geometry)
            XCTAssertEqual(
                layout.coreRect.minX - layout.leadingWingRect.minX,
                micLayout.coreRect.minX - micLayout.leadingWingRect.minX
            )
        }
        state.showTeleprompter()

        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertTrue(state.isTeleprompterReadback)
        XCTAssertEqual(presentation(for: state).geometry.leadingWingWidth, 0, "a readback has nothing to pause")
    }

    // MARK: - Helpers

    private func resume(_ state: VoiceState, offset: Int) {
        state.handleEvent(speakingEvent(text: state.teleprompterText ?? "", generation: 4, offset: offset))
        state.handleEvent(resumedEvent(offset: offset))
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
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
