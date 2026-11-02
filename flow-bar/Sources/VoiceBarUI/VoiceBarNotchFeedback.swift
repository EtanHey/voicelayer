import AppKit
import SwiftUI

/// Presentation only. A failure has no reliable recording identity here, so recovery navigates to
/// the existing full History window; it never guesses a recording or sends a retry/record command.
public struct VoiceBarNotchFeedback: Equatable {
    public let statusText: String?
    public let noteText: String?
    public let opensHistory: Bool
    public let replacesWingText: Bool
    public let wingText: String
    public let width: CGFloat
    public let statusHeight: CGFloat
    public let noteHeight: CGFloat
    public var height: CGFloat { statusHeight + noteHeight }
    public static let maximumTextHeight: CGFloat = 72
    public static let historyButtonWidth: CGFloat = 96
    public static let historyButtonSpacing: CGFloat = 8

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

    public static func resolve(input: VoiceBarNotchOperationalInput,
                               presentation: VoiceBarNotchPresentation) -> Self? {
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
        // Recording/teleprompter controls carry the primary state; expose their named status only when
        // it is long or explicitly a command/clip label. Processing already has a spinner and waveform.
        let eligible = input.mode != .transcribing && (presentation.visualState == .compactStatus || input.mode == .error ||
            (input.mode == .recording && (input.commandModeState != nil || input.activeClipMarker != nil)) ||
            (presentation.visualState == .history &&
                (input.confirmationText != nil || input.commandModeState != nil || input.activeClipMarker != nil)))
        let status = !text.isEmpty && eligible && (overflow || input.mode == .error)
            ? text : nil
        let note = input.transientNote.flatMap { $0.isEmpty ? nil : $0 }
        let noteNeedsWrap = note.map {
            Self.textHeight($0, width: presentation.geometry.bodyWidth - 32) > 17
        } == true
        // Preserve the established single-line note geometry and renderer when it already fits.
        guard status != nil || noteNeedsWrap else { return nil }
        // Reuse the compact note shell's fitted width; additional text grows down, never out to the canvas.
        let width = presentation.geometry.bodyFlushWithWings.bodyWidth
        let failure = input.mode == .error && status != nil
        // Keep the complete sentence in the note. A cancellation has a concise
        // semantic label; other overflowing copy needs no duplicate wing label.
        let shortText = text.lowercased().contains("cancel") ? "Cancelled" : ""
        let shortWidth = (shortText as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]).width
        let wingText = overflow ? (shortWidth <= available ? shortText : "") : text
        return Self(
            statusText: status, noteText: note, opensHistory: failure, replacesWingText: overflow,
            wingText: wingText, width: width,
            statusHeight: status.map {
                max(VoiceBarNotchContract.transientNoteBandHeight,
                    min(maximumTextHeight, Self.textHeight($0,
                        width: Self.messageWidth(width, opensHistory: failure))) + 10)
            } ?? 0,
            noteHeight: note.map {
                max(VoiceBarNotchContract.transientNoteBandHeight,
                    min(maximumTextHeight, Self.textHeight($0, width: width - 32)) + 10)
            } ?? 0
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
                VoiceBarNotchTransientNoteBand(text: note, width: feedback.width, height: feedback.noteHeight)
            }
            if let status = feedback.statusText {
                VoiceBarNotchTransientNoteBand(text: status, width: feedback.width, height: feedback.statusHeight,
                    onOpenHistory: feedback.opensHistory ? onOpenHistory : nil)
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
        HStack(spacing: VoiceBarNotchFeedback.historyButtonSpacing) {
            message(viewport: height - 10)
                .frame(width: VoiceBarNotchFeedback.messageWidth(width, opensHistory: onOpenHistory != nil))
            if let onOpenHistory {
                Button("Open History", action: onOpenHistory)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: VoiceBarNotchFeedback.historyButtonWidth)
                    .accessibilityHint("Opens the History settings window. Select a recording there to retry transcription.")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, VoiceBarNotchContract.transientNoteHorizontalInset)
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
        Text(text).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
            .id(text)
            .transition(.identity)
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
