import Foundation
@testable import VoiceBar
import VoiceBarUI
import XCTest

/// Lane B (2.4): the five qa-fixture-2.4-* providers present real VoiceState states, and the production controls they
/// expose send production commands (REVIEW-813 contract). Native XCUI runs of the same flows are M1-only.
@MainActor
final class UIE2EPlaybackFixturesTests: XCTestCase {
    private func model() throws -> (UIE2EModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        return (UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path])), root)
    }

    func testSpeakingProviderPausesResumesAndSeeksAWordThroughProductionCommands() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.fixture("2.4-speaking")
        XCTAssertEqual(model.events.last, "fixture:2.4-speaking")
        XCTAssertEqual(model.voice.mode, .speaking)
        XCTAssertGreaterThanOrEqual(model.voice.speechWords?.words.count ?? 0, 3)

        model.voice.togglePlaybackPause()
        XCTAssertTrue(model.events.contains("command:pause"))
        XCTAssertTrue(model.voice.isPlaybackPaused, "the host acks pause so the paused state is real")
        model.voice.togglePlaybackPause()
        XCTAssertTrue(model.events.contains("command:resume"))
        XCTAssertFalse(model.voice.isPlaybackPaused, "the host acks resume so the paused state clears")

        // qa-word-2's action: the production word click.
        model.voice.seekSpeechWord(utteranceID: model.voice.speechWords!.utteranceID, wordIndex: 2)
        XCTAssertEqual(model.events.last, "command:speech_seek")
    }

    func testReadbackProviderKeepsTheTextAndReplaySendsReplay() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.fixture("2.4-readback")
        XCTAssertEqual(model.events.last, "fixture:2.4-readback")
        XCTAssertTrue(model.voice.isTeleprompterReadback)
        model.voice.sendCommand?(["cmd": "replay", "id": "qa"])
        XCTAssertTrue(model.events.contains("command:replay"))
    }

    func testNarrationProvidersShowNarrationLayerAsTheOriginWithAWordTable() throws {
        for name in ["2.4-narration-speak", "2.4-narration-ask", "2.4-narration-read"] {
            let (model, root) = try model()
            defer { try? FileManager.default.removeItem(at: root) }
            model.fixture(name)
            XCTAssertEqual(model.events.last, "fixture:\(name)")
            XCTAssertEqual(model.voice.mode, .speaking, name)
            XCTAssertEqual(model.voice.narrationOrigin, "NarrationLayer", name)
            XCTAssertGreaterThanOrEqual(model.voice.speechWords?.words.count ?? 0, 3, "\(name): qa-word-2 exists")
        }
    }

    func testSpeedAndPreviousControlsAreAnswered() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.fixture("2.4-speaking")
        model.voice.cyclePlaybackSpeed()
        XCTAssertTrue(model.events.contains("command:set_playback_speed"))
        XCTAssertEqual(model.voice.playbackSpeed, 1.25)
        XCTAssertTrue(model.voice.previousReadAvailable)
        model.voice.playPreviousRead()
        XCTAssertTrue(model.events.contains("command:previous_read"))
    }
}
