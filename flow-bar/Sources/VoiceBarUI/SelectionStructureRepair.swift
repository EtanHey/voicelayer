import Foundation

/// T27: a selection read through accessibility from an app other than T3 Code can come back with its line
/// breaks gone (seen in a Chromium/Electron chat app): every list item runs inline after the previous sentence.
/// These pure rules decide when such text looks flattened, whether a Copy of the same selection carries the
/// structure back, and, when Copy cannot, where line breaks can be put back without touching any word.
public enum SelectionStructureRepair {
    /// The `selection_capture` field. Absent when not evaluated (T3 Code and copy-preferred browsers always
    /// copy; no AX text was read).
    public static let diagnosticField = "structure_repair"

    /// What the capture did about a selection's structure, logged as `structure_repair`.
    public enum Decision: String {
        /// The AX text had line breaks, was short, or showed no lost-structure signal.
        case notFlattened = "not_flattened"
        /// The Copy text carried the line breaks and the same content; it was used.
        case copy
        /// Copy failed or lacked the structure; line breaks were rebuilt before inline markers.
        case split
        /// Flattened, but neither Copy nor the conservative split could repair it; AX text as read.
        case none
    }

    /// Below this a selection is a line or two; reading it on one line loses nothing worth a Cmd+C round trip
    /// (pasteboard snapshot, synthetic Copy, up to 0.4 s of polling, restore). A two-item list with a lead-in
    /// sentence is already longer than this.
    public static let minimumUTF16Count = 80

    private static let bulletGlyphs: Set<Character> = ["•", "◦", "▪", "‣"]
    private static let dashMarkers: Set<Character> = ["-", "*", "+", "–"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?", ":"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
    private static let objectReplacement: Character = "\u{FFFC}"

    public static func hasLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029].contains($0.value) }
    }

    /// No line break, at least `minimumUTF16Count` long, and either an inline list marker the split would act
    /// on or an object-replacement character (Chromium exposes embedded list/markup objects as U+FFFC).
    public static func looksFlattened(_ text: String) -> Bool {
        guard !hasLineBreak(text), text.utf16.count >= minimumUTF16Count else { return false }
        return !splitPoints(Array(text)).isEmpty || text.contains(objectReplacement)
    }

    /// Copy must preserve content, including numbers and punctuation. Only recognised list prefixes,
    /// whitespace and AX's standalone embedded-object placeholders may differ.
    public static func copyKeepsStructure(ax: String, copy: String) -> Bool {
        hasLineBreak(copy) && comparableContent(ax) == comparableContent(copy)
    }

    private static func comparableContent(_ text: String) -> String {
        // A flattened AX list first gets the same conservative marker boundaries as the fallback.
        let lines = split(text).components(separatedBy: .newlines)
        return lines.map { line in
            var chars = Array(line.trimmingCharacters(in: .whitespaces))
            if marker(in: chars, at: 0) != nil {
                var end = 0
                while end < chars.count, chars[end].isASCII, chars[end].isNumber { end += 1 }
                // A bullet/dash is one character; a numbered prefix includes its '.' or ')'.
                chars.removeFirst(end + 1)
            }
            // U+FFFC is AX markup only when it is a standalone token. Keep it when embedded
            // in payload, just as we keep every other non-whitespace content character.
            return String(chars).split(whereSeparator: \.isWhitespace)
                .filter { $0 != String(objectReplacement) }.joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Replaces the single space before each inline list marker with a line break. Every other character,
    /// including every word, marker, U+FFFC and the rest of the whitespace, stays exactly as it was.
    public static func split(_ text: String) -> String {
        guard !hasLineBreak(text) else { return text }
        var characters = Array(text)
        let points = splitPoints(characters)
        guard !points.isEmpty else { return text }
        for index in points { characters[index] = "\n" }
        return String(characters)
    }

    private enum Marker: Equatable { case bullet, dash, number(Int) }

    /// Indices of the spaces to turn into line breaks. Rules, each chosen to never mint a list item out of prose:
    /// - A bullet glyph (• ◦ ▪ ‣) between spaces is a marker anywhere: prose never uses it as a word.
    /// - `-` `*` `+` `–` between spaces counts only right after a sentence end (`.` `!` `?` `:`, optionally
    ///   closed by a quote or bracket). A hyphenated word has no spaces; `5 - 3` follows a digit.
    /// - `N.` / `N)` (1–3 digits) followed by a space counts only after a sentence end, and only when all the
    ///   numbered markers in the text count up by one (`1. 2. 3.`, at least two). The sequence must start
    ///   at the text's opening or after a colon: consecutive chapter/page references are not list evidence.
    /// - At least two markers in total (one may open the text), so one stray marker never splits anything.
    private static func splitPoints(_ chars: [Character]) -> [Int] {
        var inline: [(space: Int, marker: Marker)] = []
        var opening: Marker?
        if let marker = marker(in: chars, at: 0) { opening = marker }
        var index = 1
        while index < chars.count - 1 {
            defer { index += 1 }
            guard chars[index] == " ", let marker = marker(in: chars, at: index + 1) else { continue }
            if marker != .bullet, !followsSentenceEnd(chars, space: index) { continue }
            inline.append((index, marker))
        }
        let numbers = ([opening].compactMap { $0 } + inline.map(\.marker)).compactMap { marker -> Int? in
            if case let .number(value) = marker { return value }
            return nil
        }
        let startsNumberedList: Bool
        if case .number = opening {
            startsNumberedList = true
        } else if let first = inline.first(where: { if case .number = $0.marker { return true }; return false }) {
            // A period can belong to a numeric reference ("chapter 3. 4. is optional").
            // A colon introducing the first item is stronger evidence of a flattened list.
            var before = first.space - 1
            while before >= 0, closers.contains(chars[before]) { before -= 1 }
            startsNumberedList = before >= 0 && chars[before] == ":"
        } else {
            startsNumberedList = false
        }
        let numbersCount = startsNumberedList && numbers.count >= 2
            && zip(numbers, numbers.dropFirst()).allSatisfy { $1 == $0 + 1 }
        if !numbersCount {
            inline.removeAll { if case .number = $0.marker { return true }; return false }
            if case .number = opening { opening = nil }
        }
        guard !inline.isEmpty, inline.count + (opening == nil ? 0 : 1) >= 2 else { return [] }
        return inline.map(\.space)
    }

    private static func marker(in chars: [Character], at start: Int) -> Marker? {
        guard start < chars.count else { return nil }
        let first = chars[start]
        if bulletGlyphs.contains(first) || dashMarkers.contains(first) {
            guard start + 1 < chars.count, chars[start + 1] == " " else { return nil }
            return bulletGlyphs.contains(first) ? .bullet : .dash
        }
        var end = start
        while end < chars.count, end - start < 4, chars[end].isASCII, chars[end].isNumber { end += 1 }
        let digits = end - start
        guard (1...3).contains(digits), end + 1 < chars.count,
              chars[end] == "." || chars[end] == ")", chars[end + 1] == " ",
              let value = Int(String(chars[start..<end])) else { return nil }
        return .number(value)
    }

    private static func followsSentenceEnd(_ chars: [Character], space: Int) -> Bool {
        var index = space - 1
        while index >= 0, closers.contains(chars[index]) { index -= 1 }
        return index >= 0 && sentenceEnds.contains(chars[index])
    }
}

public extension SelectionCaptureResult {
    /// Rides the existing diagnostics merge, so `SelectionCaptureResult` (and the formal models that hash
    /// its file) stay unchanged.
    func withStructureRepair(_ decision: SelectionStructureRepair.Decision) -> Self {
        withPreflightDetails([SelectionStructureRepair.diagnosticField: decision.rawValue])
    }
}
