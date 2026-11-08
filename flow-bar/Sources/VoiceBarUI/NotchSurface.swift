import AppKit
import Foundation
import Observation

// 2.4 Lane A: ONE notch surface. The notch owns every drawer that hangs from it (History and Settings) and
// shows the recording wings and the teleprompter. Which drawer is open, and whether one may open at all, is
// decided here and nowhere else. BarView, the dismissal monitors, the gear, the pull gesture and the app send
// events; they never flip a flag of their own. Model: formal/notch-surface/NotchSurface.tla.

/// History's two resting heights (Etan, 2.4: "collapsed 6, expanded 8, scrolls to 20").
public enum NotchHistoryDetent: String, Equatable, Hashable, Sendable, CaseIterable {
    case collapsed
    case expanded

    public var rows: Int {
        switch self {
        case .collapsed: NotchHistoryMorph.visibleRows
        case .expanded: NotchHistoryMorph.maximumRows
        }
    }

    /// The rows this detent shows for `entryCount` dictations: never an empty row past the last one, never
    /// fewer than the collapsed six (the list keeps its shape while the archive is short).
    public func rows(entryCount: Int) -> Int {
        switch self {
        case .collapsed: NotchHistoryMorph.visibleRows
        case .expanded: NotchHistoryMorph.maximumRows(entryCount: entryCount)
        }
    }

    /// The detent nearest to a dragged row count (the extend handle settles on one of the two, never between).
    public static func nearest(rows: CGFloat) -> NotchHistoryDetent {
        let midpoint = CGFloat(NotchHistoryMorph.visibleRows + NotchHistoryMorph.maximumRows) / 2
        return rows >= midpoint ? .expanded : .collapsed
    }
}

extension SettingsTab: @unchecked Sendable {}

/// A drawer hanging from the notch. Exactly one value, so two drawers can never be open together.
public enum NotchDrawer: Equatable, Hashable, Sendable {
    case history(NotchHistoryDetent)
    case settings(SettingsTab)

    public var isHistory: Bool {
        if case .history = self { return true }
        return false
    }

    public var isSettings: Bool {
        if case .settings = self { return true }
        return false
    }
}

/// What the notch shows, derived from the machine. Recording and the teleprompter outrank a drawer, and the
/// machine guarantees a drawer is never open under either.
public enum NotchSurfaceState: Equatable, Hashable, Sendable {
    case closed
    case recording
    case teleprompter
    case history(NotchHistoryDetent)
    case settings(SettingsTab)
}

/// Why a drawer closed. Every dismissal names its cause, and the app logs it (the Esc "receipt" that went
/// missing in NATIVE-U4 is `escape` here).
public enum NotchDismissReason: String, Equatable, Hashable, Sendable, CaseIterable {
    /// A mouse-down anywhere outside the notch: another app, the desktop, VoiceBar's own Settings window, the
    /// menu-bar popover, any other VoiceBar panel.
    case outsideClick
    /// Esc, whichever app is frontmost.
    case escape
    /// The drawer was pushed back up into the notch (the mirror of pulling it down).
    case dragUp
    /// The History button or the gear was pressed again.
    case toggle
    /// A row action finished the drawer's job (Paste, open the recording, open a Settings window tab).
    case action
    /// Dictation, Ask or a read-aloud took the notch.
    case voiceActivity
    /// History emptied while it was open.
    case emptied
    /// A notch menu (the microphone list, the bare-notch menu) asked for the spot.
    case menu
}

public enum NotchSurfaceEvent: Equatable, Hashable, Sendable {
    case openHistory
    case setHistoryDetent(NotchHistoryDetent)
    case openSettings(SettingsTab)
    case selectSettingsTab(SettingsTab)
    case dismiss(NotchDismissReason)
    case recordingChanged(Bool)
    case teleprompterChanged(Bool)
    /// A sheet or modal session in a VoiceBar window (Settings' Add term sheet, an alert) began or ended.
    case modalChanged(Bool)
}

public enum NotchSurfaceRefusal: Equatable, Hashable, Sendable {
    /// The recording wings own the notch; no drawer may hide them.
    case recording
    case teleprompter
    /// A modal Settings sheet or alert is up; a drawer would sit over it and take its clicks.
    case modal
    /// Dismiss, detent or tab change with no matching drawer open.
    case noDrawer
}

public enum NotchSurfaceOutcome: Equatable, Hashable, Sendable {
    case changed(from: NotchSurfaceState, to: NotchSurfaceState)
    case unchanged
    case refused(NotchSurfaceRefusal)
}

/// The machine itself: a pure value, so every transition is unit-testable and the exhaustive conformance test
/// can walk it exactly as TLC walks the model.
public struct NotchSurfaceMachine: Equatable, Hashable, Sendable {
    public private(set) var drawer: NotchDrawer?
    public private(set) var isRecording = false
    public private(set) var isTeleprompterShown = false
    public private(set) var isModal = false
    /// History reopens at the detent it last rested on (the session remembers the handle, as 2.3 V6 did).
    public private(set) var historyDetent: NotchHistoryDetent = .collapsed

    public init() {}

    public var state: NotchSurfaceState {
        if isRecording { return .recording }
        if isTeleprompterShown { return .teleprompter }
        switch drawer {
        case let .history(detent): return .history(detent)
        case let .settings(tab): return .settings(tab)
        case nil: return .closed
        }
    }

    /// Why no drawer may open right now, or nil when one may.
    public var openRefusal: NotchSurfaceRefusal? {
        if isRecording { return .recording }
        if isTeleprompterShown { return .teleprompter }
        if isModal { return .modal }
        return nil
    }

    /// TLA+ `DismissEnabled`: an open drawer can always be dismissed, in every state, by every reason.
    public var canDismiss: Bool { drawer != nil }

    @discardableResult
    public mutating func send(_ event: NotchSurfaceEvent) -> NotchSurfaceOutcome {
        let before = state
        let beforeDrawer = drawer
        switch event {
        case .openHistory:
            if let refusal = openRefusal { return .refused(refusal) }
            drawer = .history(historyDetent)
        case let .setHistoryDetent(detent):
            guard drawer?.isHistory == true else { return .refused(.noDrawer) }
            historyDetent = detent
            drawer = .history(detent)
        case let .openSettings(tab):
            if let refusal = openRefusal { return .refused(refusal) }
            drawer = .settings(tab)
        case let .selectSettingsTab(tab):
            guard drawer?.isSettings == true else { return .refused(.noDrawer) }
            drawer = .settings(tab)
        case .dismiss:
            guard canDismiss else { return .refused(.noDrawer) }
            drawer = nil
        case let .recordingChanged(isRecording):
            self.isRecording = isRecording
            if isRecording { drawer = nil }
        case let .teleprompterChanged(isShown):
            isTeleprompterShown = isShown
            if isShown { drawer = nil }
        case let .modalChanged(isModal):
            self.isModal = isModal
            if isModal { drawer = nil }
        }
        let after = state
        if before != after { return .changed(from: before, to: after) }
        return beforeDrawer == drawer ? .unchanged : .changed(from: before, to: after)
    }

    // MARK: Invariants (the same four TLC checks; the exhaustive Swift walk asserts them on every state)

    /// AtMostOneDrawer is structural (`drawer` is one optional value); this names it for the walk.
    public var atMostOneDrawer: Bool { true }

    /// WingsNeverHidden: while recording no drawer is open.
    public var wingsNeverHidden: Bool { !isRecording || drawer == nil }

    /// NoDrawerOverModal: while a modal sheet or alert is up no drawer is open.
    public var noDrawerOverModal: Bool { !isModal || drawer == nil }

    /// NoDrawerOverTeleprompter: a read-aloud's teleprompter is never covered by a drawer.
    public var noDrawerOverTeleprompter: Bool { !isTeleprompterShown || drawer == nil }

    /// DismissalReachable: every open state can be dismissed.
    public var dismissalReachable: Bool { drawer == nil || canDismiss }
}

/// The observable owner the views and monitors share. Main thread only, like the presentation model.
@MainActor
@Observable
public final class NotchSurfaceModel {
    public private(set) var machine = NotchSurfaceMachine()
    /// Every transition, in order (tests, the UIE2E host's receipts). Bounded.
    public private(set) var journal: [NotchSurfaceJournalEntry] = []
    @ObservationIgnored public var log: (String) -> Void = { NSLog("%@", $0) }
    private static let journalLimit = 64

    public init() {}

    public var drawer: NotchDrawer? { machine.drawer }
    public var state: NotchSurfaceState { machine.state }
    public var isDrawerOpen: Bool { machine.drawer != nil }
    public var historyDetent: NotchHistoryDetent { machine.historyDetent }

    @discardableResult
    public func send(_ event: NotchSurfaceEvent) -> NotchSurfaceOutcome {
        let outcome = machine.send(event)
        switch outcome {
        case .unchanged:
            break
        case let .changed(from, to):
            record(event, outcome)
            log("[VoiceBar] notch surface \(Self.describe(from)) -> \(Self.describe(to)) (\(Self.describe(event)))")
        case let .refused(refusal):
            // An open refused while recording is the normal case (a stray gear click); only log the receipt.
            record(event, outcome)
            if case .dismiss = event { break }
            log("[VoiceBar] notch surface refused \(Self.describe(event)): \(refusal)")
        }
        return outcome
    }

    private func record(_ event: NotchSurfaceEvent, _ outcome: NotchSurfaceOutcome) {
        journal.append(NotchSurfaceJournalEntry(event: event, outcome: outcome))
        if journal.count > Self.journalLimit { journal.removeFirst(journal.count - Self.journalLimit) }
    }

    static func describe(_ state: NotchSurfaceState) -> String {
        switch state {
        case .closed: "closed"
        case .recording: "recording"
        case .teleprompter: "teleprompter"
        case let .history(detent): "history(\(detent.rawValue))"
        case let .settings(tab): "settings(\(tab.title.lowercased()))"
        }
    }

    static func describe(_ event: NotchSurfaceEvent) -> String {
        switch event {
        case .openHistory: "open history"
        case let .setHistoryDetent(detent): "history \(detent.rawValue)"
        case let .openSettings(tab): "open settings \(tab.title.lowercased())"
        case let .selectSettingsTab(tab): "tab \(tab.title.lowercased())"
        case let .dismiss(reason): "dismiss \(reason.rawValue)"
        case let .recordingChanged(on): "recording \(on ? "began" : "ended")"
        case let .teleprompterChanged(on): "teleprompter \(on ? "shown" : "gone")"
        case let .modalChanged(on): "modal \(on ? "began" : "ended")"
        }
    }
}

public struct NotchSurfaceJournalEntry: Equatable, Sendable {
    public let event: NotchSurfaceEvent
    public let outcome: NotchSurfaceOutcome
}

/// Reports whether any VoiceBar window has a sheet attached or a modal session is running, so the machine can
/// refuse (and close) drawers over it. Sheets on Settings (Add term, confirmations) and NSAlert modals both count.
@MainActor
public final class NotchModalObserver {
    private var observers: [NSObjectProtocol] = []
    private let isModalProvider: @MainActor () -> Bool
    private let onChange: (Bool) -> Void
    public private(set) var isModal = false

    public init(
        isModalProvider: @escaping @MainActor () -> Bool = { NotchModalObserver.anyVoiceBarWindowIsModal() },
        onChange: @escaping (Bool) -> Void
    ) {
        self.isModalProvider = isModalProvider
        self.onChange = onChange
    }

    public static func anyVoiceBarWindowIsModal() -> Bool {
        NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
    }

    public func start(center: NotificationCenter = .default) {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // didEndSheet fires before the sheet leaves `attachedSheet`; re-read on the next turn too.
                MainActor.assumeIsolated { self?.refresh() }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        }
        refresh()
    }

    public func stop(center: NotificationCenter = .default) {
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    public func refresh() {
        let modal = isModalProvider()
        guard modal != isModal else { return }
        isModal = modal
        onChange(modal)
    }
}
