import Foundation

/// 2.3 U2: the notch's mutually exclusive surfaces. History is the notch's own lower panel; the microphone list is
/// an AppKit menu that hangs from the same spot under the notch. Lane U1 adds the bare-notch menu as a second kind.
public enum VoiceBarNotchMenuKind: Equatable, Sendable {
    case microphone
}

public enum VoiceBarNotchSurface: Equatable, Sendable {
    case none
    case history
    case menu(VoiceBarNotchMenuKind)
}

public enum VoiceBarNotchSurfaceEffect: Equatable, Sendable {
    /// Ask the notch view to close History. Its close arrives later, through `historyDidChange(isOpen: false)`.
    case closeHistory
    /// Show this menu now. AppKit menu tracking is modal; `menuDidClose()` follows when it ends.
    case showMenu(VoiceBarNotchMenuKind)
}

/// Order of events (formal/notch-surfaces/NotchSurfaces.tla): History's open state lives in the SwiftUI view and
/// changes one update after it is asked to, and AppKit does not run SwiftUI updates while a menu is tracking. A
/// menu shown straight after asking History to close would hang over a still-open History panel for as long as
/// the menu stays open. So a menu requested while History is open waits (`pendingMenu`) until the view reports
/// History closed, and a History that opens again first cancels the wait.
public struct VoiceBarNotchSurfaceCoordinator: Equatable, Sendable {
    public private(set) var historyOpen = false
    public private(set) var shownMenu: VoiceBarNotchMenuKind?
    public private(set) var pendingMenu: VoiceBarNotchMenuKind?

    public init() {}

    public var surface: VoiceBarNotchSurface {
        if let shownMenu { return .menu(shownMenu) }
        return historyOpen ? .history : .none
    }

    public mutating func requestMenu(_ kind: VoiceBarNotchMenuKind) -> [VoiceBarNotchSurfaceEffect] {
        // A menu is modal while it tracks; a second request cannot arrive then, but never stack two.
        guard shownMenu == nil else { return [] }
        if historyOpen {
            pendingMenu = kind
            return [.closeHistory]
        }
        pendingMenu = nil
        shownMenu = kind
        return [.showMenu(kind)]
    }

    public mutating func historyDidChange(isOpen: Bool) -> [VoiceBarNotchSurfaceEffect] {
        historyOpen = isOpen
        if isOpen {
            // The user opened History again before the close landed: History wins, the menu is dropped.
            pendingMenu = nil
            return []
        }
        guard let kind = pendingMenu, shownMenu == nil else { return [] }
        pendingMenu = nil
        shownMenu = kind
        return [.showMenu(kind)]
    }

    public mutating func menuDidClose() {
        shownMenu = nil
    }
}
