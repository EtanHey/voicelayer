import Foundation
import Observation

/// 2.3 U2: the notch's mutually exclusive surfaces. History is the notch's own lower panel; the microphone list is
/// an AppKit menu that hangs from the same spot under the notch. Lane U1 adds the bare-notch menu as a second kind.
public enum VoiceBarNotchMenuKind: Equatable, Sendable {
    case microphone
    case notch
}

public enum VoiceBarNotchSurface: Equatable, Sendable {
    case none
    case history
    case menu(VoiceBarNotchMenuKind)
}

public enum VoiceBarNotchSurfaceEffect: Equatable, Sendable {
    /// Ask the notch view to close History. Its close arrives later, through `historyDidChange(isOpen: false)`.
    case closeHistory
    /// Schedule this menu's presentation. It shows only if `beginPresenting` still admits it when the scheduled
    /// block runs; AppKit menu tracking is modal and `menuDidClose()` follows when it ends.
    case showMenu(VoiceBarNotchMenuKind)
}

/// Order of events (formal/notch-surfaces/NotchSurfaces.tla): History's open state lives in the SwiftUI view and
/// changes one update after it is asked to, and AppKit does not run SwiftUI updates while a menu is tracking. So:
/// - a menu requested while History is open waits (`pendingMenu`) until the view reports History closed;
/// - a menu is presented from a scheduled block, so between the request and that block it is only `queuedMenu`.
///   History opening in between cancels it, and `beginPresenting` re-checks before anything is shown (U2 review
///   R1: marking it shown at request time let a History opened in that gap sit under the menu).
public struct VoiceBarNotchSurfaceCoordinator: Equatable, Sendable {
    public private(set) var historyOpen = false
    public private(set) var shownMenu: VoiceBarNotchMenuKind?
    public private(set) var queuedMenu: VoiceBarNotchMenuKind?
    public private(set) var pendingMenu: VoiceBarNotchMenuKind?

    public init() {}

    public var surface: VoiceBarNotchSurface {
        if let shownMenu { return .menu(shownMenu) }
        return historyOpen ? .history : .none
    }

    public mutating func requestMenu(_ kind: VoiceBarNotchMenuKind) -> [VoiceBarNotchSurfaceEffect] {
        // Never stack two menus, and never queue a second presentation behind one already scheduled.
        guard shownMenu == nil, queuedMenu == nil else { return [] }
        if historyOpen {
            pendingMenu = kind
            return [.closeHistory]
        }
        pendingMenu = nil
        queuedMenu = kind
        return [.showMenu(kind)]
    }

    public mutating func historyDidChange(isOpen: Bool) -> [VoiceBarNotchSurfaceEffect] {
        historyOpen = isOpen
        if isOpen {
            // The user opened History before the menu showed: History wins, the waiting or queued menu is dropped.
            pendingMenu = nil
            queuedMenu = nil
            return []
        }
        guard let kind = pendingMenu, shownMenu == nil, queuedMenu == nil else { return [] }
        pendingMenu = nil
        queuedMenu = kind
        return [.showMenu(kind)]
    }

    /// U2×U4 review: the user asked for History again (a click or a pull) while it was still mounted, e.g. while
    /// its close spring runs after a menu request asked it to close. No mount change fires then, so this cancels
    /// the waiting or queued menu explicitly: History wins, and a later close never opens a stale list.
    public mutating func historyOpenRequested() {
        pendingMenu = nil
        queuedMenu = nil
    }

    /// The scheduled presentation block calls this first. False means it was cancelled (History opened, or a
    /// different presentation owns the spot): show nothing.
    public mutating func beginPresenting(_ kind: VoiceBarNotchMenuKind) -> Bool {
        guard queuedMenu == kind, !historyOpen, shownMenu == nil else { return false }
        queuedMenu = nil
        shownMenu = kind
        return true
    }

    public mutating func cancelQueuedMenu() {
        queuedMenu = nil
        pendingMenu = nil
    }

    public mutating func menuDidClose() {
        shownMenu = nil
    }
}

/// 2.3 U2: the notch view's History state, shared by the production app and the QA host. The view reports every
/// open/close here and closes History when `closeRequest` changes. (U2 review R1: the UIE2E host must drive the
/// same handoff as the app.)
/// Main thread only, like `VoiceBarNotchPresentationModel`.
@Observable
public final class VoiceBarNotchHistoryBridge {
    public private(set) var closeRequest = 0
    public private(set) var isHistoryOpen = false
    public fileprivate(set) var presentedMenu: VoiceBarNotchMenuKind?
    @ObservationIgnored public var onHistoryPanelChanged: (Bool) -> Void = { _ in }
    /// Every open intent (a click or a pull), mounted or not. Deliberately not de-duplicated: reopening a History
    /// that is still mounted (closing) changes no mount state, so `historyDidChange` cannot carry it.
    @ObservationIgnored public var onHistoryOpenRequested: () -> Void = {}

    public init() {}

    public func requestClose() {
        closeRequest &+= 1
    }

    public func historyOpenRequested() {
        onHistoryOpenRequested()
    }

    public func historyDidChange(isOpen: Bool) {
        guard isHistoryOpen != isOpen else { return }
        isHistoryOpen = isOpen
        onHistoryPanelChanged(isOpen)
    }
}

/// 2.3 U2: the one production path from "a notch menu was asked for" to an AppKit menu on screen, used by
/// `AppDelegate` and the UIE2E host alike. Presentation runs from `schedule` (the next main-queue turn in the app;
/// tests and the QA host can hold it) and is re-validated by the coordinator when it runs. Main thread only.
public final class VoiceBarNotchSurfaceHandoff {
    public enum Outcome: Equatable, Sendable {
        case presented(VoiceBarNotchMenuKind)
        case cancelled(VoiceBarNotchMenuKind)
    }

    public private(set) var coordinator = VoiceBarNotchSurfaceCoordinator()
    public let bridge: VoiceBarNotchHistoryBridge
    /// Shows the menu and returns when its (modal) tracking ends.
    private let present: (VoiceBarNotchMenuKind) -> Void
    private let presentationModel: VoiceBarNotchPresentationModel?
    public var schedule: (@escaping () -> Void) -> Void = { block in
        DispatchQueue.main.async(execute: block)
    }
    public var onOutcome: (Outcome) -> Void = { _ in }

    public init(bridge: VoiceBarNotchHistoryBridge, presentationModel: VoiceBarNotchPresentationModel? = nil, present: @escaping (VoiceBarNotchMenuKind) -> Void) {
        self.bridge = bridge
        self.present = present
        self.presentationModel = presentationModel
        bridge.onHistoryPanelChanged = { [weak self] isOpen in
            self?.historyDidChange(isOpen: isOpen)
        }
        bridge.onHistoryOpenRequested = { [weak self] in
            self?.coordinator.historyOpenRequested()
        }
    }

    public func requestMenu(_ kind: VoiceBarNotchMenuKind) {
        apply(coordinator.historyDidChange(isOpen: bridge.isHistoryOpen))
        apply(coordinator.requestMenu(kind))
    }

    public func cancelQueuedMenu() { coordinator.cancelQueuedMenu() }

    private func historyDidChange(isOpen: Bool) {
        apply(coordinator.historyDidChange(isOpen: isOpen))
    }

    private func apply(_ effects: [VoiceBarNotchSurfaceEffect]) {
        for effect in effects {
            switch effect {
            case .closeHistory:
                bridge.requestClose()
            case let .showMenu(kind):
                // A menu shown from inside a SwiftUI update or AppKit callback would track inside it.
                schedule { [weak self] in self?.presentIfStillAdmitted(kind) }
            }
        }
    }

    private func presentIfStillAdmitted(_ kind: VoiceBarNotchMenuKind) {
        guard coordinator.beginPresenting(kind) else {
            onOutcome(.cancelled(kind))
            return
        }
        bridge.presentedMenu = kind
        presentationModel?.setMenuPresented(true)
        onOutcome(.presented(kind))
        defer {
            coordinator.menuDidClose()
            bridge.presentedMenu = nil
            presentationModel?.setMenuPresented(false)
        }
        present(kind)
    }
}
