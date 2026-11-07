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
        ZStack {
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
                .accessibilityHidden(true)
            NotchHistoryExtendAccessibility(rows: rows, maximumRows: maximumRows, onAdjust: onAdjust)
                .frame(width: NotchHistoryMorph.handleHitWidth, height: NotchHistoryMorph.handleBandHeight)
        }
    }
}

/// The custom SwiftUI grip lost its AXValue in the native U4 run. A native slider adapter exposes
/// the value and adjustment actions; the existing canvas gesture retains all pointer events.
private struct NotchHistoryExtendAccessibility: NSViewRepresentable {
    let rows: Int
    let maximumRows: Int
    let onAdjust: (Int) -> Void

    func makeNSView(context _: Context) -> NotchHistoryExtendAXView { NotchHistoryExtendAXView() }

    func updateNSView(_ view: NotchHistoryExtendAXView, context _: Context) {
        view.rows = rows
        view.maximumRows = maximumRows
        view.onAdjust = onAdjust
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.slider)
        view.setAccessibilityIdentifier("notch-history-extend-handle")
        view.setAccessibilityLabel(NotchHistoryPresentation.extendHandleLabel)
        view.setAccessibilityValue("\(rows) of \(maximumRows) rows")
    }
}

private final class NotchHistoryExtendAXView: NSView {
    var rows = NotchHistoryMorph.visibleRows
    var maximumRows = NotchHistoryMorph.visibleRows
    var onAdjust: (Int) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func accessibilityPerformIncrement() -> Bool {
        guard rows < maximumRows else { return false }
        onAdjust(1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard rows > NotchHistoryMorph.visibleRows else { return false }
        onAdjust(-1)
        return true
    }
}
