import AppKit
import SwiftUI
/// Pointer events stay with BarView. Native key/AX adapters exist; production focus and VoiceOver hit testing need M1 acceptance.
struct BareNotchMenuControl: NSViewRepresentable {
    var isExpanded: Bool
    var onMenu: () -> Void
    var onHistory: () -> Void
    var onClose: () -> Void
    func makeNSView(context: Context) -> BareNotchMenuButton { BareNotchMenuButton() }
    func updateNSView(_ view: BareNotchMenuButton, context: Context) {
        view.onMenu = onMenu
        view.onHistory = onHistory
        view.onClose = onClose
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.menuButton)
        view.setAccessibilityLabel("VoiceBar menu")
        view.setAccessibilityHelp("Click for the menu, pull down for History.")
        view.setAccessibilityIdentifier("voicebar.bare-notch")
        view.setAccessibilityExpanded(isExpanded)
    }
}
final class BareNotchMenuButton: NSView {
    var onMenu: () -> Void = {}
    var onHistory: () -> Void = {}
    var onClose: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityPerformPress() -> Bool { onMenu(); return true }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 36, 76: onMenu()
        case 125: onHistory()
        case 53: onClose()
        default: super.keyDown(with: event)
        }
    }
}
