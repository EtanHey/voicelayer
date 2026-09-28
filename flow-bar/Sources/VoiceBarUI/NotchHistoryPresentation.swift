import CoreGraphics
import Foundation

/// Copy, timing and actions for the notch History panel (R4 UI pass #13; spec §4: rows are
/// "time · length" over the first words, Copy / Paste / Re-transcribe on hover, footer "Open History…").
public enum NotchHistoryPresentation {
    public static let openHistoryTitle = "Open History…"
    /// Paste from the popover types into the app behind it, which is easy to miss, so it's said once.
    public static let pasteHint = "Paste types into the app you were using."

    public static let firstWordsLimit = 90
    /// Spec §4: 24 pt hit targets (R4 UI pass #19 found 10–12 pt ones in Settings).
    public static let rowActionSize: CGFloat = 24

    public struct RowAction: Equatable {
        public enum Kind: Equatable { case copy, paste, retranscribe }
        public let kind: Kind
        public let symbol: String
        /// Tooltip and VoiceOver label.
        public let label: String
    }

    public static let rowActions: [RowAction] = [
        RowAction(kind: .copy, symbol: VoiceBarActionSymbol.copy, label: "Copy"),
        RowAction(kind: .paste, symbol: VoiceBarActionSymbol.paste, label: "Paste into the app you were using"),
        RowAction(kind: .retranscribe, symbol: "arrow.clockwise", label: "Re-transcribe"),
    ]

    /// The row's actions for VoiceOver and keyboard users, who never hover (UXP-3, UX pass #7): the hover buttons
    /// exist only while the pointer is over the row. Re-transcribe needs the row's audio.
    public static func accessibilityActions(for entry: RecentTranscriptionEntry) -> [RowAction] {
        rowActions.filter { $0.kind != .retranscribe || entry.recordingPath != nil }
    }

    /// Each row's identity across list changes: its audio when it has one (a re-transcription keeps its row),
    /// else its text plus when it was dictated (#166 Macroscope: an offset moved "Copied ✓" when an entry was
    /// inserted at 0). Ids are unique within the list: a repeat of the same base gets `#n`, so two identical
    /// audio-less entries never share "Copied ✓" or hover (Macroscope 4100526855).
    public static func rowIDs(for entries: [RecentTranscriptionEntry]) -> [String] {
        var occurrences: [String: Int] = [:]
        return entries.map { entry in
            let base = entry.recordingPath
                ?? entry.createdAt.map { "\(entry.text)@\($0.timeIntervalSince1970)" }
                ?? entry.text
            let seen = occurrences[base, default: 0]
            occurrences[base] = seen + 1
            return seen == 0 ? base : "\(base)#\(seen)"
        }
    }

    /// The row's first words on one line: whitespace and line breaks collapse, and long text ends in "…".
    public static func firstWords(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > firstWordsLimit else { return flattened }
        return String(flattened.prefix(firstWordsLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "2 min ago · 0:13"; the length only when the dictation's receipt has it. Nil for an entry saved
    /// before times were recorded.
    public static func rowHeader(for entry: RecentTranscriptionEntry, now: Date = Date()) -> String? {
        guard let time = VoiceBarRelativeTime.label(entry.createdAt, now: now) else { return nil }
        guard let receipt = entry.dictationReceipt else { return time }
        let seconds = Int(receipt.audioDuration.rounded())
        return "\(time) · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
