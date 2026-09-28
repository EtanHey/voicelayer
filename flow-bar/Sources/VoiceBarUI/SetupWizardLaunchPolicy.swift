import Foundation

/// What the app knows at launch, once the F5 listener has started and the helper probe has answered.
public struct SetupLaunchReadiness: Equatable, Sendable {
    public let permissionsGranted: Bool
    public let listenerActive: Bool
    public let helperInstalled: Bool

    public init(permissionsGranted: Bool, listenerActive: Bool, helperInstalled: Bool) {
        self.permissionsGranted = permissionsGranted
        self.listenerActive = listenerActive
        self.helperInstalled = helperInstalled
    }

    var isReady: Bool {
        permissionsGranted && listenerActive && helperInstalled
    }
}

public enum SetupWizardLaunchDecision: Equatable, Sendable {
    case show
    case markCompleted
    case none
}

/// F3: the wizard opens by itself only for first-run setup. An unfinished first run resumes; a fresh install with
/// anything to set up shows it; an install that already works (an upgrade on a Mac that was set up by hand) is
/// marked completed without showing, so it never appears there.
public enum SetupWizardLaunchPolicy {
    public static func decide(
        isCompleted: Bool,
        hasResumeStep: Bool,
        readiness: SetupLaunchReadiness
    ) -> SetupWizardLaunchDecision {
        if isCompleted { return .none }
        if hasResumeStep { return .show }
        return readiness.isReady ? .markCompleted : .show
    }
}
