import XCTest
@testable import VoiceBarUI

@MainActor
final class TeleprompterStructuredDisplayTests: XCTestCase {
    // Wire fixture for captured "2. Alpha.\n3. Beta.", legacy speech "Alpha. Beta.".
    private func fixture() -> [String: Any] {
        func span(_ start: Int, _ end: Int) -> [String: Int] { ["start": start, "end": end] }
        func block(_ word: Int, _ start: Int, _ end: Int, _ sourceStart: Int, _ sourceEnd: Int) -> [String: Any] {
            ["kind": "list-item", "source": span(sourceStart, word == 0 ? sourceEnd + 1 : sourceEnd), "speech": span(start, end),
             "ranges": [["kind": "replacement", "source": span(sourceStart, sourceEnd),
                         "display": span(sourceStart, sourceEnd), "speech": span(start, end)]],
             "word_start": word, "word_end": word + 1, "section_id": "section:0",
             "starts_block": true, "starts_section": word == 0, "marker": "\(word + 2)."]
        }
        return ["version": 1, "text": "Alpha. Beta.", "speech_start": 0,
                "blocks": [block(0, 0, 6, 0, 9), block(1, 7, 12, 10, 18)]]
    }

    // Exercise the production TypeScript serializer, then the real Swift wire decoder/cache.
    func testLargeSerializedPreparingReadsKeepEveryBreakThroughTimingAndChunks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (count, padding) in [(20, 0), (100, 140)] {
            let process = Process()
            process.currentDirectoryURL = root
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["bun", "-e", """
                import {projectStructuredSpeech} from './src/tts/structured-speech';
                import {structuredReadDisplay} from './src/tts/structured-display';
                import {serializeEvent} from './src/socket-protocol';
                const source = Array.from({length: \(count)}, (_,i) => '- Item '+i+' keeps its own separate bullet and useful explanation.'+'x'.repeat(\(padding))).join('\\n');
                const p = projectStructuredSpeech(source);
                const [display] = structuredReadDisplay(p, [p.speechText], 400);
                process.stdout.write(serializeEvent({type:'state',state:'speaking',text:'Preparing speech…',long_read:{id:'r3',chunk_index:0,chunk_count:2,chunk_start_ms:0,preparing:true,text:p.speechText,chunk_word_starts:[0,110],display}}));
                const words = p.speechText.split(' ');
                const chunks = [words.slice(0,110).join(' '), words.slice(110).join(' ')];
                const displays = structuredReadDisplay(p, chunks, 400);
                process.stdout.write(serializeEvent({type:'state',state:'speaking',text:chunks[1],long_read:{id:'r3',chunk_index:1,chunk_count:2,chunk_start_ms:500,display:displays[1]}}));
                """]
            let pipe = Pipe(); process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertGreaterThan(data.count, 8191)
            let frames = data.split(separator: 10).map { Data($0) }
            XCTAssertEqual(frames.count, 2)
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0]) as? [String: Any])
            let read = try XCTUnwrap(event["long_read"] as? [String: Any])
            var document = try XCTUnwrap(TeleprompterLongReadDocument(longRead: read))
            XCTAssertEqual(document.displayBlocks.count, count)
            let cache = TeleprompterRenderCache()
            let first = cache.document(text: document.text, wordBoundaries: [
                TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "Item", wordIndex: 0)
            ], displayBlocks: document.displayBlocks, hasCompleteDisplay: document.hasCompleteDisplay)
            XCTAssertEqual(first.layouts.filter { $0.lineBreak != .none }.count, count)
            let chunkEvent = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[1]) as? [String: Any])
            let chunkRead = try XCTUnwrap(chunkEvent["long_read"] as? [String: Any])
            let chunkText = try XCTUnwrap(chunkEvent["text"] as? String)
            let chunkDisplay = try XCTUnwrap(TeleprompterStructuredDisplay.decode(chunkRead["display"], text: chunkText))
            document.recordDisplay(chunkDisplay, wordStart: 110)
            let later = cache.document(text: document.text, wordBoundaries: [
                TeleprompterBoundary(offsetMs: 500, durationMs: 100, text: "Item", wordIndex: 110)
            ], displayBlocks: document.displayBlocks, hasCompleteDisplay: document.hasCompleteDisplay)
            XCTAssertEqual(later.layouts, first.layouts)
            XCTAssertEqual(later.words.map(\.text), first.words.map(\.text))
        }
    }

    // R7: "client/server" highlights as two words, so the decoder counts slash-split display tokens.
    func testSlashCompoundDisplayFromTypeScriptDecodesWithSplitWordCount() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bun", "-e", """
            import {projectStructuredSpeech} from './src/tts/structured-speech';
            import {structuredReadDisplay} from './src/tts/structured-display';
            const p = projectStructuredSpeech('Pick client/server.');
            process.stdout.write(JSON.stringify(structuredReadDisplay(p, [p.speechText], 400)[0]));
            """]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let value = try JSONSerialization.jsonObject(with: data)
        let text = "Pick client/server."
        XCTAssertEqual(TeleprompterContentModel.displayTokens(text), ["Pick", "client", "/server."])
        let display = try XCTUnwrap(TeleprompterStructuredDisplay.decode(value, text: text))
        XCTAssertEqual(display.blocks.map { [$0.word_start, $0.word_end] }, [[0, 3]])
    }

    // The decoder runs on the main thread: slash-heavy text must tokenize in one linear pass.
    func testLongSlashHeavyDecodeStaysCloseToPlainText() throws {
        func decodeMs(_ word: String) throws -> Double {
            let text = Array(repeating: word, count: 12_000).joined(separator: " ")
            let span = ["start": 0, "end": (text as NSString).length]
            let words = TeleprompterContentModel.displayTokenRanges(text).count
            let value: [String: Any] = ["version": 1, "text": text, "speech_start": 0, "blocks": [[
                "kind": "paragraph", "source": span, "speech": span,
                "ranges": [["source": span, "display": span, "speech": span, "kind": "identity"]],
                "word_start": 0, "word_end": words, "section_id": "section:0",
                "starts_block": true, "starts_section": true]]]
            return try (0..<3).map { _ in
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try XCTUnwrap(TeleprompterStructuredDisplay.decode(value, text: text))
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            }.min()!
        }
        // Same length and word count: 12,000 slash compounds against 24,000 plain words.
        XCTAssertEqual(TeleprompterContentModel.displayTokenRanges("client/server client server").count, 4)
        let plain = try decodeMs("client server"), slash = try decodeMs("client/server")
        XCTAssertLessThan(slash, plain * 4, "slash \(slash) ms vs plain \(plain) ms")
    }

    func testMissingPreparingDisplayReflowsEveryArrivingChunk() throws {
        var document = try XCTUnwrap(TeleprompterLongReadDocument(longRead: [
            "id": "fallback", "text": "Alpha. Beta.", "chunk_count": 2, "chunk_word_starts": [0, 1]
        ]))
        let cache = TeleprompterRenderCache()
        let timing = [TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "Alpha.", wordIndex: 0)]
        // Both chunk payloads use local word indices; the second is positioned by the document.
        var value = fixture()
        let blocks = try XCTUnwrap(value["blocks"] as? [[String: Any]])
        value["text"] = "Alpha."; value["blocks"] = [blocks[0]]
        document.recordDisplay(try XCTUnwrap(TeleprompterStructuredDisplay.decode(value, text: "Alpha.")), wordStart: 0)
        let first = cache.document(text: document.text, wordBoundaries: timing, displayBlocks: document.displayBlocks, hasCompleteDisplay: document.hasCompleteDisplay)
        XCTAssertEqual(first.layouts.map(\.decoration), ["2.", nil])
        value["text"] = "Beta.";
        value["blocks"] = [blocks[1].merging(["word_start": 0, "word_end": 1]) { _, new in new }]
        value["speech_start"] = 7
        document.recordDisplay(try XCTUnwrap(TeleprompterStructuredDisplay.decode(value, text: "Beta.")), wordStart: 1)
        let later = cache.document(text: document.text, wordBoundaries: timing, displayBlocks: document.displayBlocks, hasCompleteDisplay: document.hasCompleteDisplay)
        XCTAssertEqual(later.layouts.map(\.decoration), ["2.", "3."])
        XCTAssertEqual(later.blocks, [0..<1, 1..<2])
    }

    func testMissingMetadataRederivesPlainTextNewlinesAfterTiming() throws {
        let display = try XCTUnwrap(TeleprompterStructuredDisplay.decode(fixture(), text: "Alpha. Beta."))
        let text = "Alpha.\n\nBeta."
        let cache = TeleprompterRenderCache()
        let timing = [TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "Alpha.", wordIndex: 0)]
        _ = cache.document(text: text, wordBoundaries: timing, displayBlocks: display.blocks)
        let fallback = cache.document(text: text, wordBoundaries: timing)
        XCTAssertEqual(fallback.layouts.map(\.lineBreak), [.none, .paragraph])
        XCTAssertEqual(fallback.layouts, TeleprompterFormatting.layout(text: text, words: fallback.words))
    }

    func testListStartingAtTwoHasUntimedDecorationsAndUnchangedTimedWordIDs() throws {
        let display = try XCTUnwrap(TeleprompterStructuredDisplay.decode(fixture(), text: "Alpha. Beta."))
        let timings = [TeleprompterBoundary(offsetMs: 100, durationMs: 300, text: "Alpha.", wordIndex: 0),
                       TeleprompterBoundary(offsetMs: 600, durationMs: 300, text: "Beta.", wordIndex: 1)]
        let legacy = TeleprompterContentModel.words(text: display.text, wordBoundaries: timings)
        let rendered = TeleprompterRenderCache().document(text: display.text, wordBoundaries: timings,
                                                         displayBlocks: display.blocks)
        XCTAssertEqual(rendered.words, legacy)
        XCTAssertEqual(rendered.words.map(\.id), [0, 1])
        XCTAssertEqual(rendered.words.map(\.offsetMs), [100, 600])
        XCTAssertEqual(rendered.layouts.map(\.decoration), ["2.", "3."])
        XCTAssertEqual(rendered.layouts.map(\.lineBreak), [.paragraph, .line], "short items share a section")
        var seeks: [Int] = []
        TeleprompterSeekPolicy.seek(rendered.words[1], isReadback: false, seek: { seeks.append($0) })
        XCTAssertEqual(seeks, [600], "no list marker becomes a timed or seekable word")
    }

    func testAbsentOrInvalidOptionalMetadataUsesExactLegacyLayout() {
        let text = "End.3. Next."
        XCTAssertNil(TeleprompterStructuredDisplay.decode(nil, text: text))
        XCTAssertNil(TeleprompterStructuredDisplay.decode(fixture(), text: text))
        let words = TeleprompterContentModel.words(text: text, wordBoundaries: [])
        let layouts = TeleprompterFormatting.layout(text: text, words: words)
        XCTAssertEqual(layouts.map(\.displayText), ["End.3.", "Next."])
        XCTAssertTrue(layouts.allSatisfy { $0.decoration == nil && $0.lineBreak == .none })
    }

    func testMalformedRangesVersionAndTokenPartitionsAreRejectedAtomically() {
        var wrongVersion = fixture(); wrongVersion["version"] = 2
        var wrongText = fixture(); wrongText["text"] = "Other. text."
        var wrongOffset = fixture(); wrongOffset["speech_start"] = Int.max
        var broken = fixture()
        var blocks = broken["blocks"] as? [[String: Any]] ?? []
        blocks[1]["word_start"] = 0
        broken["blocks"] = blocks
        var wrongRange = fixture()
        var rangeBlocks = wrongRange["blocks"] as? [[String: Any]] ?? []
        rangeBlocks[0]["ranges"] = []
        wrongRange["blocks"] = rangeBlocks
        var booleanIndex = fixture()
        var booleanBlocks = booleanIndex["blocks"] as? [[String: Any]] ?? []
        booleanBlocks[0]["word_start"] = true
        booleanIndex["blocks"] = booleanBlocks
        for value in [wrongVersion, wrongText, wrongOffset, broken, wrongRange, booleanIndex] {
            XCTAssertNil(TeleprompterStructuredDisplay.decode(value, text: "Alpha. Beta."))
        }
    }

    func testDocumentChunkMappingAndGlobalTimingsSurviveDisplayReadback() throws {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "read", "chunk_index": 0, "chunk_count": 2, "chunk_start_ms": 0,
                                         "preparing": true, "text": "Alpha. Beta. Gamma.", "chunk_word_starts": [0, 2]]])
        func play(_ id: String, index: Int, text: String, display: [String: Any]? = nil) {
            var read: [String: Any] = ["id": id, "chunk_index": index, "chunk_count": 2, "chunk_start_ms": index * 1000]
            if let display { read["display"] = display }
            state.handleEvent(["type": "state", "state": "speaking", "text": text, "duration_ms": 2000,
                               "readback_id": "rb", "playback_offset_ms": index * 1000, "long_read": read])
        }
        play("read", index: 0, text: "Alpha. Beta.", display: fixture())
        state.handleEvent(["type": "subtitle", "words": [], "aligned_words": [
            ["word_index": 0, "text": "Alpha.", "offset_ms": 0, "duration_ms": 300],
            ["word_index": 1, "text": "Beta.", "offset_ms": 500, "duration_ms": 300]]])
        let blocks = state.teleprompterDisplayBlocks
        XCTAssertEqual(blocks.map(\.marker), ["2.", "3."])
        play("read", index: 1, text: "Gamma.")
        XCTAssertEqual(state.teleprompterText, "Alpha. Beta. Gamma.")
        XCTAssertEqual(state.teleprompterDisplayBlocks, blocks)
        XCTAssertEqual(state.teleprompterWordBoundaries.compactMap(\.offsetMs), [0, 500])
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertEqual(state.teleprompterDisplayBlocks, blocks)
        play("replay", index: 0, text: "Alpha. Beta.", display: fixture())
        XCTAssertEqual(state.teleprompterDisplayBlocks, blocks)
        XCTAssertEqual(state.teleprompterText, "Alpha. Beta. Gamma.")
    }

    func testSnapshotAndAReplacementReadNeverBorrowEachOthersDecorations() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Alpha. Beta.",
                           "long_read": ["id": "first", "chunk_index": 0, "chunk_count": 1,
                                         "chunk_start_ms": 0, "display": fixture()]])
        let blocks = state.teleprompterDisplayBlocks, snapshot = state.longReadDocumentSnapshot()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Replacement."])
        XCTAssertTrue(state.teleprompterDisplayBlocks.isEmpty)
        state.restoreLongReadDocument(snapshot)
        XCTAssertTrue(state.teleprompterDisplayBlocks.isEmpty, "a snapshot alone cannot decorate different text")
        state.statusText = "Alpha. Beta."
        state.restoreLongReadDocument(snapshot)
        XCTAssertEqual(state.teleprompterDisplayBlocks, blocks)
    }

    func testHeadingsParagraphsAndMetadataChangesInvalidateFormattingWithoutChangingWords() throws {
        var value = fixture()
        var blocks = value["blocks"] as? [[String: Any]] ?? []
        blocks[0]["kind"] = "heading"; blocks[0].removeValue(forKey: "marker")
        blocks[1]["kind"] = "paragraph"; blocks[1].removeValue(forKey: "marker")
        value["blocks"] = blocks
        let display = try XCTUnwrap(TeleprompterStructuredDisplay.decode(value, text: "Alpha. Beta."))
        let cache = TeleprompterRenderCache()
        let legacy = cache.document(text: display.text, wordBoundaries: [])
        let formatted = cache.document(text: display.text, wordBoundaries: [], displayBlocks: display.blocks)
        XCTAssertEqual(cache.computations, 2)
        XCTAssertEqual(formatted.words, legacy.words)
        XCTAssertEqual(formatted.layouts.map(\.isHeading), [true, false])
        XCTAssertEqual(formatted.layouts.map(\.lineBreak), [.paragraph, .paragraph])
    }

    func testPreparingCarriesFutureBulletStructureBeforeFirstTimedRender() throws {
        var document = try XCTUnwrap(TeleprompterLongReadDocument(longRead: [
            "id": "read", "text": "Alpha. Beta.", "chunk_count": 2,
            "chunk_word_starts": [0, 1], "display": fixture()
        ]))
        let first = TeleprompterRenderCache().document(text: document.text, wordBoundaries: [
            TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "Alpha.", wordIndex: 0)
        ], displayBlocks: document.displayBlocks, hasCompleteDisplay: document.hasCompleteDisplay)
        XCTAssertEqual(first.layouts.map(\.decoration), ["2.", "3."])
        XCTAssertEqual(first.blocks, [0..<1, 1..<2])
        document.recordDisplay(nil, wordStart: 1)
        XCTAssertEqual(document.displayBlocks.count, 2)
    }

    func testLateCompleteDisplayAdoptsStructureThenFreezes() throws {
        let display = try XCTUnwrap(TeleprompterStructuredDisplay.decode(fixture(), text: "Alpha. Beta."))
        let cache = TeleprompterRenderCache()
        let timings = [TeleprompterBoundary(offsetMs: 0, durationMs: 300, text: "Alpha.", wordIndex: 0)]
        let initial = cache.document(text: display.text, wordBoundaries: timings)
        let updated = cache.document(text: display.text, wordBoundaries: timings, displayBlocks: display.blocks, hasCompleteDisplay: true)
        XCTAssertNotEqual(updated.layouts, initial.layouts)
        XCTAssertEqual(updated.layouts.map(\.decoration), ["2.", "3."])
        let laterTimings = timings + [TeleprompterBoundary(offsetMs: 500, durationMs: 300, text: "Beta.", wordIndex: 1)]
        let aligned = cache.document(text: display.text, wordBoundaries: laterTimings, displayBlocks: [], hasCompleteDisplay: true)
        XCTAssertEqual(aligned.layouts, updated.layouts)
        XCTAssertEqual(aligned.words.compactMap(\.offsetMs), [0, 500])
        _ = cache.document(text: "New read.", wordBoundaries: [])
        let replacement = cache.document(text: display.text, wordBoundaries: [], displayBlocks: display.blocks)
        XCTAssertEqual(replacement.layouts.map(\.decoration), ["2.", "3."])
    }

    func testUTF16ReplacementAnchorsDoNotInventPerCharacterSourceTimings() throws {
        let text = "שלום 😀."
        let source = ["start": 0, "end": 11], speech = ["start": 0, "end": 8]
        let value: [String: Any] = ["version": 1, "text": text, "speech_start": 0, "blocks": [[
            "kind": "list-item", "source": source, "speech": speech, "word_start": 0, "word_end": 2,
            "section_id": "section:0", "starts_block": true, "starts_section": true, "marker": "2.",
            "ranges": [["kind": "replacement", "source": source, "display": source, "speech": speech]]]]]
        let display = try XCTUnwrap(TeleprompterStructuredDisplay.decode(value, text: text))
        XCTAssertEqual(display.blocks[0].ranges[0].source.end, 11)
        let words = TeleprompterContentModel.words(text: text, wordBoundaries: [
            TeleprompterBoundary(offsetMs: 100, durationMs: 50, text: "שלום", wordIndex: 0),
            TeleprompterBoundary(offsetMs: nil, durationMs: nil, text: "😀.", wordIndex: 1)])
        XCTAssertEqual(words.map(\.offsetMs), [100, nil])
        XCTAssertEqual(TeleprompterFormatting.layout(text: text, words: words, displayBlocks: display.blocks)
            .map(\.decoration), ["2.", nil])
    }
}
