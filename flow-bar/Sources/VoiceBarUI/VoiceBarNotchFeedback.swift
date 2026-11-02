import AppKit
import SwiftUI

/// Presentation only. A failure has no reliable recording identity here, so recovery navigates to
/// the existing full History window; it never guesses a recording or sends a retry/record command.
public struct VoiceBarNotchFeedback: Equatable {
    public let statusText: String?
    public let noteText: String?
    /// N5: the status row (an error diagnostic) carries the inline History action.
    public let statusOpensHistory: Bool
    /// N5: the note row (a busy-selection note) carries the inline History action.
    public let noteOpensHistory: Bool
    public var opensHistory: Bool { statusOpensHistory || noteOpensHistory }
    public let replacesWingText: Bool
    public let wingText: String
    public let width: CGFloat
    public let statusHeight: CGFloat
    public let noteHeight: CGFloat
    public var height: CGFloat { statusHeight + noteHeight }
    /// N3: text grows downward to this many points (about five lines) before the note scrolls; never "…".
    public static let maximumTextHeight: CGFloat = 80
    /// N5: the History action is a compact glyph button on the message's own row. A labelled bordered button
    /// (96 pt) left a ~49 pt text column at notch width; the glyph keeps the words readable beside it.
    public static let historyButtonWidth: CGFloat = 22
    public static let historyButtonSpacing: CGFloat = 6
    public static let historyActionTitle = "Open History"

    public static func messageWidth(_ width: CGFloat, opensHistory: Bool) -> CGFloat {
        max(1, width - 2 * VoiceBarNotchContract.transientNoteHorizontalInset -
            (opensHistory ? historyButtonWidth + historyButtonSpacing : 0))
    }

    public static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        )
        // Keep at least one 16 pt line slot; multiline height comes from the actual system font.
        return ceil(max(16, rect.height))
    }

    static func bandHeight(_ text: String, width: CGFloat, opensHistory: Bool) -> CGFloat {
        max(VoiceBarNotchContract.transientNoteBandHeight,
            min(maximumTextHeight, textHeight(text, width: messageWidth(width, opensHistory: opensHistory))) + 10)
    }

    /// The notch's notice policy (formal/notch-presentation, Fixed):
    /// - N2: nothing is shown under the notch while transcribing; the spinner and blue carry it.
    /// - N1: a visible notice (an error diagnostic, an idle confirmation, a note) is always the compact tab under
    ///   the notch and never also a wing label.
    /// - N4: an empty diagnostic is hidden; no "Error" or "Details below" copy is invented.
    /// - N5: an error diagnostic and a busy-selection note each carry Open History inline.
    /// Operational labels (F5 hints, recording command/clip names) stay in the wing unless they overflow it.
    public static func resolve(input: VoiceBarNotchOperationalInput,
                               presentation: VoiceBarNotchPresentation) -> Self? {
        guard input.mode != .transcribing else { return nil }
        let text = input.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let insets = WaveformLayout.coreGap + WaveformLayout.outerInset +
            VoiceBarNotchContract.compactStatusTrailingSafetyInset
        let accessories: CGFloat = input.mode == .error ? 23 :
            (input.mode == .idle && input.queueDepth > 0
                ? Theme.intrinsicPillStatusWidth(for: "\(input.queueDepth)") + 16 : 0)
        let available = presentation.geometry.trailingWingWidth - insets - accessories
        let measured = (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]).width
        let allowedLines = input.mode == .idle && TwoLineStatusFeedback.contains(input.confirmationText) ? 2 : 1
        let overflow = text.components(separatedBy: "\n").count > allowedLines || measured > available
        let confirmation = input.confirmationText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isNotice = input.mode == .error || (input.mode == .idle && !confirmation.isEmpty)
        // Recording/teleprompter controls carry the primary state; expose their named status only when
        // it is long or explicitly a command/clip label.
        let eligible = presentation.visualState == .compactStatus || isNotice ||
            (input.mode == .recording && (input.commandModeState != nil || input.activeClipMarker != nil)) ||
            (presentation.visualState == .history && (input.commandModeState != nil || input.activeClipMarker != nil))
        let status = !text.isEmpty && eligible && (overflow || isNotice) ? text : nil
        let note = input.transientNote.flatMap { $0.isEmpty ? nil : $0 }
        let noteOpensHistory = note.map(VoiceBarPresentation.isSelectionBusyNote) == true
        // N1: every note is the compact tab under the notch, never a band across the wings.
        let width = VoiceBarNotchContract.noteColumnWidth(
            for: presentation.geometry, ownBodyHeight: presentation.ownBodyHeight
        )
        let noteNeedsWrap = note.map {
            Self.textHeight($0, width: Self.messageWidth(width, opensHistory: false)) > 17
        } == true
        // A short plain note keeps the established single-line renderer.
        guard status != nil || noteNeedsWrap || noteOpensHistory else { return nil }
        let statusOpensHistory = input.mode == .error && status != nil
        return Self(
            statusText: status, noteText: note,
            statusOpensHistory: statusOpensHistory, noteOpensHistory: noteOpensHistory,
            replacesWingText: true,
            // N1: while a notice shows, the wing carries no label; the full copy lives in the tab.
            wingText: "",
            width: width,
            statusHeight: status.map { bandHeight($0, width: width, opensHistory: statusOpensHistory) } ?? 0,
            noteHeight: note.map { bandHeight($0, width: width, opensHistory: noteOpensHistory) } ?? 0
        )
    }
}

/// The same view is mounted by BarView and the silent snapshot executable. Text is never line-limited;
/// exceptionally long diagnostics scroll inside a bounded viewport instead of expanding off screen.
public struct VoiceBarNotchFeedbackBand: View {
    public let feedback: VoiceBarNotchFeedback
    public var onOpenHistory: () -> Void
    public init(feedback: VoiceBarNotchFeedback, onOpenHistory: @escaping () -> Void) {
        self.feedback = feedback
        self.onOpenHistory = onOpenHistory
    }
    public var body: some View {
        VStack(spacing: 0) {
            if let note = feedback.noteText {
                VoiceBarNotchTransientNoteBand(text: note, width: feedback.width, height: feedback.noteHeight,
                    onOpenHistory: feedback.noteOpensHistory ? onOpenHistory : nil)
            }
            if let status = feedback.statusText {
                VoiceBarNotchTransientNoteBand(text: status, width: feedback.width, height: feedback.statusHeight,
                    onOpenHistory: feedback.statusOpensHistory ? onOpenHistory : nil)
            }
        }
        .frame(maxWidth: .infinity)
        // Replace selectable text and its layout atomically. The outer shell owns
        // its shape animation; inherited spring transactions must not retain old glyphs.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

/// The original transient note node, shared by short selection notes and wrapped status/error text.
public struct VoiceBarNotchTransientNoteBand: View {
    public let text: String
    public let width: CGFloat
    public let height: CGFloat
    public var onOpenHistory: (() -> Void)?

    public init(text: String, width: CGFloat, height: CGFloat = VoiceBarNotchContract.transientNoteBandHeight,
                onOpenHistory: (() -> Void)? = nil) {
        self.text = text
        self.width = width
        self.height = height
        self.onOpenHistory = onOpenHistory
    }

    public var body: some View {
        // N5: the action shares the message's row, trailing it; the note never grows a second row for it.
        HStack(alignment: .center, spacing: VoiceBarNotchFeedback.historyButtonSpacing) {
            message(viewport: height - 10)
                .frame(width: VoiceBarNotchFeedback.messageWidth(width, opensHistory: onOpenHistory != nil))
            if let onOpenHistory {
                VoiceBarNotchHistoryActionButton(action: onOpenHistory)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .frame(width: width - 2 * VoiceBarNotchContract.transientNoteHorizontalInset)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    @ViewBuilder private func message(viewport: CGFloat) -> some View {
        if VoiceBarNotchFeedback.textHeight(text,
            width: VoiceBarNotchFeedback.messageWidth(width, opensHistory: onOpenHistory != nil)) > viewport {
            VStack(spacing: 2) {
                ScrollView(.vertical) { label }
                    .scrollIndicators(.visible)
                    .accessibilityHint("Scroll for the full message")
                Text("Scroll for full message").font(.system(size: 10)).opacity(0.7)
            }.frame(height: viewport)
        } else {
            label
        }
    }
    private var label: some View {
        // N3: wrap and grow down; never a line limit, never "…".
        Text(text).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(onOpenHistory == nil ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: onOpenHistory == nil ? .center : .leading)
            .textSelection(.enabled)
            .id(text)
            .transition(.identity)
    }
}

/// The compact inline History action: a glyph the size of the wing controls, named for VoiceOver and on hover.
struct VoiceBarNotchHistoryActionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: VoiceBarNotchFeedback.historyButtonWidth,
                       height: VoiceBarNotchFeedback.historyButtonWidth)
                .contentShape(Circle())
        }
        .buttonStyle(VoiceBarNotchHistoryActionStyle())
        .frame(width: VoiceBarNotchFeedback.historyButtonWidth)
        .background(PillControlTooltip(text: VoiceBarNotchFeedback.historyActionTitle))
        .accessibilityLabel(VoiceBarNotchFeedback.historyActionTitle)
        .accessibilityHint("Opens the History settings window. Select a recording there to retry transcription.")
        .accessibilityIdentifier("VoiceBarNotchFeedback.openHistory")
    }
}

private struct VoiceBarNotchHistoryActionStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.white.opacity(isHovered ? 0.22 : 0.14)))
            // Press feedback without moving the row: scale in place, quick ease-out both ways.
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

public extension VoiceBarNotchInteractionConfiguration {
    /// Lower text selection, scrolling and History navigation must pass the AppKit click-through gate.
    func includingFeedback(for presentation: VoiceBarNotchPresentation) -> Self {
        guard presentation.feedback != nil else { return self }
        return Self(leadingControlCount: leadingControlCount,
                    trailingControlCountFromCore: trailingControlCountFromCore,
                    trailingControlCountFromOuter: trailingControlCountFromOuter,
                    trailingOuterInset: trailingOuterInset, lowerControlCount: lowerControlCount,
                    lowerSurfaceIsInteractive: true)
    }
}
