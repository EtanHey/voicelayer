// TeleprompterDocument.swift — TELE1: one long read is one teleprompter document.
//
// Synthesis splits a long read into ~400-character chunks. Those boundaries are audio-only: the
// teleprompter shows the whole read from its Preparing event and maps each chunk's timings onto it.

import Foundation

/// The whole display text of one long read, plus where each chunk's words start in it.
public struct TeleprompterLongReadDocument: Equatable {
    /// Every word is a laid-out view; past this the read pages per chunk as before.
    static let maximumWords = 3000

    public let readID: String
    /// The read's retained-audio identity. A readback replay of the same audio arrives under a new read ID.
    public var readbackID: String?
    public let text: String
    private let tokens: [String]
    private let chunkWordStarts: [Int]
    /// Global word index → timing. A seek or a readback replay of the same read keeps it.
    private var timings: [Int: TeleprompterBoundary] = [:]

    /// Nil for a daemon that sends no document, or a document that does not tile its chunks.
    public init?(longRead: [String: Any]) {
        guard let readID = longRead["id"] as? String, let text = longRead["text"] as? String,
              let starts = longRead["chunk_word_starts"] as? [Int],
              starts.count == longRead["chunk_count"] as? Int, starts.first == 0 else { return nil }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count <= Self.maximumWords, let last = starts.last, last < tokens.count,
              zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        self.readID = readID
        self.text = text
        self.tokens = tokens
        chunkWordStarts = starts
    }

    /// The chunk's first word in the document, or nil when the chunk is not exactly that slice of it.
    public func wordStart(chunkIndex: Int, chunkCount: Int, text chunkText: String) -> Int? {
        guard chunkCount == chunkWordStarts.count, chunkWordStarts.indices.contains(chunkIndex) else { return nil }
        let start = chunkWordStarts[chunkIndex]
        let end = chunkIndex + 1 < chunkWordStarts.count ? chunkWordStarts[chunkIndex + 1] : tokens.count
        let chunkTokens = chunkText.split(whereSeparator: \.isWhitespace).map(String.init)
        return tokens[start ..< end].elementsEqual(chunkTokens) ? start : nil
    }

    /// Re-indexes one chunk's timings (already on the global clock) against the document. Estimated
    /// legacy reschedules are not seek targets, so they stay untimed; an untimed chunk erases nothing.
    public mutating func record(chunkText: String, boundaries: [TeleprompterBoundary], wordStart: Int) {
        let words = TeleprompterContentModel.words(text: chunkText, wordBoundaries: boundaries)
        let chunkTokens = chunkText.split(whereSeparator: \.isWhitespace).map(String.init)
        let pieces = chunkTokens.map(TeleprompterContentModel.displayPieceCount)
        guard pieces.reduce(0, +) == words.count else { return }
        var rows: [Int: TeleprompterBoundary] = [:]
        var piece = 0
        for (index, token) in chunkTokens.enumerated() {
            let word = words[piece]
            piece += pieces[index]
            guard let offset = word.offsetMs, !word.hasEstimatedTiming else { continue }
            rows[wordStart + index] = TeleprompterBoundary(offsetMs: offset, durationMs: word.durationMs, text: token,
                                                           wordIndex: wordStart + index,
                                                           isInterpolated: word.hasInterpolatedTiming)
        }
        guard !rows.isEmpty else { return }
        for index in wordStart ..< wordStart + chunkTokens.count { timings[index] = rows[index] }
    }

    public var boundaries: [TeleprompterBoundary] {
        timings.sorted { $0.key < $1.key }.map(\.value)
    }
}
