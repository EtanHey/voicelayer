import XCTest
@testable import VoiceBarUI

@MainActor
final class CompletedReplayDisplayTests: XCTestCase {
    private func displayFixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bun", "-e", """
            import {projectStructuredSpeech} from './src/tts/structured-speech';
            import {structuredReadDisplay} from './src/tts/structured-display';
            const source = '## Release notes\\n\\n**Fixed:** שלום client/server.\\n\\n' +
                Array.from({length:45}, (_,i) => (i+1)+'. Item '+i+' keeps its formatting after completion.').join('\\n') +
                '\\n\\n```ts\\nconst answer = 42;\\n```';
            const projection = projectStructuredSpeech(source);
            process.stdout.write(JSON.stringify(structuredReadDisplay(projection, [projection.speechText], 400)[0]));
            """]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func render(_ state: VoiceState) -> TeleprompterRenderedDocument {
        TeleprompterRenderCache().document(text: state.teleprompterText ?? "",
            wordBoundaries: state.teleprompterWordBoundaries,
            displayBlocks: state.teleprompterDisplayBlocks,
            hasCompleteDisplay: state.teleprompterHasCompleteDisplay)
    }

    func testCompletedReplayKeepsLiveBlocksThroughTimingPauseAndReadback() throws {
        let display = try displayFixture()
        let text = try XCTUnwrap(display["text"] as? String)
        XCTAssertGreaterThan(text.count, 2000)
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
            "long_read": ["id": "original", "preparing": true, "text": text,
                "chunk_index": 0, "chunk_count": 1, "chunk_start_ms": 0,
                "chunk_word_starts": [0], "display": display]])
        state.handleEvent(["type": "state", "state": "speaking", "text": text,
            "long_read": ["id": "original", "chunk_index": 0, "chunk_count": 1,
                "chunk_start_ms": 0, "display": display]])
        let liveBlocks = state.teleprompterDisplayBlocks
        let live = render(state)
        XCTAssertTrue(liveBlocks.contains { $0.kind == "heading" })
        XCTAssertTrue(liveBlocks.contains { $0.kind == "list-item" })
        XCTAssertTrue(liveBlocks.contains { $0.kind == "code" })
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertEqual(state.teleprompterDisplayBlocks, liveBlocks)
        state.dismissRetainedTeleprompter()
        XCTAssertNil(state.teleprompterText)
        state.replay()
        state.handleEvent(["type": "state", "state": "speaking", "text": text, "display": display,
            "playback_id": "completed-replay", "generation": 1, "duration_ms": 10_000])
        XCTAssertEqual(state.teleprompterText, text)
        XCTAssertEqual(state.teleprompterDisplayBlocks, liveBlocks)
        XCTAssertEqual(render(state).layouts, live.layouts)
        state.handleEvent(["type": "subtitle", "words": [
            ["text": "Release", "offset_ms": 0, "duration_ms": 100]]])
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "completed-replay",
            "generation": 1, "offset_ms": 100, "chunk_offset_ms": 100])
        XCTAssertTrue(state.isPlaybackPaused)
        XCTAssertEqual(state.teleprompterDisplayBlocks, liveBlocks)
        XCTAssertEqual(render(state).layouts, live.layouts)
        state.handleEvent(["type": "state", "state": "speaking", "text": text, "display": display,
            "playback_id": "completed-replay", "generation": 2, "playback_offset_ms": 100])
        state.handleEvent(["type": "playback_state", "state": "resumed", "playback_id": "completed-replay",
            "generation": 2, "offset_ms": 100, "chunk_offset_ms": 100])
        XCTAssertFalse(state.isPlaybackPaused)
        XCTAssertEqual(state.teleprompterDisplayBlocks, liveBlocks)
        XCTAssertEqual(render(state).layouts, live.layouts)
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertEqual(state.teleprompterDisplayBlocks, liveBlocks)
    }

    func testReplayRejectsMismatchedDisplayAndClearsItForLegacySpeech() throws {
        let display = try displayFixture()
        let text = try XCTUnwrap(display["text"] as? String)
        let state = VoiceState()
        state.handleEvent(["type": "state", "state": "speaking", "text": text, "display": display])
        XCTAssertFalse(state.teleprompterDisplayBlocks.isEmpty)
        state.handleEvent(["type": "state", "state": "speaking", "text": "Other speech.", "display": display])
        XCTAssertTrue(state.teleprompterDisplayBlocks.isEmpty)
        state.handleEvent(["type": "state", "state": "speaking", "text": "Legacy speech."])
        XCTAssertEqual(state.teleprompterText, "Legacy speech.")
        XCTAssertTrue(state.teleprompterDisplayBlocks.isEmpty)
    }
}
