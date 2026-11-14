import Foundation

/// One batch of a list-aware typed delivery. Every segment but the last ends in a line break that is
/// followed by a list line; `leadingMarker` is that list line's marker, which the target editor may
/// already have inserted on its own.
public struct ListContinuationSegment: Equatable {
    public let text: String
    public let leadingMarker: String?

    public init(text: String, leadingMarker: String?) {
        self.text = text
        self.leadingMarker = leadingMarker
    }
}

/// What the editor did with one typed line break, read from the focused element's text before and after.
public enum ListContinuationReading: Equatable {
    /// The editor put its own copy of the next line's marker after the break: do not type ours.
    case editorInsertedMarker
    /// A plain line break: type our marker as usual.
    case plainBreak
    /// The readback does not show our line and its break (yet).
    case unknown
}

/// AIDEV-NOTE (lane T7, 2026-11-13): a rich composer that continues a list on a line break (T3 Code:
/// `splitOrLiftListItem` in rich mode, `listContinuationForEnter` in plain mode) inserts its own "2. "
/// when we type Shift+Return after "1. …", and then we typed ours: "2. 2. …" (take bb63b989). The
/// delivery stays typed — the pasteboard is never touched — but at each line break that precedes a
/// list line the typing pauses, reads the focused element back over AX, and drops our marker only when
/// the editor provably inserted the same one at exactly that place. Text without such a break is
/// typed exactly as before, in one batch.
public enum ListContinuationTyping {
    /// Bullet glyphs a rich editor paints (and AX reports) for a bullet item it created itself.
    static let paintedBulletMarkers = ["• ", "◦ ", "▪ "]

    /// The list marker at the very start of `line`: "1. ", "12) ", "- ", "* " or "+ " (one space).
    /// Indented markers are left alone: the editors only continue top-level lists.
    public static func marker(atStartOf line: Substring) -> String? {
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, let ascii = line[index].asciiValue, (48 ... 57).contains(ascii), digits < 9 {
            digits += 1
            index = line.index(after: index)
        }
        if digits > 0 {
            guard index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
            index = line.index(after: index)
        } else {
            guard index < line.endIndex, line[index] == "-" || line[index] == "*" || line[index] == "+" else { return nil }
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == " " else { return nil }
        return String(line[line.startIndex ... index])
    }

    /// Nil when no line break in `text` is followed by a list line: the caller types exactly as before.
    public static func segments(for text: String) -> [ListContinuationSegment]? {
        var segments: [ListContinuationSegment] = []
        var current = ""
        var currentMarker: String?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            current.append(character)
            index = text.index(after: index)
            guard character.isNewline, index < text.endIndex else { continue }
            let lineEnd = text[index...].firstIndex(where: \.isNewline) ?? text.endIndex
            if let marker = marker(atStartOf: text[index ..< lineEnd]) {
                segments.append(ListContinuationSegment(text: current, leadingMarker: currentMarker))
                current = ""
                currentMarker = marker
            }
        }
        guard !segments.isEmpty else { return nil }
        segments.append(ListContinuationSegment(text: current, leadingMarker: currentMarker))
        return segments
    }

    /// Markers that count as "the same one" as `ours` when the editor inserted them.
    static func equivalentEditorMarkers(for ours: String) -> [String] {
        ours.first.map { "-*+".contains($0) } == true ? [ours] + paintedBulletMarkers : [ours]
    }

    /// Reads one break. `before` is the focused element's text before `typedLine` (our typed text, its
    /// line break included) was posted, `after` the text once the editor handled it. The caret's place is
    /// where `before` and `after` first differ; what followed the caret must be unchanged after our line,
    /// the break and the editor's marker — up to the one trailing line break a rich editor reports for an
    /// empty last paragraph. Anything else is `.unknown`.
    public static func read(before: String, after: String, typedLine: String, nextMarker: String) -> ListContinuationReading {
        let normalized = typedLine.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: "\n")
        // A rich editor repaints our own leading bullet too ("- Passport" reads "• Passport").
        var typedForms = [Array(normalized)]
        if let own = marker(atStartOf: normalized[...]), own.count < normalized.count {
            for painted in equivalentEditorMarkers(for: own).dropFirst() {
                typedForms.append(Array(painted + normalized.dropFirst(own.count)))
            }
        }
        for typed in typedForms {
            let reading = read(before: before, after: after, typed: typed, nextMarker: nextMarker)
            if reading != .unknown { return reading }
        }
        return .unknown
    }

    private static func read(before: String, after: String, typed: [Character], nextMarker: String) -> ListContinuationReading {
        let old = Array(before)
        let new = Array(after)
        var caret = 0
        while caret < old.count, caret < new.count, old[caret] == new[caret] { caret += 1 }
        // The common prefix can run into our own line when it repeats text that followed the caret;
        // back up to the last place our typed line can start.
        for start in stride(from: caret, through: max(0, caret - typed.count), by: -1) {
            guard start <= old.count else { continue }
            let rest = Array(new[start...])
            guard rest.starts(with: typed) else { continue }
            let afterBreak = Array(rest[typed.count...])
            let originalTail = Array(old[start...])
            for marker in equivalentEditorMarkers(for: nextMarker).map(Array.init)
            where afterBreak.starts(with: marker)
                && sameModuloTrailingBreak(Array(afterBreak[marker.count...]), originalTail) {
                return .editorInsertedMarker
            }
            if sameModuloTrailingBreak(afterBreak, originalTail) { return .plainBreak }
        }
        return .unknown
    }

    private static func sameModuloTrailingBreak(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        func trimmed(_ value: [Character]) -> ArraySlice<Character> {
            value.last == "\n" ? value.dropLast() : value[...]
        }
        return trimmed(lhs) == trimmed(rhs)
    }
}
