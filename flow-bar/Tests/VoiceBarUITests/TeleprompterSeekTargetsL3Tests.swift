import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C7 L3 V09, reported 2026-11-11 at 26–31 s: repeated clicks on a word in a numbered list did
/// not seek while a nearby word did. The fixture is the daemon's own payload for that text: its structured display
/// (projectStructuredSpeech + structuredReadDisplay) and its speech_words table (SpeechWordTimeline), generated from
/// src/tts so the client sees exactly what the daemon sends.
@MainActor
final class TeleprompterSeekTargetsL3Tests: XCTestCase {
    static let payload = #"""
{"text": "Your next step: paste and post the discussion. The text is open in TextEdit, and Helium is on the new Ideas discussion page for pingdotgg/t3code.\n1. Copy the title, \"Voice on mobile: transcribe with a Mac custom speech endpoint\", into the title field.\n2. Copy the body from TextEdit into the body field.\n3. Press Start discussion.\nIdle threads:", "display": {"version": 1, "text": "Your next step: paste and post the discussion. The text is open in TextEdit, and Helium is on the new Ideas discussion page for pingdotgg/t3code.\n1. Copy the title, \"Voice on mobile: transcribe with a Mac custom speech endpoint\", into the title field.\n2. Copy the body from TextEdit into the body field.\n3. Press Start discussion.\nIdle threads:", "speech_start": 0, "blocks": [{"kind": "paragraph", "source": {"start": 0, "end": 146}, "speech": {"start": 0, "end": 145}, "ranges": [{"source": {"start": 0, "end": 145}, "display": {"start": 0, "end": 145}, "speech": {"start": 0, "end": 145}, "kind": "identity"}], "word_start": 0, "word_end": 25, "section_id": "section:0", "starts_block": true, "starts_section": true}, {"kind": "list-item", "source": {"start": 147, "end": 253}, "speech": {"start": 146, "end": 251}, "ranges": [{"source": {"start": 147, "end": 252}, "display": {"start": 147, "end": 252}, "speech": {"start": 146, "end": 251}, "kind": "identity"}], "word_start": 25, "word_end": 43, "section_id": "section:0", "starts_block": true, "starts_section": false}, {"kind": "list-item", "source": {"start": 253, "end": 305}, "speech": {"start": 252, "end": 303}, "ranges": [{"source": {"start": 253, "end": 304}, "display": {"start": 253, "end": 304}, "speech": {"start": 252, "end": 303}, "kind": "identity"}], "word_start": 43, "word_end": 53, "section_id": "section:0", "starts_block": true, "starts_section": false}, {"kind": "list-item", "source": {"start": 305, "end": 332}, "speech": {"start": 304, "end": 330}, "ranges": [{"source": {"start": 305, "end": 331}, "display": {"start": 305, "end": 331}, "speech": {"start": 304, "end": 330}, "kind": "identity"}], "word_start": 53, "word_end": 57, "section_id": "section:0", "starts_block": true, "starts_section": false}, {"kind": "paragraph", "source": {"start": 333, "end": 346}, "speech": {"start": 331, "end": 344}, "ranges": [{"source": {"start": 333, "end": 346}, "display": {"start": 333, "end": 346}, "speech": {"start": 331, "end": 344}, "kind": "identity"}], "word_start": 57, "word_end": 59, "section_id": "section:0", "starts_block": true, "starts_section": false}]}, "words": {"type": "speech_words", "utteranceId": "u-v09", "wordOffset": 0, "approximate": true, "words": [{"text": "Your", "startMs": 0, "endMs": 661.0169491525423}, {"text": "next", "startMs": 661.0169491525423, "endMs": 1322.0338983050847}, {"text": "step:", "startMs": 1322.0338983050847, "endMs": 1983.050847457627}, {"text": "paste", "startMs": 1983.050847457627, "endMs": 2644.0677966101694}, {"text": "and", "startMs": 2644.0677966101694, "endMs": 3305.084745762712}, {"text": "post", "startMs": 3305.084745762712, "endMs": 3966.101694915254}, {"text": "the", "startMs": 3966.101694915254, "endMs": 4627.118644067797}, {"text": "discussion.", "startMs": 4627.118644067797, "endMs": 5288.135593220339}, {"text": "The", "startMs": 5288.135593220339, "endMs": 5949.152542372882}, {"text": "text", "startMs": 5949.152542372882, "endMs": 6610.169491525424}, {"text": "is", "startMs": 6610.169491525424, "endMs": 7271.186440677966}, {"text": "open", "startMs": 7271.186440677966, "endMs": 7932.203389830508}, {"text": "in", "startMs": 7932.203389830508, "endMs": 8593.22033898305}, {"text": "TextEdit,", "startMs": 8593.22033898305, "endMs": 9254.237288135593}, {"text": "and", "startMs": 9254.237288135593, "endMs": 9915.254237288136}, {"text": "Helium", "startMs": 9915.254237288136, "endMs": 10576.271186440677}, {"text": "is", "startMs": 10576.271186440677, "endMs": 11237.28813559322}, {"text": "on", "startMs": 11237.28813559322, "endMs": 11898.305084745763}, {"text": "the", "startMs": 11898.305084745763, "endMs": 12559.322033898305}, {"text": "new", "startMs": 12559.322033898305, "endMs": 13220.338983050848}, {"text": "Ideas", "startMs": 13220.338983050848, "endMs": 13881.35593220339}, {"text": "discussion", "startMs": 13881.35593220339, "endMs": 14542.372881355932}, {"text": "page", "startMs": 14542.372881355932, "endMs": 15203.389830508475}, {"text": "for", "startMs": 15203.389830508475, "endMs": 15864.406779661016}, {"text": "pingdotgg/t3code.", "startMs": 15864.406779661016, "endMs": 16525.42372881356}, {"text": "1.", "startMs": 16525.42372881356, "endMs": 17186.4406779661}, {"text": "Copy", "startMs": 17186.4406779661, "endMs": 17847.457627118645}, {"text": "the", "startMs": 17847.457627118645, "endMs": 18508.474576271186}, {"text": "title,", "startMs": 18508.474576271186, "endMs": 19169.491525423728}, {"text": "\"Voice", "startMs": 19169.491525423728, "endMs": 19830.508474576272}, {"text": "on", "startMs": 19830.508474576272, "endMs": 20491.525423728814}, {"text": "mobile:", "startMs": 20491.525423728814, "endMs": 21152.542372881355}, {"text": "transcribe", "startMs": 21152.542372881355, "endMs": 21813.5593220339}, {"text": "with", "startMs": 21813.5593220339, "endMs": 22474.57627118644}, {"text": "a", "startMs": 22474.57627118644, "endMs": 23135.593220338982}, {"text": "Mac", "startMs": 23135.593220338982, "endMs": 23796.610169491527}, {"text": "custom", "startMs": 23796.610169491527, "endMs": 24457.627118644068}, {"text": "speech", "startMs": 24457.627118644068, "endMs": 25118.64406779661}, {"text": "endpoint\",", "startMs": 25118.64406779661, "endMs": 25779.661016949154}, {"text": "into", "startMs": 25779.661016949154, "endMs": 26440.677966101695}, {"text": "the", "startMs": 26440.677966101695, "endMs": 27101.694915254237}, {"text": "title", "startMs": 27101.694915254237, "endMs": 27762.71186440678}, {"text": "field.", "startMs": 27762.71186440678, "endMs": 28423.728813559323}, {"text": "2.", "startMs": 28423.728813559323, "endMs": 29084.745762711864}, {"text": "Copy", "startMs": 29084.745762711864, "endMs": 29745.762711864405}, {"text": "the", "startMs": 29745.762711864405, "endMs": 30406.77966101695}, {"text": "body", "startMs": 30406.77966101695, "endMs": 31067.79661016949}, {"text": "from", "startMs": 31067.79661016949, "endMs": 31728.813559322032}, {"text": "TextEdit", "startMs": 31728.813559322032, "endMs": 32389.830508474577}, {"text": "into", "startMs": 32389.830508474577, "endMs": 33050.84745762712}, {"text": "the", "startMs": 33050.84745762712, "endMs": 33711.86440677966}, {"text": "body", "startMs": 33711.86440677966, "endMs": 34372.8813559322}, {"text": "field.", "startMs": 34372.8813559322, "endMs": 35033.898305084746}, {"text": "3.", "startMs": 35033.898305084746, "endMs": 35694.91525423729}, {"text": "Press", "startMs": 35694.91525423729, "endMs": 36355.93220338983}, {"text": "Start", "startMs": 36355.93220338983, "endMs": 37016.94915254237}, {"text": "discussion.", "startMs": 37016.94915254237, "endMs": 37677.96610169492}, {"text": "Idle", "startMs": 37677.96610169492, "endMs": 38338.983050847455}, {"text": "threads:", "startMs": 38338.983050847455, "endMs": 39000}]}}
"""#

    private var sent: [[String: Any]] = []

    /// The daemon times a long read chunk by chunk as it synthesizes; until a chunk is ready, its words have no
    /// entry in the table. `timedWords` keeps only the synthesized prefix.
    private func fixtureState(timedWords: Int? = nil) throws -> VoiceState {
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Self.payload.utf8)) as? [String: Any])
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        state.isConnected = true
        state.isCollapsed = false
        state.sendCommand = { [unowned self] in sent.append($0) }
        let text = try XCTUnwrap(fixture["text"] as? String)
        state.handleEvent(["type": "state", "state": "speaking", "text": text, "duration_ms": 39_000,
                           "playback_id": "v09", "generation": 1, "utteranceId": "u-v09",
                           "long_read": ["id": "u-v09", "chunk_index": 0, "chunk_count": 1, "chunk_start_ms": 0,
                                         "display": fixture["display"] as Any]])
        var words = try XCTUnwrap(fixture["words"] as? [String: Any])
        if let timedWords, let rows = words["words"] as? [[String: Any]] { words["words"] = Array(rows.prefix(timedWords)) }
        state.handleEvent(words)
        return state
    }

    private func model(_ state: VoiceState) throws -> TeleprompterAModel {
        TeleprompterAModelCache().model(text: try XCTUnwrap(state.teleprompterText),
                                        boundaries: state.teleprompterWordBoundaries,
                                        blocks: state.teleprompterDisplayBlocks,
                                        complete: state.teleprompterHasCompleteDisplay,
                                        column: TeleprompterA.columnWidth)
    }

    /// Every drawn word of a multi-line read is a seek target while playing: first and last words of lines, words
    /// with punctuation and quotes, list items, and words before or after the spoken position.
    func testEveryWordOfTheReadIsASeekTarget() throws {
        let state = try fixtureState()
        XCTAssertNotNil(state.speechWords, "the daemon's table arrived")
        let model = try model(state)
        XCTAssertGreaterThan(model.lines.count, 3, "a multi-line fixture")
        let dead = model.layouts.indices.filter { model.seekTarget(for: $0, table: state.speechWords) == nil }
            .map { "\($0):\(model.layouts[$0].displayText)" }
        XCTAssertEqual(dead, [], "words with no seek target")
    }

    /// V09: at 0:03 only the first chunk was timed, so "Copy" (word 26, the next chunk) had no target and repeated
    /// clicks did nothing, while "title," seeked at 0:06 once its chunk was timed. Every drawn word of the current
    /// read is a target even before its chunk is timed.
    func testWordsAheadOfTheTimedPrefixAreStillSeekTargets() throws {
        let state = try fixtureState(timedWords: 25)
        let model = try model(state)
        let dead = model.layouts.indices.filter { model.seekTarget(for: $0, table: state.speechWords) == nil }
            .map { "\($0):\(model.layouts[$0].displayText)" }
        XCTAssertEqual(dead, [], "words with no seek target while the read is still synthesizing")
    }

    /// A click on a word not yet timed seeks the moment the daemon times it, and never to a different word.
    func testAClickAheadSeeksWhenItsTimingArrives() throws {
        let state = try fixtureState(timedWords: 25)
        let model = try model(state)
        let copy = try XCTUnwrap(model.layouts.indices.first { model.layouts[$0].displayText == "Copy" })
        guard case let .word(utterance, index)? = model.seekTarget(for: copy, table: state.speechWords) else {
            return XCTFail("Copy is a word target")
        }
        sent = []
        state.seekSpeechWord(utteranceID: utterance, wordIndex: index)
        XCTAssertTrue(sent.filter { $0["cmd"] as? String == "speech_seek" }.isEmpty,
                      "the daemon refuses untimed words, so nothing is sent yet")
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Self.payload.utf8)) as? [String: Any])
        var words = try XCTUnwrap(fixture["words"] as? [String: Any])
        words["wordOffset"] = 25
        words["words"] = Array(try XCTUnwrap(words["words"] as? [[String: Any]]).dropFirst(25))
        state.handleEvent(words)
        let seeks = sent.filter { $0["cmd"] as? String == "speech_seek" }
        XCTAssertEqual(seeks.count, 1, "one seek once Copy is timed")
        XCTAssertEqual(seeks.first?["wordIndex"] as? Int, index)
        XCTAssertEqual(seeks.first?["utteranceId"] as? String, "u-v09")
        state.handleEvent(words)
        XCTAssertEqual(sent.filter { $0["cmd"] as? String == "speech_seek" }.count, 1, "never twice")
    }

    /// A pending click belongs to its read: pausing, or another read arriving, drops it.
    func testAPendingClickIsDroppedByPauseOrANewRead() throws {
        let state = try fixtureState(timedWords: 25)
        state.seekSpeechWord(utteranceID: "u-v09", wordIndex: 26)
        state.handleEvent(["type": "state", "state": "speaking", "text": "Another read entirely", "duration_ms": 3000,
                           "playback_id": "other", "generation": 1, "utteranceId": "u-other"])
        sent = []
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Self.payload.utf8)) as? [String: Any])
        state.handleEvent(try XCTUnwrap(fixture["words"] as? [String: Any]))
        XCTAssertTrue(sent.filter { $0["cmd"] as? String == "speech_seek" }.isEmpty, "the old read's click never fires")
    }
}
