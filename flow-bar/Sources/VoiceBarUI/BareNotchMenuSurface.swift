import AppKit

/// 2.3 SPEC lane U1: the bare notch's menu as a surface. The click-vs-drag rule and the one-surface rule belong to
/// lane U2/U4's surface coordinator; this file is the view-only seam that coordinator presents the menu through.
public enum BareNotchAccessibility {
    /// The bare notch is a button (SPEC § Accessibility).
    public static let label = "VoiceBar menu"
    public static let help = "Click for the menu, pull down for History."
}

/// Keys on the focused bare notch: Return opens the menu, ↓ opens History, Esc closes whatever is open.
public enum BareNotchKeyCommand: Equatable {
    case openMenu
    case openHistory
    case close

    public static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> BareNotchKeyCommand? {
        // ⌘↓ or ⌥Return mean something else to the frontmost app; only the bare key acts here.
        let chords = modifiers.intersection([.command, .option, .control, .shift])
        guard chords.isEmpty else { return nil }
        switch keyCode {
        case 36, 76: return .openMenu // Return, keypad Enter
        case 125: return .openHistory // Down arrow
        case 53: return .close // Escape
        default: return nil
        }
    }
}

/// Pops the notch menu up under the notch and reports whether it is open, which the bare notch mirrors as its
/// expanded state. `NSMenu.popUp` tracks synchronously, so the menu is open exactly for the length of that call.
/// No animation of its own: the system menu already appears instantly, which is right for something opened many
/// times a day and from the keyboard.
@MainActor
public final class BareNotchMenuPresenter {
    public typealias PopUp = @MainActor (NSMenu, NSPoint, NSView) -> Void

    public private(set) var isExpanded = false
    public var onExpandedChange: (Bool) -> Void = { _ in }
    private let popUp: PopUp

    public init(popUp: @escaping PopUp = { menu, point, view in
        _ = menu.popUp(positioning: nil, at: point, in: view)
    }) {
        self.popUp = popUp
    }

    /// A second request while the menu is tracking is ignored: one surface at a time.
    @discardableResult
    public func present(_ menu: NSMenu, at point: NSPoint, in view: NSView) -> Bool {
        guard !isExpanded else { return false }
        setExpanded(true)
        defer { setExpanded(false) }
        popUp(menu, point, view)
        return true
    }

    private func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        onExpandedChange(expanded)
    }
}
