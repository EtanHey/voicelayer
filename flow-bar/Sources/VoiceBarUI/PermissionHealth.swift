import Foundation

/// One non-prompting read of the three permissions VoiceBar needs (2.3 permission health). The app target does the
/// reading (`AppDelegate.readPermissionHealth()`, status-only APIs that cannot show a TCC dialog); this presentation
/// module only holds the result.
public struct PermissionHealthReading: Equatable, Sendable {
    public let microphone: SetupMicrophoneAuthorization
    public let accessibilityGranted: Bool
    public let inputMonitoringGranted: Bool

    public init(microphone: SetupMicrophoneAuthorization, accessibilityGranted: Bool, inputMonitoringGranted: Bool) {
        self.microphone = microphone
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
    }

    public static let allGranted = Self(microphone: .granted, accessibilityGranted: true, inputMonitoringGranted: true)

    /// What the F5 listener needs, in the listener's own order (Input Monitoring, then Accessibility).
    public var missingHotkeyPermissions: [HotkeyPermission] {
        var missing: [HotkeyPermission] = []
        if !inputMonitoringGranted { missing.append(.inputMonitoring) }
        if !accessibilityGranted { missing.append(.accessibility) }
        return missing
    }

    /// Everything the notch's orange dot reports, in Setup's order so the dot and `firstBroken` agree.
    public var missingPermissions: [HotkeyPermission] {
        var missing: [HotkeyPermission] = []
        if microphone != .granted { missing.append(.microphone) }
        if !accessibilityGranted { missing.append(.accessibility) }
        if !inputMonitoringGranted { missing.append(.inputMonitoring) }
        return missing
    }

    public func snapshot(hotkeyListenerActive: Bool) -> SetupPermissionSnapshot {
        SetupPermissionSnapshot(microphone: microphone, accessibilityGranted: accessibilityGranted,
                                inputMonitoringGranted: inputMonitoringGranted,
                                hotkeyListenerActive: hotkeyListenerActive)
    }
}

/// Why a re-check ran. Logged, and lets a test say which seam caught a reset.
public enum PermissionHealthTrigger: String, Sendable {
    case launch, appActivated, settingsOpened, menuBarOpened, notchHovered, captureEnded, listenerChanged, poll
}

/// A repeating tick the monitor can cancel. `Timer` in the app; a fake in tests, so a disposed monitor can be ticked.
public protocol PermissionHealthTicker: AnyObject {
    func invalidate()
}

extension Timer: PermissionHealthTicker {}

/// Re-reads permission state while VoiceBar runs, so a permission revoked in System Settings (or reset by `tccutil`
/// or a reinstall) surfaces without a relaunch. Publishes only when the reading changes, so a cheap poll costs
/// nothing downstream. Status reads only: it never requests a permission and never touches the F5 listener.
///
/// Main thread only. Not `@MainActor`: its owner (AppDelegate) is not actor-isolated in this Swift 5 package, so
/// every entry asserts the main queue instead.
public final class PermissionHealthMonitor {
    public typealias Read = () -> PermissionHealthReading
    /// Schedules `tick` every `interval` seconds and returns the handle that stops it.
    public typealias Schedule = (_ interval: TimeInterval, _ tick: @escaping () -> Void) -> PermissionHealthTicker

    /// Cheap: three local status reads every few seconds, and nothing published unless something changed.
    public static let pollInterval: TimeInterval = 5

    public static let timerSchedule: Schedule = { interval, tick in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in tick() }
        timer.tolerance = interval / 2
        return timer
    }

    private let read: Read
    private let schedule: Schedule
    public private(set) var reading: PermissionHealthReading?
    public var onChange: ((PermissionHealthReading, PermissionHealthTrigger) -> Void)?
    /// Always called after a read, including unchanged permissions, for live listener health.
    public var onRefresh: (() -> Void)?
    private var ticker: PermissionHealthTicker?
    public var isPolling: Bool { ticker != nil }

    public init(read: @escaping Read, schedule: @escaping Schedule = PermissionHealthMonitor.timerSchedule) {
        self.read = read
        self.schedule = schedule
    }

    /// The run loop retains a repeating Timer, so an owner going away must not leave it firing.
    deinit {
        ticker?.invalidate()
    }

    /// Reads now. Returns whether the reading changed (and was published). `force` republishes an unchanged reading,
    /// for a caller that just overwrote the same state from another source.
    @discardableResult
    public func refresh(_ trigger: PermissionHealthTrigger, force: Bool = false) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let next = read()
        let changed = next != reading
        reading = next
        onRefresh?()
        guard changed || force else { return false }
        onChange?(next, trigger)
        return changed
    }

    public func startPolling(interval: TimeInterval = PermissionHealthMonitor.pollInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        ticker?.invalidate()
        ticker = schedule(interval) { [weak self] in
            // A tick that outlives stopPolling (or the monitor) reads nothing.
            guard let self, self.ticker != nil else { return }
            self.refresh(.poll)
        }
    }

    /// Stops the poll and drops the callback; no reads or publishes after this until `startPolling` again.
    public func stopPolling() {
        dispatchPrecondition(condition: .onQueue(.main))
        ticker?.invalidate()
        ticker = nil
        onChange = nil
        onRefresh = nil
    }
}
