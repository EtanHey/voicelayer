import AppKit
@testable import VoiceBar
import VoiceBarUI
import XCTest

@MainActor
final class UIE2EPlaybackFixtureTests: XCTestCase {
    func testPauseResumeAndWordSeekChangeRealVoiceState() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        model.fixture("speaking")
        model.voice.togglePlaybackPause()
        XCTAssertTrue(model.voice.isPlaybackPaused)
        model.voice.togglePlaybackPause()
        XCTAssertFalse(model.voice.isPlaybackPaused)
        model.voice.handleEvent(["type": "speech_words", "utteranceId": "qa-utterance", "wordOffset": 0,
            "words": [["text": "First", "startMs": 0, "endMs": 10_000],
                      ["text": "QA", "startMs": 10_000, "endMs": 20_000]]])
        model.voice.seekSpeechWord(utteranceID: "qa-utterance", wordIndex: 1)
        XCTAssertEqual(model.voice.speechWords?.wordIndex(atMilliseconds: model.voice.playbackElapsedMilliseconds()), 1)
    }
}
