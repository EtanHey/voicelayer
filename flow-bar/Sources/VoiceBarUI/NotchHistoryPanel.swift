import SwiftUI

/// 2.3 lane U4 (approved mock 5-history): the History panel that grows out of the notch. Rows are two lines, six
/// visible collapsed and eight expanded, up to 20 scrolling inside (Etan, 2026-11-08, superseding 11-03's "7
/// visible"): the dictation on the first line, when and how long on the second. Tight insets, no footer prose, a thin scroll indicator only while scrolling, and a row highlight
/// that follows the pointer on the same frame from ONE container hover tracker (no per-row `.onHover`).
/// Hovering a row shows Copy / Paste / Transcribe again on its right. It draws on the notch's own contrast
/// palette and adds no material of its own.
struct NotchHistoryPanel: View {
    let entries: [RecentTranscriptionEntry]
    let activeRetranscriptionPath: String?
    let palette: VoiceBarNotchContrastPalette
    /// Returns whether the text reached the pasteboard; the tick shows only then (#161 review).
    let onCopy: (RecentTranscriptionEntry) -> Bool
    let onPaste: (RecentTranscriptionEntry) -> Void
    let onRetranscribe: (String) -> Void
    /// A click on a row's text opens it in the History window (SPEC open question 1). Copy / Paste stay on hover.
    var onOpen: (RecentTranscriptionEntry) -> Void = { _ in }
    var retranscriptionAvailability: () -> HistoryRetranscriptionAvailability = { .available }
    /// The visible list: six rows, or eight once the extend handle pulled it down (V6).
    var listHeight: CGFloat = NotchHistoryMorph.listHeight
    /// Shots only: render one row as hovered without a pointer.
    var forcedHoverIndex: Int?
    /// Shots only: render the scroll indicator as if mid-scroll, at this content offset.
    var forcedScrollOffset: CGFloat?

    @State private var hoveredIndex: Int?
    @State private var copyFeedback = CopyFeedback()
    @State private var scrollOffset: CGFloat = 0
    @State private var isScrollIndicatorVisible = false
    @State private var scrollIndicatorHideTask: Task<Void, Never>?

    private static let scrollSpace = "NotchHistoryPanel.scroll"

    var body: some View {
        let ids = NotchHistoryPresentation.rowIDs(for: entries)
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(zip(entries.indices, ids)), id: \.1) { index, id in
                    row(entries[index], index: index, id: id)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: NotchHistoryScrollOffsetKey.self,
                        value: -proxy.frame(in: .named(Self.scrollSpace)).minY
                    )
                }
            )
            // ONE hover tracker for the whole list: the row under the pointer is its y over the row height,
            // so the highlight moves on the same frame as the pointer (R0856-06).
            .onContinuousHover(coordinateSpace: .local) { phase in
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    switch phase {
                    case let .active(location):
                        hoveredIndex = NotchHistoryPresentation.rowIndex(atY: location.y, rowCount: entries.count)
                    case .ended:
                        hoveredIndex = nil
                    }
                }
            }
        }
        .coordinateSpace(name: Self.scrollSpace)
        .scrollIndicators(.never)
        .onPreferenceChange(NotchHistoryScrollOffsetKey.self) { offset in
            scrolled(to: offset)
        }
        .frame(height: listHeight)
        .overlay(alignment: .topTrailing) {
            scrollIndicator
        }
        .onDisappear { scrollIndicatorHideTask?.cancel() }
    }

    // MARK: Scroll indicator

    @ViewBuilder
    private var scrollIndicator: some View {
        let offset = forcedScrollOffset ?? scrollOffset
        if let thumb = NotchHistoryPresentation.scrollThumb(
            offset: offset,
            visibleHeight: listHeight,
            contentHeight: NotchHistoryMorph.rowHeight * CGFloat(entries.count)
        ) {
            RoundedRectangle(cornerRadius: NotchHistoryPresentation.scrollIndicatorWidth / 2, style: .continuous)
                .fill(palette.primary.color.opacity(0.4))
                .frame(width: NotchHistoryPresentation.scrollIndicatorWidth, height: thumb.height)
                .offset(
                    x: NotchHistoryPresentation.scrollIndicatorGap + NotchHistoryPresentation.scrollIndicatorWidth,
                    y: thumb.minY
                )
                .opacity(forcedScrollOffset != nil || isScrollIndicatorVisible ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Shown the moment the list moves (80 ms in), hidden 700 ms after it stops (300 ms out), as in the mock.
    private func scrolled(to offset: CGFloat) {
        guard abs(offset - scrollOffset) > 0.25 else { return }
        scrollOffset = offset
        withAnimation(.easeOut(duration: NotchHistoryPresentation.scrollIndicatorFadeIn)) {
            isScrollIndicatorVisible = true
        }
        scrollIndicatorHideTask?.cancel()
        scrollIndicatorHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(NotchHistoryPresentation.scrollIndicatorLinger))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: NotchHistoryPresentation.scrollIndicatorFadeOut)) {
                isScrollIndicatorVisible = false
            }
        }
    }

    // MARK: Rows

    private func row(_ entry: RecentTranscriptionEntry, index: Int, id: String) -> some View {
        let isRetranscribing = entry.recordingPath != nil && entry.recordingPath == activeRetranscriptionPath
        let isCopied = copyFeedback.isCopied(key: id, at: Date())
        let isHovered = (forcedHoverIndex ?? hoveredIndex) == index
        let showsActions = isHovered || isCopied
        return HStack(alignment: .center, spacing: NotchHistoryPresentation.rowColumnSpacing) {
            // A row click opens it in the History window (SPEC open question 1). A plain button, so the clipped-text
            // tooltip sits on a control and keyboard users reach it too.
            Button { onOpen(entry) } label: {
                VStack(alignment: .leading, spacing: NotchHistoryPresentation.rowLineSpacing) {
                    Text(NotchHistoryPresentation.firstWords(entry.text))
                        .font(.system(size: NotchHistoryPresentation.rowTextFontSize))
                        .foregroundStyle(palette.primary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // V12: a row whose words don't fit shows them all when the pointer rests on it.
                        .background(PillControlTooltip(text: NotchHistoryPresentation.clippedTextTooltip(entry.text)))
                    Text(NotchHistoryPresentation.rowHeader(for: entry) ?? " ")
                        .font(.system(size: NotchHistoryPresentation.rowMetaFontSize))
                        .monospacedDigit()
                        .foregroundStyle(palette.tertiary.color)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true) // the row element already carries its label and the open action

            if isRetranscribing {
                HistoryRetranscribingBadge(
                    fontSize: NotchHistoryPresentation.rowMetaFontSize, color: palette.secondary.color
                )
            } else if showsActions {
                // UXP-3: the Copy glyph itself turns into the tick; no second "Copied ✓" beside it.
                actionButtons(entry, id: id)
            }
        }
        .padding(.leading, NotchHistoryPresentation.rowLeadingPadding)
        .padding(.trailing, NotchHistoryPresentation.rowTrailingPadding)
        .frame(height: NotchHistoryMorph.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: NotchHistoryPresentation.rowCornerRadius, style: .continuous)
                .fill(palette.primary.color.opacity(isHovered ? NotchHistoryPresentation.rowHoverOpacity : 0))
        )
        .contentShape(Rectangle())
        .opacity(isRetranscribing ? 0.62 : 1)
        .accessibilityElement(children: .contain)
        // 2.4 Lane A: a stable identifier per position (the E2E suite counts the hittable rows: 6, then 8) and the
        // button role the row's open action already has.
        .accessibilityIdentifier(NotchHistoryPresentation.rowAccessibilityIdentifier(index: index))
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(
            [NotchHistoryPresentation.firstWords(entry.text), NotchHistoryPresentation.rowHeader(for: entry)]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        // UXP-3: the hover buttons exist only under the pointer; VoiceOver and keyboard users get the same actions
        // on the row itself.
        .accessibilityAction { onOpen(entry) }
        .accessibilityActions {
            ForEach(NotchHistoryPresentation.accessibilityActions(for: entry), id: \.symbol) { action in
                if action.kind != .retranscribe || retranscriptionAvailability().isEnabled {
                    Button(action.label) { perform(action.kind, entry: entry, id: id) }
                }
            }
        }
        .accessibilityHint(retranscriptionAvailability().reason ?? NotchHistoryPresentation.openHint)
    }

    private func actionButtons(_ entry: RecentTranscriptionEntry, id: String) -> some View {
        HStack(spacing: 0) {
            ForEach(NotchHistoryPresentation.rowActions, id: \.symbol) { action in
                if action.kind == .copy {
                    CopyFeedbackButton(
                        action.label,
                        key: id,
                        feedback: $copyFeedback,
                        foreground: palette.primary.color
                    ) { onCopy(entry) }
                } else if action.kind != .retranscribe || entry.recordingPath != nil {
                    Button {
                        perform(action.kind, entry: entry, id: id)
                    } label: {
                        Image(systemName: action.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.primary.color)
                            .frame(
                                width: NotchHistoryPresentation.rowActionSize,
                                height: NotchHistoryPresentation.rowActionSize
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // R0856-09: the notch panel is non-activating; SwiftUI `.help` never showed here. The wing
                    // buttons' native registration does (fc126263).
                    .disabled(action.kind == .retranscribe && !retranscriptionAvailability().isEnabled)
                    .background(PillControlTooltip(text: action.kind == .retranscribe
                        ? retranscriptionAvailability().reason ?? action.label : action.label))
                    .accessibilityHint(action.kind == .retranscribe ? retranscriptionAvailability().reason ?? action.label : action.label)
                    .accessibilityLabel(action.label)
                }
            }
        }
        .frame(minWidth: NotchHistoryPresentation.rowActionsMinimumWidth, alignment: .trailing)
    }

    /// The row's actions for VoiceOver: the same calls the hover buttons make. A copy made this way gets the same
    /// tick and announcement once the row is revealed.
    private func perform(_ kind: NotchHistoryPresentation.RowAction.Kind, entry: RecentTranscriptionEntry, id: String) {
        switch kind {
        case .copy:
            let succeeded = onCopy(entry)
            copyFeedback.copied(key: id, succeeded: succeeded, byPointer: false, at: Date())
            guard succeeded else { return }
            AccessibilityNotification.Announcement("Copied").post()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(CopyFeedback.duration))
                copyFeedback.expire(at: Date())
            }
        case .paste:
            onPaste(entry)
        case .retranscribe:
            guard retranscriptionAvailability().isEnabled else { return }
            if let path = entry.recordingPath { onRetranscribe(path) }
        }
    }
}

private struct NotchHistoryScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
