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

    private func playback(_ recorder: Recorder) -> SettingsAudioPlayback {
        SettingsAudioPlayback(
            start: { url in recorder.start(url) },
            stop: { recorder.stop() }
        )
    }

    private final class Recorder {
        var started: [URL] = []
        var stopCount = 0
        var startSucceeds = true

        func start(_ url: URL) -> Bool {
            guard startSucceeds else { return false }
            started.append(url)
            return true
        }

        func stop() {
            stopCount += 1
        }
    }
}
