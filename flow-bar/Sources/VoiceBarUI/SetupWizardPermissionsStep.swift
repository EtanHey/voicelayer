import Foundation

/// F3 step 1. Microphone has a third state the other two don't: until VoiceBar asks, macOS doesn't list it in the
/// Microphone pane at all, so "Open" would land on a list without VoiceBar in it.
public enum SetupMicrophoneAuthorization: Equatable, Sendable {
    case granted
    case notRequested
    case denied
}

/// What the app reads back each tick: the same preflight checks Settings shows, plus whether the F5 listener is
/// running (it starts at launch, so permissions granted later need a restart).
public struct SetupPermissionSnapshot: Equatable, Sendable {
    public let microphone: SetupMicrophoneAuthorization
    public let accessibilityGranted: Bool
    public let inputMonitoringGranted: Bool
    public let hotkeyListenerActive: Bool

    public init(
        microphone: SetupMicrophoneAuthorization,
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        hotkeyListenerActive: Bool
    ) {
        self.microphone = microphone
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.hotkeyListenerActive = hotkeyListenerActive
    }

    public static let allGranted = Self(
        microphone: .granted, accessibilityGranted: true, inputMonitoringGranted: true, hotkeyListenerActive: true
    )

    /// Before the app has answered: nothing is claimed granted.
    public static let unknown = Self(
        microphone: .notRequested, accessibilityGranted: false, inputMonitoringGranted: false,
        hotkeyListenerActive: false
    )
}

public enum SetupPermissionAction: Equatable, Sendable {
    /// The permission's System Settings pane — the same URL as Settings › General › Permissions › Open.
    case openSettings(url: String)
    /// The macOS microphone prompt, for an app that has never asked.
    case requestMicrophone

    public var title: String {
        switch self {
        case .openSettings: "Open"
        case .requestMicrophone: "Allow…"
        }
    }
}

public struct SetupPermissionRow: Equatable {
    public let permission: HotkeyPermission
    public let label: String
    public let status: String
    public let isGranted: Bool
    public let action: SetupPermissionAction?
}

public struct SetupPermissionsStep: Equatable {
    public let rows: [SetupPermissionRow]
    private let snapshot: SetupPermissionSnapshot

    public init(snapshot: SetupPermissionSnapshot) {
        self.snapshot = snapshot
        let microphone: SetupPermissionRow = switch snapshot.microphone {
        case .granted: Self.row(.microphone, granted: true)
        case .denied: Self.row(.microphone, granted: false)
        case .notRequested: SetupPermissionRow(
                permission: .microphone,
                label: HotkeyPermission.microphone.label,
                status: "Not requested",
                isGranted: false,
                action: .requestMicrophone
            )
        }
        rows = [
            microphone,
            Self.row(.accessibility, granted: snapshot.accessibilityGranted),
            Self.row(.inputMonitoring, granted: snapshot.inputMonitoringGranted),
        ]
    }

    public var allGranted: Bool {
        rows.allSatisfy(\.isGranted)
    }

    public var restartNote: String? {
        guard snapshot.accessibilityGranted, snapshot.inputMonitoringGranted, !snapshot.hotkeyListenerActive else {
            return nil
        }
        return "Restart VoiceBar to turn on F5: quit it from the menu bar, then open it again. Setup picks up where you left off."
    }

    private static func row(_ permission: HotkeyPermission, granted: Bool) -> SetupPermissionRow {
        SetupPermissionRow(
            permission: permission,
            label: permission.label,
            status: granted ? "Granted" : "Missing",
            isGranted: granted,
            action: granted ? nil : .openSettings(url: permission.settingsURLString)
        )
    }
}
