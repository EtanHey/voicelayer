import Foundation

/// Copy and timing for the notch History popover (R4 UI pass #13; wording from spec §4: rows are
/// "time · length", the footer is "Open History…").
public enum NotchHistoryPresentation {
    public static let openHistoryTitle = "Open History…"
    /// Paste from the popover types into the app behind it, which is easy to miss, so it's said once.
    public static let pasteHint = "Paste types into the app you were using."
    public static let copiedFeedbackDuration: Duration = .milliseconds(1500)

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
