import Foundation
import SwiftUI

/// Whether the cloned speaking voice is ready, for General › Setup's "Speaking voice" step.
///
/// AIDEV-NOTE: Settings does not receive the clone-engine state yet (U3b wires its view model into AppDelegate).
/// Until then `SettingsView.speakingVoiceStatus` defaults to nil and the step is left out rather than guessed.
public enum SettingsSetupVoiceStatus: Equatable, Sendable {
    case ready
    /// Loading the voice model: not ready yet, and nothing for you to fix.
    case starting
    /// It stopped unexpectedly and VoiceBar is starting it again: not ready, and nothing for you to fix.
    case restarting
    case engineDown

    /// One state per engine state: only running is ready, and only stopped or failed needs you.
    public init(cloneEngine state: CloneEngineSnapshot.State) {
        switch state {
        case .running: self = .ready
        case .starting: self = .starting
        case .restarting: self = .restarting
        case .stopped, .failed: self = .engineDown
        }
    }
}

/// The one fix a setup step offers.
public enum SettingsSetupFix: Equatable, Sendable {
    case permission(SetupPermissionAction)
    case checkF5
    case restartF5Listener
    case manageVoice
    case startVoiceEngine

    public var title: String {
        switch self {
        case let .permission(action):
            if case .requestMicrophone = action { return "Allow…" }
            return "Open System Settings"
        case .checkF5: return "Check"
        case .restartF5Listener: return "Restart F5 listener"
        case .manageVoice: return "Manage"
        case .startVoiceEngine: return "Start engine"
        }
    }
}

public enum SettingsSetupStepID: String, CaseIterable, Sendable {
    case microphone, accessibility, inputMonitoring, f5Key, speakingVoice
}

public struct SettingsSetupStep: Equatable, Sendable {
    public let id: SettingsSetupStepID
    public let title: String
    public let description: String
    public let isDone: Bool
    public let fix: SettingsSetupFix?
    /// On its way by itself (loading or recovering): not done, but not broken either.
    public var isPending = false

    public var isBroken: Bool { !isDone && !isPending }
    var markKind: SettingsSetupMark.Kind { isDone ? .done : isPending ? .pending : .attention }
}

/// General › Setup (R2: setup is folded into General). Everything fine is one quiet row; anything missing lists the
/// steps with the broken ones first, each with its single fix.
public struct SettingsGeneralSetup: Equatable, Sendable {
    public static let readyTitle = "VoiceBar is ready"
    public static let readyDescription = "Permissions are on, F5 works and your voice is set up."
    /// Without a clone-engine reading the ready line claims only what it knows.
    public static let readyDescriptionWithoutVoice = "Permissions are on and F5 works."

    /// Spec order; `steps` moves the broken ones to the top without reordering within each group.
    public let steps: [SettingsSetupStep]
    public let knowsVoice: Bool

    public init(
        permissions: [SetupPermissionRow],
        hotkeyListenerActive: Bool,
        f5CheckedAt: Date?,
        voice: SettingsSetupVoiceStatus?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        var ordered = permissions.compactMap { Self.step(for: $0) }
        let permissionsDone = permissions.allSatisfy(\.isGranted)
        ordered.append(SettingsSetupStep(
            id: .f5Key, title: "F5 key",
            description: Self.f5Description(listenerActive: hotkeyListenerActive, permissionsDone: permissionsDone,
                                            checkedAt: f5CheckedAt, now: now, calendar: calendar),
            isDone: hotkeyListenerActive,
            // Permissions granted after launch leave the listener off until it restarts; a missing permission is
            // fixed on its own row first.
            fix: hotkeyListenerActive ? .checkF5 : (permissionsDone ? .restartF5Listener : nil)
        ))
        if let voice { ordered.append(Self.voiceStep(voice)) }
        steps = ordered.filter(\.isBroken) + ordered.filter(\.isPending) + ordered.filter(\.isDone)
        knowsVoice = voice != nil
    }

    /// Every step done. A pending step keeps the list open (the voice isn't "set up" yet) without calling it broken.
    public var isReady: Bool { steps.allSatisfy(\.isDone) }
    public var header: String { steps.contains(where: \.isBroken) ? "Finish setup" : "Setup" }
    public var readyDescription: String { knowsVoice ? Self.readyDescription : Self.readyDescriptionWithoutVoice }
    /// The step the notch's orange dot points at: the first broken one. A pending step is never a target.
    public var firstBroken: SettingsSetupStepID? { steps.first(where: \.isBroken)?.id }

    static func voiceStep(_ voice: SettingsSetupVoiceStatus) -> SettingsSetupStep {
        let (description, isDone, isPending): (String, Bool, Bool) = switch voice {
        case .ready: ("Your cloned voice is ready for long replies.", true, false)
        case .starting: ("Your cloned voice is starting. Long replies use the fast voice until it's ready.", false, true)
        case .restarting: ("The cloned voice engine stopped unexpectedly, so VoiceBar is starting it again. "
            + "Long replies use the fast voice meanwhile.", false, true)
        case .engineDown: ("The cloned voice engine is not running. Long replies use the fast voice.", false, false)
        }
        return SettingsSetupStep(id: .speakingVoice, title: "Speaking voice", description: description, isDone: isDone,
                                 fix: voice == .engineDown ? .startVoiceEngine : .manageVoice, isPending: isPending)
    }

    static func step(for row: SetupPermissionRow) -> SettingsSetupStep? {
        let fix = row.action.map(SettingsSetupFix.permission)
        switch row.permission {
        case .microphone:
            return SettingsSetupStep(
                id: .microphone, title: "Microphone access",
                description: row.isGranted ? "VoiceBar can hear your microphones."
                    : "Off. VoiceBar needs this to hear you.",
                isDone: row.isGranted, fix: fix)
        case .accessibility:
            return SettingsSetupStep(
                id: .accessibility, title: "Accessibility",
                description: row.isGranted ? "Lets VoiceBar paste what you say into other apps."
                    : "Off. VoiceBar needs this to paste what you say into other apps.",
                isDone: row.isGranted, fix: fix)
        case .inputMonitoring:
            return SettingsSetupStep(
                id: .inputMonitoring, title: "Input Monitoring",
                description: row.isGranted ? "Lets F5 and the mouse side button start dictation."
                    : "Off. VoiceBar needs this to hear F5 and the mouse side button.",
                isDone: row.isGranted, fix: fix)
        }
    }

    static func f5Description(listenerActive: Bool, permissionsDone: Bool, checkedAt: Date?,
                              now: Date, calendar: Calendar) -> String {
        guard listenerActive else {
            return permissionsDone ? "Off. Restart the F5 listener to pick up the new permissions."
                : "Off. Turn on the permissions above first."
        }
        guard let checkedAt else { return "Works." }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let day = calendar.isDate(checkedAt, inSameDayAs: now) ? "today" : (VoiceBarRelativeTime.label(
            checkedAt, now: now, calendar: calendar) ?? "earlier").lowercased()
        return "Works. Last checked \(day) at \(formatter.string(from: checkedAt))."
    }
}

/// Arriving from the notch's orange dot (or any request focused on Setup) briefly highlights the broken row: a
/// 1.6 s amber fade, none under Reduce Motion (focus still moves to the row's fix).
public struct SettingsArrivalHighlight: Equatable, Sendable {
    public static let duration: TimeInterval = 1.6
    public static let color = Color(red: 1.0, green: 0.72, blue: 0.2)

    public private(set) var step: SettingsSetupStepID?

    public init(step: SettingsSetupStepID? = nil) { self.step = step }

    /// Starts the highlight on `step`; Reduce Motion leaves it off.
    public mutating func arrive(at step: SettingsSetupStepID?, reduceMotion: Bool) {
        self.step = reduceMotion ? nil : step
    }

    /// Ends it, unless a newer arrival replaced it meanwhile.
    public mutating func expire(_ step: SettingsSetupStepID) {
        if self.step == step { self.step = nil }
    }
}

/// A switch the app owns but Settings only shows (Open at login, Mouse side buttons).
///
/// AIDEV-NOTE: neither fact reaches Settings yet. A nil input leaves the row informational (no switch), because a
/// switch that changes nothing is worse than none.
public struct SettingsToggleInput {
    public let isOn: () -> Bool
    public let set: (Bool) -> Void

    public init(isOn: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        self.isOn = isOn
        self.set = set
    }
}

/// General › Microphone priority row facts.
enum SettingsMicrophoneRowPresentation {
    /// The "Used for dictation" pill goes on the microphone the next dictation really uses, matched by identity
    /// (UID, then device ID), and by name only when the snapshot knows no identity.
    static func isUsedForDictation(_ row: MicrophonePriorityRow, snapshot: MicrophonePrioritySnapshot) -> Bool {
        guard row.isConnected else { return false }
        if let uid = snapshot.nextDeviceUID { return row.uid == uid }
        if let id = snapshot.nextDeviceID { return row.deviceID == id }
        return snapshot.nextDeviceName != nil && snapshot.nextDeviceName == row.label
    }

    /// Make default is offered on any connected, prioritizable mic below the top, whether or not it is the one in use.
    static func offersMakeDefault(_ row: MicrophonePriorityRow, at index: Int) -> Bool {
        row.canPrioritize && row.isConnected && index > 0
    }

    static func status(_ row: MicrophonePriorityRow) -> String {
        guard row.canPrioritize else { return (row.isConnected ? "Connected" : "Not connected") + " · UID unavailable" }
        return row.isConnected ? "Connected" : "Not connected"
    }
}

/// General's fixed row copy, shared by the pane and its V12 row-clipping guard.
enum SettingsGeneralCopy {
    static let dictationKeyTitle = "Dictation key"
    static let dictationKeyDescription =
        "Hold to talk. Double-tap to keep recording hands-free; it stops after 10 minutes of silence."
    static let mouseTitle = "Mouse side buttons"
    static let mouseDescription = "Forward acts like F5. Back sends Return."
    static let openAtLoginTitle = "Open at login"
    static let hideTitle = "Hide the notch"
    static let hideDescription = "VoiceBar keeps working. Click its Dock icon to bring the notch back."
    static let relayTitle = "F5 key helper"
    static let setupAssistantTitle = "Setup assistant"
    static let setupAssistantDescription = "Walks through permissions, the F5 key, your microphone and a test dictation."
    static let microphoneNote =
        "Drag to reorder. VoiceBar uses the first connected microphone. Disconnected ones keep their place."

    static func relayDescription(installed: Bool, listenerActive: Bool) -> String {
        let state = installed ? "Installed." : listenerActive ? "Not installed." : "Needs setup."
        return "Lets F5 start dictation even when macOS maps it to the dictation key. \(state)"
    }
}
