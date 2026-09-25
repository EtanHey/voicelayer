import SwiftUI

/// Spec §4: the History panel that drops out of the notch in the teleprompter's shell. Rows are
/// time · length over the first words; Copy / Paste / Re-transcribe appear on hover. It draws on the
/// notch's own contrast palette, like the teleprompter, and adds no material of its own.
struct NotchHistoryPanel: View {
    let entries: [RecentTranscriptionEntry]
    let activeRetranscriptionPath: String?
    let palette: VoiceBarNotchContrastPalette
    /// Returns whether the text reached the pasteboard; "Copied ✓" shows only then (#161 review).
    let onCopy: (RecentTranscriptionEntry) -> Bool
    let onPaste: (RecentTranscriptionEntry) -> Void
    let onRetranscribe: (String) -> Void
    let onOpenHistory: () -> Void
    /// Shots only: render one row as hovered without a pointer.
    var forcedHoverIndex: Int?

    @State private var hoveredID: String?
    @State private var copyFeedback = NotchHistoryCopyFeedback()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let ids = NotchHistoryPresentation.rowIDs(for: entries)
                    ForEach(Array(zip(entries.indices, ids)), id: \.1) { index, id in
                        row(entries[index], index: index, id: id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(palette.tertiary.color.opacity(0.35))
                .frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(NotchHistoryPresentation.pasteHint)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondary.color)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Button(NotchHistoryPresentation.openHistoryTitle, action: onOpenHistory)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.primary.color)
                    .accessibilityHint("Opens Settings on History")
            }
        }
    }

    private func row(_ entry: RecentTranscriptionEntry, index: Int, id: String) -> some View {
        let isRetranscribing = entry.recordingPath != nil && entry.recordingPath == activeRetranscriptionPath
        let isCopied = copyFeedback.isCopied(row: id)
        let showsActions = forcedHoverIndex == index || hoveredID == id || isCopied
        return VStack(alignment: .leading, spacing: 2) {
            // One fixed-height lane for the header and the 24 pt actions, so they share a center line
            // (#161 review: the header sat ~5 pt above the buttons).
            HStack(alignment: .center, spacing: 4) {
                Text(NotchHistoryPresentation.rowHeader(for: entry) ?? "")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.secondary.color)
                Spacer(minLength: 4)
                if isRetranscribing {
                    ProcessingSpinner()
                    Text("Re-transcribing…")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.secondary.color)
                } else {
                    if isCopied {
                        Text(NotchHistoryPresentation.copyTitle(isCopied: true))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.secondary.color)
                    }
                    actionButtons(entry, id: id, isCopied: isCopied)
                        .opacity(showsActions ? 1 : 0)
                }
            }
            .frame(height: NotchHistoryPresentation.rowActionSize)

            Text(NotchHistoryPresentation.firstWords(entry.text))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.primary.color)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.primary.color.opacity(showsActions ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredID = id
            } else if hoveredID == id {
                hoveredID = nil
            }
        }
        .opacity(isRetranscribing ? 0.62 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            [NotchHistoryPresentation.rowHeader(for: entry), NotchHistoryPresentation.firstWords(entry.text)]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private func actionButtons(_ entry: RecentTranscriptionEntry, id: String, isCopied: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(NotchHistoryPresentation.rowActions, id: \.symbol) { action in
                if action.kind != .retranscribe || entry.recordingPath != nil {
                    Button {
                        perform(action.kind, entry: entry, id: id)
                    } label: {
                        Image(systemName: action.kind == .copy && isCopied ? "checkmark" : action.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.primary.color)
                            .frame(
                                width: NotchHistoryPresentation.rowActionSize,
                                height: NotchHistoryPresentation.rowActionSize
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(action.label)
                    .accessibilityLabel(action.kind == .copy && isCopied ? "Copied" : action.label)
                }
            }
        }
    }

    private func perform(_ kind: NotchHistoryPresentation.RowAction.Kind, entry: RecentTranscriptionEntry, id: String) {
        switch kind {
        case .copy:
            guard onCopy(entry) else { return }
            let generation = copyFeedback.copied(row: id)
            Task { @MainActor in
                try? await Task.sleep(for: NotchHistoryPresentation.copiedFeedbackDuration)
                copyFeedback.expire(generation)
            }
        case .paste:
            onPaste(entry)
        case .retranscribe:
            if let path = entry.recordingPath { onRetranscribe(path) }
        }
    }
}
