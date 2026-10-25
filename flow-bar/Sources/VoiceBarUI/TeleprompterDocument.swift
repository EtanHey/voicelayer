// TeleprompterDocument.swift — TELE1: one long read is one teleprompter document.
//
// Synthesis splits a long read into ~400-character chunks. Those boundaries are audio-only: the
// teleprompter shows the whole read from its Preparing event and maps each chunk's timings onto it.

import Foundation

/// The whole display text of one long read, plus where each chunk's words start in it.
public struct TeleprompterLongReadDocument: Equatable {
    public let readID: String
    /// The read's retained-audio identity. A readback replay of the same audio arrives under a new read ID.
    public var readbackID: String?
    public let text: String
    private let tokens: [String]
    private let chunkWordStarts: [Int]
    /// Global word index → timing. A seek or a readback replay of the same read keeps it.
    private var timings: [Int: TeleprompterBoundary] = [:]
    private var hasCompleteDisplay = false
    private var displayChunks: [Int: [TeleprompterDisplayBlock]] = [:]

    /// Nil for a daemon that sends no document, or a document that does not tile its chunks.
    public init?(longRead: [String: Any]) {
        guard let readID = longRead["id"] as? String, let text = longRead["text"] as? String,
              let starts = longRead["chunk_word_starts"] as? [Int],
              starts.count == longRead["chunk_count"] as? Int, starts.first == 0 else { return nil }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = starts.last, last < tokens.count,
              zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        self.readID = readID
        self.text = text
        self.tokens = tokens
        chunkWordStarts = starts
        if let display = TeleprompterStructuredDisplay.decode(longRead["display"], text: text) {
            displayChunks[0] = display.blocks
            hasCompleteDisplay = true
        }
    }

    /// The chunk's first word in the document, or nil when the chunk is not exactly that slice of it.
    /// A readback replay of a stopped read carries only the retained prefix, so a count up to the
    /// document's own is the same read; the slice check is what proves identity.
    public func wordStart(chunkIndex: Int, chunkCount: Int, text chunkText: String) -> Int? {
        guard (1 ... chunkWordStarts.count).contains(chunkCount), chunkIndex < chunkCount,
              chunkWordStarts.indices.contains(chunkIndex) else { return nil }
        let start = chunkWordStarts[chunkIndex]
        let end = chunkIndex + 1 < chunkWordStarts.count ? chunkWordStarts[chunkIndex + 1] : tokens.count
        let chunkTokens = chunkText.split(whereSeparator: \.isWhitespace).map(String.init)
        return tokens[start ..< end].elementsEqual(chunkTokens) ? start : nil
    }

    /// Re-indexes one chunk's timings (already on the global clock) against the document, per whitespace
    /// token and before any display split, so a long URL never turns measured rows into estimates.
    /// Indexed rows must match their tokens; legacy rows must be one plausible row per token. Anything
    /// else is an identity mismatch and records nothing. An untimed chunk erases nothing.
    public mutating func record(chunkText: String, boundaries: [TeleprompterBoundary], wordStart: Int) {
        let chunkTokens = chunkText.split(whereSeparator: \.isWhitespace).map(String.init)
        let rows: [Int: TeleprompterBoundary]
        if boundaries.contains(where: { $0.wordIndex != nil }) {
            guard let indexed = TeleprompterBoundary.indexedRows(boundaries, tokens: chunkTokens) else { return }
            rows = indexed
        } else {
            guard let legacy = TeleprompterContentModel.legacyTokenRows(text: chunkText, boundaries: boundaries)
            else { return }
            rows = legacy
        }
        let timed = rows.filter { $0.value.offsetMs != nil }
        guard !timed.isEmpty else { return }
        for index in chunkTokens.indices {
            timings[wordStart + index] = timed[index].map {
                TeleprompterBoundary(offsetMs: $0.offsetMs, durationMs: $0.durationMs, text: chunkTokens[index],
                                     wordIndex: wordStart + index, isInterpolated: $0.isInterpolated)
            }
        }
    }

    mutating func recordDisplay(_ display: TeleprompterStructuredDisplay?, wordStart: Int) {
        guard !hasCompleteDisplay else { return }
        displayChunks[wordStart] = display?.positioned(at: wordStart)
    }

    var displayBlocks: [TeleprompterDisplayBlock] {
        displayChunks.sorted { $0.key < $1.key }.flatMap(\.value)
    }

    public var boundaries: [TeleprompterBoundary] {
        timings.sorted { $0.key < $1.key }.map(\.value)
    }
}
