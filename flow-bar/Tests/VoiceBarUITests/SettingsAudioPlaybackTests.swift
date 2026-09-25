@testable import VoiceBarUI
import XCTest

@MainActor
final class SettingsAudioPlaybackTests: XCTestCase {
    private let recordingURL = URL(fileURLWithPath: "/tmp/voicelayer-recording/audio.wav")
    private let questionURL = URL(fileURLWithPath: "/tmp/voicelayer-ask/agent-audio.mp3")
    private let responseURL = URL(fileURLWithPath: "/tmp/voicelayer-ask/audio.wav")

    func testTogglingAClipStartsIt() {
        let recorder = Recorder()
        let playback = playback(recorder)

        playback.toggle(questionURL)

        XCTAssertEqual(recorder.started, [questionURL])
        XCTAssertTrue(playback.isPlaying(questionURL))
        XCTAssertFalse(playback.isPlaying(responseURL))
    }

    func testTogglingTheSameClipStopsIt() {
        let recorder = Recorder()
        let playback = playback(recorder)

        playback.toggle(questionURL)
        playback.toggle(questionURL)

        XCTAssertEqual(recorder.started, [questionURL])
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertNil(playback.playingURL)
    }

    func testTogglingTheOtherSideStopsTheFirstAndStartsTheSecond() {
        let recorder = Recorder()
        let playback = playback(recorder)

        playback.toggle(questionURL)
        playback.toggle(responseURL)

        XCTAssertEqual(recorder.started, [questionURL, responseURL])
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertTrue(playback.isPlaying(responseURL))
        XCTAssertFalse(playback.isPlaying(questionURL))
    }

    func testRecordingQuestionAndResponseShareOnePlaybackSession() {
        let recorder = Recorder()
        let playback = playback(recorder)

        playback.toggle(recordingURL)
        playback.toggle(questionURL)
        playback.toggle(responseURL)

        XCTAssertEqual(recorder.started, [recordingURL, questionURL, responseURL])
        XCTAssertEqual(recorder.stopCount, 2)
        XCTAssertFalse(playback.isPlaying(recordingURL))
        XCTAssertFalse(playback.isPlaying(questionURL))
        XCTAssertTrue(playback.isPlaying(responseURL))
    }

    func testFailedStartLeavesNothingPlaying() {
        let recorder = Recorder()
        recorder.startSucceeds = false
        let playback = playback(recorder)

        playback.toggle(questionURL)

        XCTAssertNil(playback.playingURL)
        XCTAssertFalse(playback.isPlaying(questionURL))
    }

    func testFinishingPlaybackClearsTheActiveClip() {
        let recorder = Recorder()
        let playback = playback(recorder)

        playback.toggle(questionURL)
        playback.playbackDidFinish(questionURL)

        XCTAssertNil(playback.playingURL)
    }

    func testFinishingAStaleClipDoesNotClearTheActiveOne() {
        let recorder = Recorder()
        let playback = playback(recorder)

        playback.toggle(questionURL)
        playback.playbackDidFinish(responseURL)

        XCTAssertTrue(playback.isPlaying(questionURL))
    }

    func testStopIsANoOpWhenNothingIsPlaying() {
        let recorder = Recorder()
        let playback = playback(recorder)

        playback.stop()

        XCTAssertEqual(recorder.stopCount, 0)
        XCTAssertNil(playback.playingURL)
    }

    // MARK: - H1-b: position + seek (the shared player model the scrub bar and, later,

    // word-level click-to-seek both drive)

    func testPositionIsReportedOnlyForTheClipPlaying() {
        let recorder = Recorder()
        recorder.position = SettingsAudioPlaybackPosition(currentTime: 12, duration: 65)
        let playback = playback(recorder)

        XCTAssertNil(playback.position(of: questionURL))
        playback.toggle(questionURL)

        XCTAssertEqual(playback.position(of: questionURL)?.currentTime, 12)
        XCTAssertEqual(playback.position(of: questionURL)?.duration, 65)
        XCTAssertNil(playback.position(of: responseURL))
    }

    func testSeekMovesThePlayingClip() {
        let recorder = Recorder()
        recorder.position = SettingsAudioPlaybackPosition(currentTime: 3, duration: 65)
        let playback = playback(recorder)
        playback.toggle(questionURL)

        playback.seek(questionURL, to: 40)

        XCTAssertEqual(recorder.seeks, [40])
        XCTAssertEqual(recorder.started, [questionURL])
    }

    func testSeekClampsBelowZero() {
        let recorder = Recorder()
        recorder.position = SettingsAudioPlaybackPosition(currentTime: 3, duration: 65)
        let playback = playback(recorder)
        playback.toggle(questionURL)

        playback.seek(questionURL, to: -4)

        XCTAssertEqual(recorder.seeks, [0])
    }

    func testSeekingToTheEndFinishesTheClip() {
        let recorder = Recorder()
        recorder.position = SettingsAudioPlaybackPosition(currentTime: 3, duration: 65)
        let playback = playback(recorder)
        playback.toggle(questionURL)

        playback.seek(questionURL, to: 400)

        XCTAssertEqual(recorder.seeks, [])
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertNil(playback.playingURL)
    }

    func testSeekingAClipThatIsNotPlayingDoesNothing() {
        let recorder = Recorder()
        recorder.position = SettingsAudioPlaybackPosition(currentTime: 0, duration: 65)
        let playback = playback(recorder)
        playback.toggle(questionURL)

        playback.seek(responseURL, to: 20)

        XCTAssertEqual(recorder.started, [questionURL])
        XCTAssertEqual(recorder.seeks, [])
        XCTAssertTrue(playback.isPlaying(questionURL))
    }

    func testPlayFromATimeStartsTheClipThere() {
        let recorder = Recorder()
        recorder.position = SettingsAudioPlaybackPosition(currentTime: 0, duration: 65)
        let playback = playback(recorder)
        playback.toggle(questionURL)

        playback.play(responseURL, from: 20)
        playback.play(responseURL, from: 30)

        XCTAssertEqual(recorder.started, [questionURL, responseURL])
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(recorder.seeks, [20, 30])
        XCTAssertTrue(playback.isPlaying(responseURL))
    }

    func testPlayFromATimeWhenTheStartFailsSeeksNothing() {
        let recorder = Recorder()
        recorder.startSucceeds = false
        let playback = playback(recorder)

        playback.play(questionURL, from: 20)

        XCTAssertEqual(recorder.seeks, [])
        XCTAssertNil(playback.playingURL)
    }

    func testSkipStepsFromTheCurrentTime() {
        let recorder = Recorder()
        recorder.position = SettingsAudioPlaybackPosition(currentTime: 12, duration: 65)
        let playback = playback(recorder)
        playback.toggle(questionURL)

        playback.skip(questionURL, by: SettingsAudioPlayback.keyboardSeekStep)
        playback.skip(questionURL, by: -SettingsAudioPlayback.keyboardSeekStep)

        XCTAssertEqual(SettingsAudioPlayback.keyboardSeekStep, 5)
        XCTAssertEqual(recorder.seeks, [17, 12])
    }

    func testSkipOnAClipThatIsNotPlayingDoesNothing() {
        let recorder = Recorder()
        recorder.position = SettingsAudioPlaybackPosition(currentTime: 12, duration: 65)
        let playback = playback(recorder)
        playback.toggle(questionURL)

        playback.skip(responseURL, by: 5)

        XCTAssertEqual(recorder.seeks, [])
        XCTAssertTrue(playback.isPlaying(questionURL))
    }

    func testPositionLabelsAndSpokenValue() {
        let position = SettingsAudioPlaybackPosition(currentTime: 12.7, duration: 65.2)
        XCTAssertEqual(SettingsAudioPlaybackPosition.clockLabel(12.7), "0:12")
        XCTAssertEqual(SettingsAudioPlaybackPosition.clockLabel(65.2), "1:05")
        XCTAssertEqual(SettingsAudioPlaybackPosition.clockLabel(3725), "1:02:05")
        XCTAssertEqual(SettingsAudioPlaybackPosition.clockLabel(-3), "0:00")
        XCTAssertEqual(SettingsAudioPlaybackPosition.clockLabel(.nan), "0:00")
        XCTAssertEqual(position.fraction, 12.7 / 65.2, accuracy: 0.0001)
        XCTAssertEqual(SettingsAudioPlaybackPosition(currentTime: 3, duration: 0).fraction, 0)
        XCTAssertEqual(SettingsAudioPlaybackPosition(currentTime: 90, duration: 60).fraction, 1)
        // VoiceOver reads "0:12" digit by digit, so the adjustable value is spoken in words.
        XCTAssertEqual(position.spokenValue, "12 seconds of 1 minute 5 seconds")
        XCTAssertEqual(
            SettingsAudioPlaybackPosition(currentTime: 0, duration: 3661).spokenValue,
            "0 seconds of 1 hour 1 minute 1 second"
        )
    }

    /// #159 Macroscope 4100260791: a finite but huge time (a corrupt duration) must not trap converting to Int.
    func testHugeFiniteTimesClampInsteadOfTrapping() {
        let huge = Double.greatestFiniteMagnitude
        XCTAssertEqual(SettingsAudioPlaybackPosition.clockLabel(huge), "2777:46:39")
        XCTAssertEqual(
            SettingsAudioPlaybackPosition(currentTime: huge, duration: huge).spokenValue,
            "2777 hours 46 minutes 39 seconds of 2777 hours 46 minutes 39 seconds"
        )
    }

    func testTimeForAFractionOfTheTrack() {
        let position = SettingsAudioPlaybackPosition(currentTime: 0, duration: 80)
        XCTAssertEqual(position.time(atFraction: 0.25), 20)
        XCTAssertEqual(position.time(atFraction: -1), 0)
        XCTAssertEqual(position.time(atFraction: 2), 80)
    }

    private func playback(_ recorder: Recorder) -> SettingsAudioPlayback {
        SettingsAudioPlayback(
            start: { url in recorder.start(url) },
            stop: { recorder.stop() },
            position: { recorder.position },
            seek: { time in recorder.seek(time) }
        )
    }

    private final class Recorder {
        var started: [URL] = []
        var stopCount = 0
        var startSucceeds = true
        var position: SettingsAudioPlaybackPosition?
        var seeks: [TimeInterval] = []

        func start(_ url: URL) -> Bool {
            guard startSucceeds else { return false }
            started.append(url)
            return true
        }

        func stop() {
            stopCount += 1
        }

        func seek(_ time: TimeInterval) {
            seeks.append(time)
            if let position {
                self.position = SettingsAudioPlaybackPosition(currentTime: time, duration: position.duration)
            }
        }
    }
}
