import Foundation

/// What the app knows at launch, once the F5 listener has started.
public struct SetupLaunchReadiness: Equatable, Sendable {
    public let permissionsGranted: Bool
    public let listenerActive: Bool

    public init(permissionsGranted: Bool, listenerActive: Bool) {
        self.permissionsGranted = permissionsGranted
        self.listenerActive = listenerActive
    }

    /// The F5 key helper is not part of this: F5 is listened for directly, so a Mac without the helper works
    /// (the same rule as Try it; #211 r1).
    var isReady: Bool {
        permissionsGranted && listenerActive
    }
}

public enum SetupWizardLaunchDecision: Equatable, Sendable {
    case show
    case markCompleted
    case none
}

/// F3: the wizard opens by itself only for a genuinely new install. An unfinished first run resumes. A Mac that
/// has dictated before is already set up — an upgrade must never pop the wizard there (#211 r1), even if a check
/// is red now (Settings shows the permission rows, and Run setup… is in the menu). A new install that already
/// works is marked completed without showing.
public enum SetupWizardLaunchPolicy {
    public static func decide(
        isCompleted: Bool,
        hasResumeStep: Bool,
        hasPriorUse: Bool,
        readiness: SetupLaunchReadiness
    ) -> SetupWizardLaunchDecision {
        if isCompleted { return .none }
        if hasResumeStep { return .show }
        if hasPriorUse { return .markCompleted }
        return readiness.isReady ? .markCompleted : .show
    }

    /// Decides and saves: `.markCompleted` persists `setupCompleted`, so the next launch never decides again.
    /// Returns whether to show the wizard.
    public static func resolve(
        store: SetupWizardCompletionStore,
        hasPriorUse: Bool,
        readiness: SetupLaunchReadiness
    ) -> Bool {
        switch decide(
            isCompleted: store.isCompleted,
            hasResumeStep: store.resumeStep != nil,
            hasPriorUse: hasPriorUse,
            readiness: readiness
        ) {
        case .show:
            return true
        case .markCompleted:
            store.markCompleted()
            return false
        case .none:
            return false
        }
    }
}

/// Has this Mac used VoiceBar before this version? The most reliable record is the recordings archive: the daemon
/// writes every recording there (dictations and asks, cancelled and timed out too) and never deletes them, and it
/// lives outside the app's defaults, so it survives a reinstall or a defaults reset. VoiceBar's own
/// recent-transcriptions list is the backstop for an archive that was moved or cleared.
public enum SetupPriorUse {
    public static func detect(
        archiveRoot: URL,
        recentTranscriptionCount: Int,
        fileManager: FileManager = .default
    ) -> Bool {
        if recentTranscriptionCount > 0 { return true }
        guard let days = try? fileManager.contentsOfDirectory(
            at: archiveRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return false }
        for day in days where isDirectory(day) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: day, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            // `.tmp-` is a recording still being written (the archive's own partial-write prefix).
            if entries.contains(where: { isDirectory($0) && !$0.lastPathComponent.hasPrefix(".tmp-") }) {
                return true
            }
        }
        return false
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
