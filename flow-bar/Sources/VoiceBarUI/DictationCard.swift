import SwiftUI

public enum DictationInsertionStatus: Equatable {
    case unverified
    case notInserted
    case pending
    case insertedAtCursor
    case pasted
    case failed

    public var label: String {
        switch self {
        case .unverified: "Insertion unverified"
        case .notInserted: "Not inserted"
        case .pending: "Insertion pending"
        case .insertedAtCursor: "Inserted at your cursor"
        case .pasted: "Pasted"
        case .failed: "Insertion failed"
        }
    }

    var systemImage: String {
        switch self {
        case .insertedAtCursor, .pasted: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .pending: "clock"
        case .notInserted, .unverified: "minus.circle"
        }
    }
}

/// General › Last dictation. It sits in the Form's own grouped row, so it draws no card of its own and hugs its
/// content (UXP-3, UX pass #15: a card inside a card with a ~50 pt empty band).
public struct DictationCard: View {
    public let entry: RecentTranscriptionEntry
    public let insertionStatus: DictationInsertionStatus
    /// Returns whether the text reached the pasteboard (`VoiceState.copyTranscript`), so a failed copy shows no tick.
    public let onCopy: (String) -> Bool
    @State private var copyFeedback = CopyFeedback()

    public init(
        entry: RecentTranscriptionEntry,
        insertionStatus: DictationInsertionStatus,
        onCopy: @escaping (String) -> Bool
    ) {
        self.entry = entry
        self.insertionStatus = insertionStatus
        self.onCopy = onCopy
    }

    public static func timingLabel(_ receipt: DictationReceipt?) -> String? {
        guard let receipt else { return nil }
        return String(
            format: "%.1f s audio · %.1f s processing",
            receipt.audioDuration,
            receipt.processingDuration
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(entry.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyFeedbackButton("Copy last dictation", feedback: $copyFeedback) { onCopy(entry.text) }
            }
            HStack {
                Label(insertionStatus.label, systemImage: insertionStatus.systemImage)
                Spacer()
                if let timing = Self.timingLabel(entry.dictationReceipt) {
                    Text(timing)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
