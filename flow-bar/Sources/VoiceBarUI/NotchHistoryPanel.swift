import SwiftUI

/// Spec §4: the History panel that drops out of the notch in the teleprompter's shell. Rows are
/// time · length over the first words; Copy / Paste / Re-transcribe appear on hover. It draws on the
/// notch's own contrast palette, like the teleprompter, and adds no material of its own.
struct NotchHistoryPanel: View {
    let entries: [RecentTranscriptionEntry]
    let activeRetranscriptionPath: String?
    let palette: VoiceBarNotchContrastPalette
    let onCopy: (RecentTranscriptionEntry) -> Void
    let onPaste: (RecentTranscriptionEntry) -> Void
    let onRetranscribe: (String) -> Void
    let onOpenHistory: () -> Void
    /// Shots only: render one row as hovered without a pointer.
    var forcedHoverIndex: Int?

    @State private var hoveredIndex: Int?
    @State private var copiedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        row(entry, index: index)
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

    private func row(_ entry: RecentTranscriptionEntry, index: Int) -> some View {
        let isRetranscribing = entry.recordingPath != nil && entry.recordingPath == activeRetranscriptionPath
        let showsActions = (forcedHoverIndex ?? hoveredIndex) == index || copiedIndex == index
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
                    if copiedIndex == index {
                        Text(NotchHistoryPresentation.copyTitle(isCopied: true))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.secondary.color)
                    }
                    actionButtons(entry, index: index)
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
                hoveredIndex = index
            } else if hoveredIndex == index {
                hoveredIndex = nil
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

    private func actionButtons(_ entry: RecentTranscriptionEntry, index: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(NotchHistoryPresentation.rowActions, id: \.symbol) { action in
                if action.kind != .retranscribe || entry.recordingPath != nil {
                    Button {
                        perform(action.kind, entry: entry, index: index)
                    } label: {
                        Image(systemName: action.kind == .copy && copiedIndex == index ? "checkmark" : action.symbol)
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
                    .accessibilityLabel(action.kind == .copy && copiedIndex == index ? "Copied" : action.label)
                }
            }
        }
    }

    private func perform(_ kind: NotchHistoryPresentation.RowAction.Kind, entry: RecentTranscriptionEntry, index: Int) {
        switch kind {
        case .copy:
            onCopy(entry)
            copiedIndex = index
            Task { @MainActor in
                try? await Task.sleep(for: NotchHistoryPresentation.copiedFeedbackDuration)
                if copiedIndex == index { copiedIndex = nil }
            }
        case .paste:
            onPaste(entry)
        case .retranscribe:
            if let path = entry.recordingPath { onRetranscribe(path) }
        }
    }
}
