import Foundation

/// Optional P14b metadata. Speech tokens remain the only timed/seekable words.
public struct TeleprompterDisplayBlock: Decodable, Equatable {
    struct Span: Decodable, Equatable {
        let start: Int
        let end: Int
        var valid: Bool { start >= 0 && start <= end && end <= 200_000 }
    }
    struct Mapping: Decodable, Equatable {
        let source: Span
        let display: Span
        let speech: Span
        let kind: String
    }
    let kind: String
    let source: Span
    let speech: Span
    let ranges: [Mapping]
    var word_start: Int
    var word_end: Int
    let section_id: String
    let starts_block: Bool
    let starts_section: Bool
    let marker: String?
}

struct TeleprompterStructuredDisplay: Decodable {
    let version: Int
    let text: String
    let speech_start: Int
    let blocks: [TeleprompterDisplayBlock]

    /// Decode at the wire boundary. A malformed decoration never weakens document/token validation.
    static func decode(_ value: Any?, text: String) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 1024 * 1024,
              let result = try? JSONDecoder().decode(Self.self, from: data), result.version == 1,
              result.text == text, result.speech_start >= 0,
              result.speech_start <= 200_000 - text.utf16.count else { return nil }
        let ns = text as NSString
        // Word indices are display tokens, as in display-tokens.ts: "client/server" is two words.
        let tokens = TeleprompterContentModel.displayTokenRanges(text)
        let kinds: Set<String> = ["heading", "paragraph", "list-item", "table-row", "table-separator", "separator", "code"]
        var next = 0
        for block in result.blocks {
            guard kinds.contains(block.kind), block.source.valid, block.source.start < block.source.end,
                  block.word_start == next, block.word_end > next, block.word_end <= tokens.count,
                  block.section_id.hasPrefix("section:"), block.section_id.utf8.count <= 32,
                  block.speech.start == result.speech_start + tokens[next].location,
                  block.speech.end == result.speech_start + NSMaxRange(tokens[block.word_end - 1]),
                  validMarker(block) else { return nil }
            var speech = block.speech.start
            for range in block.ranges {
                guard range.source.valid, range.display == range.source, range.speech.valid,
                      range.speech.start == speech, range.speech.end > speech,
                      range.speech.end <= block.speech.end,
                      range.source.start >= block.source.start, range.source.end <= block.source.end,
                      ["identity", "replacement", "insertion"].contains(range.kind),
                      range.kind != "identity" || range.source.end - range.source.start == range.speech.end - range.speech.start,
                      range.kind != "insertion" || range.source.start == range.source.end else { return nil }
                speech = range.speech.end
            }
            guard speech == block.speech.end else { return nil }
            next = block.word_end
        }
        guard next == tokens.count, ns.length > 0 else { return nil }
        return result
    }

    private static func validMarker(_ block: TeleprompterDisplayBlock) -> Bool {
        guard let marker = block.marker else { return true }
        return block.kind == "list-item" && block.starts_block && marker.utf16.count <= 32 &&
            marker.range(of: "^(?:[-+*]|[0-9]+[.)])$", options: .regularExpression) != nil
    }

    func positioned(at wordStart: Int) -> [TeleprompterDisplayBlock] {
        blocks.map { block in
            var block = block
            block.word_start += wordStart
            block.word_end += wordStart
            return block
        }
    }
}
