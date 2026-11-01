import AppKit
import SwiftUI

/// Presentation only. A failure has no reliable recording identity here, so recovery navigates to
/// the existing full History window; it never guesses a recording or sends a retry/record command.
public struct VoiceBarNotchFeedback: Equatable {
    public let statusText: String?
    public let noteText: String?
    public let opensHistory: Bool
    public let replacesWingText: Bool
    public let width: CGFloat
    public let statusHeight: CGFloat
    public let noteHeight: CGFloat
    public var height: CGFloat { statusHeight + noteHeight }
    public static let maximumTextHeight: CGFloat = 72

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
        // it is long or explicitly a command/clip label. Processing currently has no wing text at all.
        let eligible = presentation.visualState == .compactStatus || input.mode == .error ||
            input.mode == .transcribing ||
            (input.mode == .recording && (input.commandModeState != nil || input.activeClipMarker != nil)) ||
            (presentation.visualState == .history &&
                (input.confirmationText != nil || input.commandModeState != nil || input.activeClipMarker != nil))
        let status = !text.isEmpty && eligible && (overflow || input.mode == .transcribing || input.mode == .error)
            ? text : nil
        let note = input.transientNote.flatMap { $0.isEmpty ? nil : $0 }
        let noteNeedsWrap = note.map {
            Self.textHeight($0, width: presentation.geometry.bodyWidth - 32) > 17
        } == true
        // Preserve the established single-line note geometry and renderer when it already fits.
        guard status != nil || noteNeedsWrap else { return nil }
        let width = max(presentation.geometry.bodyWidth,
                        input.coreWidth + 2 * VoiceBarNotchContract.morphCanvasWingCapacity)
        let failure = input.mode == .error && status != nil
        return Self(
            statusText: status, noteText: note, opensHistory: failure, replacesWingText: overflow, width: width,
            statusHeight: status.map {
                min(maximumTextHeight, Self.textHeight($0, width: width - 32) + 4) + 16 + (failure ? 34 : 0)
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
                text(note, viewport: feedback.noteHeight - 10)
                    .padding(.horizontal, 16)
                    .frame(height: feedback.noteHeight)
            }
            if let status = feedback.statusText {
                VStack(alignment: .leading, spacing: 6) {
                    text(status, viewport: feedback.statusHeight - 16 - (feedback.opensHistory ? 34 : 0))
                    if feedback.opensHistory {
                        Button("Open History", action: onOpenHistory)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint("Opens the History settings window. Select a recording there to retry transcription.")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(height: feedback.statusHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .font(.system(size: 12, weight: .medium))
        // Replace selectable text and its layout atomically. The outer shell owns
        // its shape animation; inherited spring transactions must not retain old glyphs.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
    @ViewBuilder private func text(_ value: String, viewport: CGFloat) -> some View {
        if VoiceBarNotchFeedback.textHeight(value, width: feedback.width - 32) > viewport {
            VStack(alignment: .leading, spacing: 2) {
                ScrollView(.vertical) { label(value) }
                    .scrollIndicators(.visible)
                    .accessibilityHint("Scroll for the full message")
                Text("Scroll for full message").font(.system(size: 10)).opacity(0.7)
            }.frame(height: viewport)
        } else {
            label(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func label(_ value: String) -> some View {
        Text(value).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .id(value)
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
