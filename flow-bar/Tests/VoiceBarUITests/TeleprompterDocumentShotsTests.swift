import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// TELE1 visual receipt (opt-in): a three-chunk long read mid-chunk-2, and a short formatted read.
/// Driven only through socket events, so the same file renders the "before" on an older checkout.
@MainActor
final class TeleprompterDocumentShotsTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private static let document = """
    Release 2.2.48 is out and Latest on GitHub. Notch messages stay unmuted.What changed:
    • Word timing: replay a long read and every word highlights , even across sections.
    • Repeated sentences: long transcripts do not loop anymore.The second Mac updates silently.

    Pause and play sit on the pill, loud.Pause works mid-read too.
    """

    func testWriteTeleprompterDocumentShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_TELE1_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_TELE1_SHOTS_DIR to write the TELE1 teleprompter shots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tokens = Self.document.split(whereSeparator: \.isWhitespace).map(String.init)
        let starts = [0, 14, 30]
        let chunks = starts.indices.map { index in
            tokens[starts[index] ..< (index + 1 < starts.count ? starts[index + 1] : tokens.count)]
                .joined(separator: " ")
        }
        let longRead = state()
        longRead.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                              "long_read": ["id": "shot-read", "chunk_index": 0, "chunk_count": 3,
                                            "chunk_start_ms": 0, "preparing": true, "text": Self.document,
                                            "chunk_word_starts": starts]])
        for index in 0 ... 1 {
            let start = index * 6000
            longRead.handleEvent(["type": "state", "state": "speaking", "text": chunks[index], "duration_ms": 18000,
                                  "readback_id": "shot-readback", "playback_offset_ms": start + (index == 1 ? 2400 : 0),
                                  "long_read": ["id": "shot-read", "chunk_index": index, "chunk_count": 3,
                                                "chunk_start_ms": start]])
            let words = chunks[index].split(separator: " ").enumerated().map { offset, token -> [String: Any] in
                ["word_index": offset, "text": String(token), "offset_ms": offset * 380, "duration_ms": 340]
            }
            longRead.handleEvent(["type": "subtitle", "words": [], "duration_ms": 6000, "aligned_words": words])
        }
        try render(longRead, to: directory.appendingPathComponent("tele1-long-read-mid-chunk-2.png"))

        // Round 2: no word cap. A 4,500-word read in 3 chunks stays one lazily laid-out document.
        let bigTokens = (0 ..< 4500).map { $0 % 40 == 39 ? "word\($0).\n\n" : "word\($0)" }
        let bigText = bigTokens.joined(separator: " ")
        let big = state()
        big.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                         "long_read": ["id": "big-read", "chunk_index": 0, "chunk_count": 3, "chunk_start_ms": 0,
                                       "preparing": true, "text": bigText, "chunk_word_starts": [0, 1500, 3000]]])
        let bigChunk = bigText.split(whereSeparator: \.isWhitespace)[1500 ..< 3000].joined(separator: " ")
        big.handleEvent(["type": "state", "state": "speaking", "text": bigChunk, "duration_ms": 1_800_000,
                         "playback_offset_ms": 600_000 + 380 * 700,
                         "long_read": ["id": "big-read", "chunk_index": 1, "chunk_count": 3, "chunk_start_ms": 600_000]])
        big.handleEvent(["type": "subtitle", "words": [], "duration_ms": 600_000, "aligned_words":
            bigChunk.split(separator: " ").enumerated().map { offset, token -> [String: Any] in
                ["word_index": offset, "text": String(token), "offset_ms": offset * 380, "duration_ms": 340]
            }])
        let started = Date()
        try render(big, to: directory.appendingPathComponent("tele1-long-read-4500-words.png"))
        print("TELE1 4500-word render \(Int(Date().timeIntervalSince(started) * 1000)) ms (includes 800 ms settle)")

        let short = state()
        short.handleEvent(["type": "state", "state": "speaking", "duration_ms": 6000,
                           "text": "Shipped today:\n• unmuted.What changed , in short\n1. Open it\n2. Close it"])
        try render(short, to: directory.appendingPathComponent("tele1-short-formatted.png"))
    }

    private func state() -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            playbackAmplitudeClock: { 1000 }, keepsExpandedInDevState: false
        )
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        return state
    }

    private func render(_ state: VoiceState, to url: URL) throws {
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false)
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
        let size = CGSize(width: canvas.totalWidth + 24, height: canvas.totalHeight + 17)
        let bar = BarView(state: state, commandRouter: NoopRouter(), onOpenSettings: {}, onOpenHistory: {},
                          presentationModel: model, includesPanelOutsets: true)
        let host = NSHostingView(rootView: bar.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8)) // let the shell morph and the scroll settle
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw NSError(domain: "TeleprompterDocumentShots", code: 1) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "TeleprompterDocumentShots", code: 2)
        }
        try data.write(to: url, options: .atomic)
        window.contentView = nil
    }
}
