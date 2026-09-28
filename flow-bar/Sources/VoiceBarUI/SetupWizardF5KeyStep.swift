import Foundation

public struct SetupF5KeyStatus: Equatable, Sendable {
    public let listenerActive: Bool
    public let helperInstalled: Bool
    public init(listenerActive: Bool, helperInstalled: Bool) {
        self.listenerActive = listenerActive
        self.helperInstalled = helperInstalled
    }

    public static let unknown = Self(listenerActive: false, helperInstalled: false)
}

public struct SetupRelayRun: Equatable, Sendable {
    public let action: SettingsRelaySetupFeedback.Action
    public let result: SettingsRelaySetupResult?
    public init(action: SettingsRelaySetupFeedback.Action, result: SettingsRelaySetupResult?) {
        self.action = action
        self.result = result
    }
}

public struct SetupF5KeyResultLine: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case running, success, failure }
    public let text: String
    public let tone: Tone
}

/// F3 step 2. Two things make F5 work: the listener (an event tap that needs Accessibility and Input Monitoring and
/// starts at launch) and the F5 key helper that Settings › Advanced sets up. The helper's Set up / Reinstall and its
/// result line are Settings' own (#193); the wizard only shows them.
public struct SetupF5KeyStep: Equatable {
    private let status: SetupF5KeyStatus
    private let run: SetupRelayRun?

    public init(status: SetupF5KeyStatus, run: SetupRelayRun? = nil) {
        self.status = status
        self.run = run
    }

    public var isReady: Bool {
        status.listenerActive && status.helperInstalled
    }

    public var listenerStatus: String {
        status.listenerActive ? "On" : "Off"
    }

    public var listenerProblem: String? {
        status.listenerActive ? nil : "F5 needs Accessibility and Input Monitoring, then a restart of VoiceBar."
    }

    /// Where an off listener is fixed.
    public var listenerFixStep: SetupWizardStep? {
        status.listenerActive ? nil : .permissions
    }

    public var helperStatus: String {
        status.helperInstalled ? "Installed" : "Not installed"
    }

    /// The same choice as Settings: Reinstall once the helper is installed, Set up before.
    public var helperAction: SettingsRelaySetupFeedback.Action {
        status.helperInstalled ? .reinstall : .setUp
    }

    public var helperButtonTitle: String {
        helperAction == .reinstall ? "Reinstall" : "Set up"
    }

    public var helperButtonEnabled: Bool {
        run == nil || run?.result != nil
    }

    public var resultLine: SetupF5KeyResultLine? {
        guard let run else { return nil }
        guard let result = run.result else {
            return SetupF5KeyResultLine(text: SettingsRelaySetupFeedback.running(run.action), tone: .running)
        }
        return SetupF5KeyResultLine(
            text: SettingsRelaySetupFeedback.line(for: result, action: run.action),
            tone: result.succeeded ? .success : .failure
        )
    }
}
