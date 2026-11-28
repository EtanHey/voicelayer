import SwiftUI

/// 2.3 lane U4 (approved mock 5-history): the History panel that grows out of the notch. Rows are two lines, six
/// visible collapsed and eight expanded, up to 20 scrolling inside (design revision 2026-11-08).
/// Dictation occupies the first line; time and duration occupy the second. Tight insets, no footer prose, a thin scroll indicator only while scrolling, and a row highlight
/// that follows the pointer on the same frame from ONE container hover tracker (no per-row `.onHover`).
/// Hovering a row shows Copy / Paste / Transcribe again on its right. It draws on the notch's own contrast
/// palette and adds no material of its own.
struct NotchHistoryPanel: View {
    var entries: [RecentTranscriptionEntry]
    let activeRetranscriptionPath: String?
    let palette: VoiceBarNotchContrastPalette
    /// Returns whether the text reached the pasteboard; the tick shows only then (#161 review).
    var onCopy: (RecentTranscriptionEntry) -> Bool
    var onPaste: (RecentTranscriptionEntry) -> Void
    var onRetranscribe: (String) -> Void
    /// A click on a row's text opens it in the History window (SPEC open question 1). Copy / Paste stay on hover.
    var onOpen: (RecentTranscriptionEntry) -> Void = { _ in }
    var onOpenAtIndex: ((Int) -> Void)?
    var retranscriptionAvailability: () -> HistoryRetranscriptionAvailability = { .available }
    /// The visible list: six rows, or eight once the extend handle pulled it down (V6).
    var listHeight: CGFloat = NotchHistoryMorph.listHeight
    /// Lane H: a category's own second line by row position (Ask and Speech); nil keeps the dictation line.
    var rowHeader: ((Int) -> String?)?
    /// Lane H: what an empty category says, in a row's own anatomy.
    var emptyState: NotchHistoryPresentation.EmptyState?
    var scope: SettingsHistoryScope = .recording
    var rowHasActionableText: ((Int) -> Bool)?
    /// Shots only: render one row as hovered without a pointer.
    var forcedHoverIndex: Int?
    /// Shots only: render the scroll indicator as if mid-scroll, at this content offset.
    var forcedScrollOffset: CGFloat?

    @State private var hoveredIndex: Int?
    @State private var copyFeedback = CopyFeedback()
    /// go-1126 vl-swipe: the scroll position lives in a reference the panel holds but does not observe. Only the
    /// indicator observes it, so a scrolled frame redraws the indicator and never rebuilds the rows (it used to rebuild
    /// every row on every scrolled frame: `NotchHistoryScrollCostTests`).
    @State private var scroll = NotchHistoryScrollTracker()

    private static let scrollSpace = "NotchHistoryPanel.scroll"

    var body: some View {
        let ids = NotchHistoryPresentation.rowIDs(for: entries)
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(zip(entries.indices, ids)), id: \.1) { index, id in
                    row(entries[index], index: index, id: id)
                }
                if entries.isEmpty, let emptyState {
                    emptyRow(emptyState)
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
                        let index = NotchHistoryPresentation.rowIndex(atY: location.y, rowCount: entries.count)
                        if index != hoveredIndex { hoveredIndex = index }
                    case .ended:
                        if hoveredIndex != nil { hoveredIndex = nil }
                    }
                }
            }
        }
        .coordinateSpace(name: Self.scrollSpace)
        .scrollIndicators(.never)
        .onPreferenceChange(NotchHistoryScrollOffsetKey.self) { [scroll] offset in
            scroll.scrolled(to: offset)
        }
        .frame(height: listHeight)
        .overlay(alignment: .topTrailing) {
            NotchHistoryScrollIndicator(
                tracker: scroll, forcedOffset: forcedScrollOffset, visibleHeight: listHeight,
                contentHeight: NotchHistoryMorph.rowHeight * CGFloat(entries.count), palette: palette
            )
        }
        .onDisappear { scroll.stop() }
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
            Button { open(entry, index: index) } label: {
                VStack(alignment: .leading, spacing: NotchHistoryPresentation.rowLineSpacing) {
                    Text(NotchHistoryPresentation.firstWords(entry.text))
                        .font(.system(size: NotchHistoryPresentation.rowTextFontSize))
                        .foregroundStyle(palette.primary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // V12: a row whose words don't fit shows them all when the pointer rests on it.
                        .background(PillControlTooltip(text: NotchHistoryPresentation.clippedTextTooltip(entry.text)))
                    Text(header(entry, index: index) ?? " ")
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
                actionButtons(entry, index: index, id: id)
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
            [scope == .recording ? nil : scope.title, NotchHistoryPresentation.firstWords(entry.text), header(entry, index: index)]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        // UXP-3: the hover buttons exist only under the pointer; VoiceOver and keyboard users get the same actions
        // on the row itself.
        .accessibilityAction { open(entry, index: index) }
        .accessibilityActions {
            ForEach(actions(for: entry, index: index), id: \.symbol) { action in
                if action.kind != .retranscribe || retranscriptionAvailability().isEnabled {
                    Button(action.label) { perform(action.kind, entry: entry, id: id) }
                }
            }
        }
        .accessibilityHint(scope == .recording
            ? retranscriptionAvailability().reason ?? NotchHistoryPresentation.openHint(for: scope)
            : NotchHistoryPresentation.openHint(for: scope))
    }

    private func open(_ entry: RecentTranscriptionEntry, index: Int) {
        if let onOpenAtIndex { onOpenAtIndex(index) } else { onOpen(entry) }
    }

    private func header(_ entry: RecentTranscriptionEntry, index: Int) -> String? {
        guard let rowHeader else { return NotchHistoryPresentation.rowHeader(for: entry) }
        return rowHeader(index)
    }

    /// An empty category: one still row with the list's own insets, sizes and height. Nothing to hover or press.
    private func emptyRow(_ state: NotchHistoryPresentation.EmptyState) -> some View {
        VStack(alignment: .leading, spacing: NotchHistoryPresentation.rowLineSpacing) {
            Text(state.title)
                .font(.system(size: NotchHistoryPresentation.rowTextFontSize))
                .foregroundStyle(palette.secondary.color)
            Text(state.detail.isEmpty ? " " : state.detail)
                .font(.system(size: NotchHistoryPresentation.rowMetaFontSize))
                .foregroundStyle(palette.tertiary.color)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, NotchHistoryPresentation.rowLeadingPadding)
        .padding(.trailing, NotchHistoryPresentation.rowTrailingPadding)
        .frame(height: NotchHistoryMorph.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([state.title, state.detail].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityIdentifier(NotchHistoryPresentation.emptyRowIdentifier)
    }

    func actions(for entry: RecentTranscriptionEntry, index: Int) -> [NotchHistoryPresentation.RowAction] {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rowHasActionableText?(index) ?? true else { return [] }
        return NotchHistoryPresentation.accessibilityActions(for: entry).filter {
            scope != .speech || $0.kind == .copy
        }
    }

    private func actionButtons(_ entry: RecentTranscriptionEntry, index: Int, id: String) -> some View {
        HStack(spacing: 0) {
            ForEach(actions(for: entry, index: index), id: \.symbol) { action in
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

/// The list's scroll position and whether its indicator shows. Shown the moment the list moves (80 ms in), hidden
/// 700 ms after it stops (300 ms out), as in the mock.
@MainActor final class NotchHistoryScrollTracker: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var isVisible = false
    private var hideTask: Task<Void, Never>?
    /// When the list last moved; the hide waits for it to have been still for the linger.
    private var lastMove: TimeInterval = 0

    func scrolled(to next: CGFloat) {
        guard abs(next - offset) > 0.25 else { return }
        offset = next
        lastMove = ProcessInfo.processInfo.systemUptime
        if !isVisible {
            withAnimation(.easeOut(duration: NotchHistoryPresentation.scrollIndicatorFadeIn)) { isVisible = true }
        }
        // One pending hide per scroll, not one task per frame: it re-checks how long the list has been still.
        guard hideTask == nil else { return }
        hideTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let still = ProcessInfo.processInfo.systemUptime - self.lastMove
                let linger = NotchHistoryPresentation.scrollIndicatorLinger
                if still >= linger { break }
                try? await Task.sleep(for: .seconds(linger - still))
            }
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            withAnimation(.easeOut(duration: NotchHistoryPresentation.scrollIndicatorFadeOut)) { self.isVisible = false }
        }
    }

    func stop() {
        hideTask?.cancel()
        hideTask = nil
    }
}

/// The thin scroll thumb, the only view that redraws per scrolled frame.
private struct NotchHistoryScrollIndicator: View {
    @ObservedObject var tracker: NotchHistoryScrollTracker
    let forcedOffset: CGFloat?
    let visibleHeight: CGFloat
    let contentHeight: CGFloat
    let palette: VoiceBarNotchContrastPalette

    var body: some View {
        if let thumb = NotchHistoryPresentation.scrollThumb(
            offset: forcedOffset ?? tracker.offset, visibleHeight: visibleHeight, contentHeight: contentHeight
        ) {
            RoundedRectangle(cornerRadius: NotchHistoryPresentation.scrollIndicatorWidth / 2, style: .continuous)
                .fill(palette.primary.color.opacity(0.4))
                .frame(width: NotchHistoryPresentation.scrollIndicatorWidth, height: thumb.height)
                .offset(
                    x: NotchHistoryPresentation.scrollIndicatorGap + NotchHistoryPresentation.scrollIndicatorWidth,
                    y: thumb.minY
                )
                .opacity(forcedOffset != nil || tracker.isVisible ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct NotchHistoryScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
