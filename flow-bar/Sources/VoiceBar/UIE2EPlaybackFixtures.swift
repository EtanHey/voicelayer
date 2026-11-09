#if VOICEBAR_QA
import SwiftUI
import VoiceBarUI

/// Lane B (2.4) providers for the E2E suite (#813, contract in REVIEW-813 § Fixture contract): speaking, readback
/// and narration-speak/ask/read. Synthetic only: no device, no audio, nothing written outside VOICEBAR_UIE2E_ROOT.
/// Each presents its state through VoiceState.handleEvent, exactly the events the daemon sends, so the production
/// BarView/TeleprompterAView renders it and its controls send real commands (`command:<production cmd>`).
extension UIE2EModel {
    static let playbackFixtures = ["2.4-speaking", "2.4-readback", "2.4-narration-speak", "2.4-narration-ask", "2.4-narration-read"]

    private static let qaWords = ["First", "QA", "word", "table"]
    private static let qaUtterance = "qa-utterance"
    private static let qaPlayback = "qa-playback"

    /// Presents one Lane B provider. False for any other name (the host's own fixtures handle those).
    func applyPlaybackFixture(_ name: String) -> Bool {
        switch name {
        case "2.4-speaking":
            speakWordTable(text: Self.qaWords.joined(separator: " "), source: nil, longRead: false)
        case "2.4-readback":
            // The retained readback: a finished read the teleprompter keeps, with Replay.
            speakWordTable(text: Self.qaWords.joined(separator: " "), source: nil, longRead: false)
            voice.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        case "2.4-narration-speak":
            speakWordTable(text: "QA agent status update", source: "narrationlayer", longRead: false)
        case "2.4-narration-ask":
            speakWordTable(text: "QA question for you?", source: "narrationlayer", longRead: false)
        case "2.4-narration-read":
            // Transport is NOT proved here: this is the edge NarrationLayer would send, rendered by production UI.
            speakWordTable(text: "QA long read text", source: "narrationlayer", longRead: true)
        default:
            return false
        }
        return true
    }

    /// The speaking edge plus its speech_words table (≥ 3 words), so every word is a `qa-word-<i>` button that seeks.
    private func speakWordTable(text: String, source: String?, longRead: Bool, offsetMs: Int = 0, generation: Int = 1) {
        let words = text.split(separator: " ").map(String.init)
        voice.isHovering = true
        var edge: [String: Any] = ["type": "state", "state": "speaking", "text": text, "utteranceId": Self.qaUtterance,
                                   "playback_id": Self.qaPlayback, "generation": generation, "playback_offset_ms": offsetMs,
                                   "duration_ms": words.count * 1000, "chunk_duration_ms": words.count * 1000,
                                   "readback_id": "qa-readback"]
        if let source { edge["narration_source"] = source }
        if longRead { edge["long_read"] = ["id": Self.qaUtterance, "chunk_index": 0, "chunk_count": 1, "chunk_start_ms": 0] }
        voice.handleEvent(edge)
        voice.handleEvent(["type": "speech_words", "utteranceId": Self.qaUtterance, "wordOffset": 0, "approximate": false,
                           "words": words.enumerated().map { ["text": $1, "startMs": $0 * 1000, "endMs": $0 * 1000 + 800] }])
    }

    /// Synthetic daemon answers for the playback commands these providers' controls send. Proves the UI dispatch
    /// and its state transitions, never daemon admission or audio. False for every other command.
    func answerPlaybackCommand(_ cmd: String, _ message: [String: Any]) -> Bool {
        guard playbackFixturePresented else { return false }
        let id = message["id"] ?? ""
        switch cmd {
        case "pause":
            voice.handleEvent(["type": "ack", "command": cmd, "id": id, "outcome": "accept", "offset_ms": 2000])
            voice.handleEvent(["type": "playback_state", "state": "paused", "playback_id": Self.qaPlayback, "generation": 2,
                               "offset_ms": 2000, "chunk_offset_ms": 2000, "pause_owner": "user", "word_index": 2, "word_count": 4])
        case "resume":
            voice.handleEvent(["type": "ack", "command": cmd, "id": id, "outcome": "accept", "offset_ms": 2000])
            speakWordTable(text: Self.qaWords.joined(separator: " "), source: nil, longRead: false, offsetMs: 2000, generation: 3)
            voice.handleEvent(["type": "playback_state", "state": "resumed", "playback_id": Self.qaPlayback, "generation": 3,
                               "offset_ms": 2000, "chunk_offset_ms": 2000, "word_index": 2, "word_count": 4])
        case "speech_seek", "previous_read":
            voice.handleEvent(["type": "ack", "command": cmd, "id": id, "outcome": "accept"])
        case "set_playback_speed":
            voice.handleEvent(["type": "ack", "command": cmd, "id": id, "outcome": "accept"])
            voice.handleEvent(["type": "playback_session", "speed": message["speed"] ?? 1, "previous_available": true])
        default:
            return false
        }
        return true
    }
}

extension UIE2EHost {
    /// One Settings row of Lane B providers (identifier `qa-fixture-<name>`).
    func playbackFixtureRow() -> some View {
        HStack {
            ForEach(UIE2EModel.playbackFixtures, id: \.self) { name in
                Button(name) { self.model.fixture(name) }.accessibilityIdentifier("qa-fixture-\(name)")
            }
        }.controlSize(.small).padding(2)
    }
}
#endif
