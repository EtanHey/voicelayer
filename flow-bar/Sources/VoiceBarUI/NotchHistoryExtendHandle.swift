import AppKit
import SwiftUI

/// V6: the handle under the last row (the mock's `.pull`). It draws the handle, brightens under the pointer, gives
/// VoiceOver the same one-row steps, and owns its own drag: on macOS 26 the panel's content lives in the glass
/// material's nested NSHostingView, so BarView's canvas gesture never sees a press here (2.3 U4 native, M1).
/// `onDrag` reports the pointer's y (one coordinate space for the whole drag) and the sample's time on
/// NotchHistoryClock's monotonic base (the gesture's own timestamp); `onDragEnd` fires
/// exactly once per drag, `true` when the system cancelled it (no `onEnded`) or the handle unmounted.
///
/// The Settings drawer has the same grip at its bottom edge (`rows` nil): there it only pushes the drawer closed
/// (Etan, QA 0510 N4), and VoiceOver reads it as the drawer's grip with no row steps.
struct NotchHistoryExtendHandle: View {
    let palette: VoiceBarNotchContrastPalette
    /// History's rows and their one-row VoiceOver steps; nil for the Settings drawer's grip.
    var rows: (current: Int, maximum: Int, onAdjust: (Int) -> Void)?
    /// 0510 N6: while a pull is armed for Settings its hint takes the grip's band, so the grip is not drawn.
    var showsGrip = true
    var onDrag: ((CGFloat, TimeInterval) -> Void)?
    var onDragEnd: ((Bool) -> Void)?
    @State private var isHovered = false
    @State private var ownsPointer = false
    @GestureState private var isDragGestureActive = false

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(palette.primary.color.opacity(
                    !showsGrip ? 0 : isHovered ? NotchHistoryMorph.handleHoverOpacity : NotchHistoryMorph.handleOpacity
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
            if let rows {
                NotchHistoryExtendAccessibility(rows: rows.current, maximumRows: rows.maximum, onAdjust: rows.onAdjust)
                    .frame(width: NotchHistoryMorph.handleHitWidth, height: NotchHistoryMorph.handleBandHeight)
                    .allowsHitTesting(false)
            } else {
                Color.clear
                    .frame(width: NotchHistoryMorph.handleHitWidth, height: NotchHistoryMorph.handleBandHeight)
                    .accessibilityElement()
                    .accessibilityLabel(NotchHistoryPresentation.drawerGripLabel)
                    .accessibilityIdentifier("notch-drawer-grip")
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($isDragGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                ownsPointer = true
                onDrag?(value.location.y, value.time.timeIntervalSinceReferenceDate)
            }
            .onEnded { _ in releasePointer(cancelled: false) })
        // A cancelled gesture or an unmounted handle never delivers onEnded: release on the gesture state's reset
        // and on disappearance too. Idempotent.
        .onChange(of: isDragGestureActive) { _, active in if !active { releasePointer(cancelled: true) } }
        .onDisappear { releasePointer(cancelled: true) }
    }

    private func releasePointer(cancelled: Bool) {
        guard ownsPointer else { return }
        ownsPointer = false
        onDragEnd?(cancelled)
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
