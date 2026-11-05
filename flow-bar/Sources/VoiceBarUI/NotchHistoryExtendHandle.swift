import AppKit
import SwiftUI

/// V6: the handle under the last row (the mock's `.pull`). Dragging it is BarView's canvas gesture
/// (`NotchHistoryPull.acceptsHandle`); this view draws it, brightens under the pointer, and gives VoiceOver the
/// same one-row steps.
struct NotchHistoryExtendHandle: View {
    let palette: VoiceBarNotchContrastPalette
    let rows: Int
    let maximumRows: Int
    let onAdjust: (Int) -> Void
    @State private var isHovered = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(palette.primary.color.opacity(
                isHovered ? NotchHistoryMorph.handleHoverOpacity : NotchHistoryMorph.handleOpacity
            ))
            .frame(width: NotchHistoryMorph.handleWidth, height: NotchHistoryMorph.handleThickness)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .frame(width: NotchHistoryMorph.handleHitWidth, height: NotchHistoryMorph.handleBandHeight)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard hovering != isHovered else { return }
                isHovered = hovering
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHovered { NSCursor.pop() }
                isHovered = false
            }
            // A grip, not an icon button: no tooltip (the tooltip rule is for controls); VoiceOver names it.
            .accessibilityElement()
            .accessibilityIdentifier("notch-history-extend-handle")
            .accessibilityLabel(NotchHistoryPresentation.extendHandleLabel)
            .accessibilityValue("\(rows) of \(maximumRows) rows")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onAdjust(1)
                case .decrement: onAdjust(-1)
                @unknown default: break
                }
            }
    }
}
