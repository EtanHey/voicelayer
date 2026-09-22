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

public struct DictationCard: View {
    public let entry: RecentTranscriptionEntry
    public let insertionStatus: DictationInsertionStatus
    public let onCopy: (String) -> Void

    public init(
        entry: RecentTranscriptionEntry,
        insertionStatus: DictationInsertionStatus,
        onCopy: @escaping (String) -> Void
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(entry.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    onCopy(entry.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy last dictation")
                .accessibilityLabel("Copy last dictation")
            }
            Spacer(minLength: 24)
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
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
