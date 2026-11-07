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
    case launch, appActivated, settingsOpened, notchHovered, captureEnded, listenerChanged, poll
}

/// Re-reads permission state while VoiceBar runs, so a permission revoked in System Settings (or reset by `tccutil`
/// or a reinstall) surfaces without a relaunch. Publishes only when the reading changes, so a cheap poll costs
/// nothing downstream. Status reads only: it never requests a permission and never touches the F5 listener.
/// Main thread only, like the AppDelegate that owns it.
public final class PermissionHealthMonitor {
    public typealias Read = () -> PermissionHealthReading

    /// Cheap: three local status reads every few seconds, and nothing published unless something changed.
    public static let pollInterval: TimeInterval = 5

    private let read: Read
    public private(set) var reading: PermissionHealthReading?
    public var onChange: ((PermissionHealthReading, PermissionHealthTrigger) -> Void)?
    private var timer: Timer?
    public var isPolling: Bool { timer != nil }

    public init(read: @escaping Read) {
        self.read = read
    }

    /// Reads now. Returns whether the reading changed (and was published). `force` republishes an unchanged reading,
    /// for a caller that just overwrote the same state from another source.
    @discardableResult
    public func refresh(_ trigger: PermissionHealthTrigger, force: Bool = false) -> Bool {
        let next = read()
        let changed = next != reading
        reading = next
        guard changed || force else { return false }
        onChange?(next, trigger)
        return changed
    }

    public func startPolling(interval: TimeInterval = PermissionHealthMonitor.pollInterval) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh(.poll)
        }
        timer.tolerance = interval / 2
        self.timer = timer
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
