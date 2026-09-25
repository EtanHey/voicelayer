import CoreGraphics
import Foundation

/// Copy, timing and actions for the notch History panel (R4 UI pass #13; spec §4: rows are
/// "time · length" over the first words, Copy / Paste / Re-transcribe on hover, footer "Open History…").
public enum NotchHistoryPresentation {
    public static let openHistoryTitle = "Open History…"
    /// Paste from the popover types into the app behind it, which is easy to miss, so it's said once.
    public static let pasteHint = "Paste types into the app you were using."
    public static let copiedFeedbackDuration: Duration = .milliseconds(1500)

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
        RowAction(kind: .copy, symbol: "doc.on.doc", label: "Copy"),
        RowAction(kind: .paste, symbol: "doc.on.clipboard", label: "Paste into the app you were using"),
        RowAction(kind: .retranscribe, symbol: "arrow.clockwise", label: "Re-transcribe"),
    ]

    /// The row's first words on one line: whitespace and line breaks collapse, and long text ends in "…".
    public static func firstWords(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > firstWordsLimit else { return flattened }
        return String(flattened.prefix(firstWordsLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public static func copyTitle(isCopied: Bool) -> String {
        isCopied ? "Copied ✓" : "Copy"
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

/// Which History row shows "Copied ✓". Each copy gets a generation, so a timer started by an earlier copy
/// can't clear the feedback of a later one (CodeRabbit on #161: copying a row twice within 1.5 s cleared it
/// early).
public struct NotchHistoryCopyFeedback: Equatable {
    private var row: Int?
    private var generation = 0

    public init() {}

    public func isCopied(row: Int) -> Bool {
        self.row == row
    }

    /// Marks `row` copied and returns the generation its expiry must match.
    public mutating func copied(row: Int) -> Int {
        generation &+= 1
        self.row = row
        return generation
    }

    public mutating func expire(_ generation: Int) {
        guard generation == self.generation else { return }
        row = nil
    }
}
