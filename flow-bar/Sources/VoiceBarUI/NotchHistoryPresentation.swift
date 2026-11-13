import AppKit
import CoreGraphics
import Foundation

/// Copy, metrics and actions for the notch History panel. 2.3 lane U4 (approved mock 5-history): two-line rows,
/// six visible collapsed and eight expanded (Etan, 2026-11-08), the dictation over "when · length"; Copy / Paste / Transcribe again on hover; no footer.
public enum NotchHistoryPresentation {
    // Row metrics (mock.css `.row.two`).
    public static let rowLeadingPadding: CGFloat = 10
    public static let rowTrailingPadding: CGFloat = 6
    public static let rowCornerRadius: CGFloat = 8
    public static let rowColumnSpacing: CGFloat = 10
    public static let rowLineSpacing: CGFloat = 2
    public static let rowTextFontSize: CGFloat = 13
    public static let rowMetaFontSize: CGFloat = 11.5
    /// The hover highlight (`--vb-hover`, white at 9 %), drawn in the palette's primary label colour.
    public static let rowHoverOpacity: Double = 0.09
    /// The action column's minimum width (`.row .acts { min-width: 66px }`).
    public static let rowActionsMinimumWidth: CGFloat = 66

    // Scroll indicator (5-history `.sb`): 4 pt wide, 1 pt outside the list's right edge, only while scrolling.
    public static let scrollIndicatorWidth: CGFloat = 4
    public static let scrollIndicatorGap: CGFloat = 1
    public static let scrollIndicatorMinimumHeight: CGFloat = 24
    public static let scrollIndicatorFadeIn: TimeInterval = 0.08
    public static let scrollIndicatorFadeOut: TimeInterval = 0.3
    public static let scrollIndicatorLinger: TimeInterval = 0.7

    /// The thumb's top and height inside the visible list, or nil when the content fits (no indicator at all).
    public static func scrollThumb(
        offset: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat
    ) -> (minY: CGFloat, height: CGFloat)? {
        guard contentHeight > visibleHeight + 0.5, visibleHeight > 0 else { return nil }
        let height = max(scrollIndicatorMinimumHeight, visibleHeight / contentHeight * visibleHeight)
        let travel = contentHeight - visibleHeight
        let fraction = min(1, max(0, offset / travel))
        return (fraction * (visibleHeight - height), height)
    }

    /// The row under a point `y` from the top of the list content (the one container hover tracker).
    public static func rowIndex(atY y: CGFloat, rowCount: Int) -> Int? {
        guard y >= 0, rowCount > 0 else { return nil }
        let index = Int(y / NotchHistoryMorph.rowHeight)
        return index < rowCount ? index : nil
    }

    public static let firstWordsLimit = 90
    /// Spec §4: 24 pt hit targets (R4 UI pass #19 found 10–12 pt ones in Settings), the shared Copy button's size.
    public static let rowActionSize: CGFloat = CopyFeedbackButton.hitTarget

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

    // MARK: Categories (lane H)

    public struct EmptyState: Equatable, Sendable {
        public let title: String
        public let detail: String
    }

    /// The selector's height and the gap under it; the list gives up this much, the drawer's height does not change.
    public static let categorySelectorHeight: CGFloat = 22
    public static let categorySelectorGap: CGFloat = 4
    public static let categorySelectorFontSize: CGFloat = 11.5
    public static let categorySelectorLabel = "History category"
    public static let emptyRowIdentifier = "history-empty-row"

    public static func categoryIdentifier(_ scope: SettingsHistoryScope) -> String { "history-category-\(scope.rawValue)" }

    /// A segment's tooltip (every notch control has one, R0856-09).
    public static func categoryTooltip(_ scope: SettingsHistoryScope) -> String {
        switch scope {
        case .recording: "What you dictated"
        case .ask: "Your answers to spoken questions"
        case .speech: "Text read aloud to you"
        }
    }

    /// `isLoaded` is false only while a category's first archive read is still running.
    public static func emptyState(for scope: SettingsHistoryScope, isLoaded: Bool = true) -> EmptyState {
        guard isLoaded else { return EmptyState(title: "Loading…", detail: "") }
        switch scope {
        case .recording:
            return EmptyState(title: "No dictations yet", detail: "What you dictate shows up here.")
        case .ask:
            return EmptyState(title: "No asks yet", detail: "Your answers to an agent's spoken questions show up here.")
        case .speech:
            return EmptyState(title: "Nothing read aloud yet", detail: "Text VoiceBar reads to you shows up here.")
        }
    }

    public static let openHint = "Opens this recording in the History window"

    public static func openHint(for scope: SettingsHistoryScope) -> String {
        switch scope {
        case .recording: openHint
        case .ask: "Opens this ask in the History window"
        case .speech: "Opens this speech in the History window"
        }
    }

    /// "history-row-1" for the newest row: one-based, by position in the list.
    public static func rowAccessibilityIdentifier(index: Int) -> String { "history-row-\(index + 1)" }
    public static let extendHandleLabel = "Show more rows"
    /// The Settings drawer's grip (0510 N4, N16): drag it to resize the drawer, or up to close it.
    public static let drawerGripLabel = "Drag to resize, or up to close"
    /// 0510 N6: the overpull hint, which sits in the handle's band and never over a row.
    public static let settingsPullHint = "Release for Settings"
    public static let settingsPullHintIdentifier = "notch-settings-pull-hint"
    public static let settingsPullHintHeight: CGFloat = NotchHistoryMorph.handleBandHeight

    // V12: what a row's text column can show while its hover actions are out (the 404 pt list, the row's insets,
    // the action column and the gap before it).
    public static var rowTextAvailableWidth: CGFloat {
        NotchHistoryMorph.bodyWidth - 2 * NotchHistoryMorph.listHorizontalInset - rowLeadingPadding
            - rowTrailingPadding - rowColumnSpacing - rowActionsMinimumWidth
    }

    public static let clippedTooltipLimit = 600

    /// The row's whole text for its tooltip, only when the row can't show it all: past the first-words cut, or
    /// wider than the text column at 13 pt. Very long dictations stop at 600 characters; the History window has
    /// the rest.
    public static func clippedTextTooltip(_ text: String, availableWidth: CGFloat = rowTextAvailableWidth) -> String? {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        let shown = firstWords(text)
        let width = (shown as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: rowTextFontSize)]).width
        guard shown != flattened || width > availableWidth else { return nil }
        guard flattened.count > clippedTooltipLimit else { return flattened }
        return String(flattened.prefix(clippedTooltipLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The row's first words on one line: whitespace and line breaks collapse, and long text ends in "…".
    public static func firstWords(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > firstWordsLimit else { return flattened }
        return String(flattened.prefix(firstWordsLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The row's second line, "2 min ago · 0:13"; the length only when the dictation's receipt has it. Nil for an entry saved
    /// before times were recorded.
    public static func rowHeader(for entry: RecentTranscriptionEntry, now: Date = Date()) -> String? {
        guard let time = VoiceBarRelativeTime.label(entry.createdAt, now: now) else { return nil }
        guard let receipt = entry.dictationReceipt else { return time }
        let seconds = Int(receipt.audioDuration.rounded())
        return "\(time) · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
