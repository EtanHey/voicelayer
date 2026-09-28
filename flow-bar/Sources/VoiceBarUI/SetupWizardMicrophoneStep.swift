import Foundation

/// F3 step 3. The same read-only default every other surface shows (Etan's D2): the microphone-priority list's next
/// device, with "Change…" to Settings › General › Microphone priority, the one place it is chosen.
public struct SetupMicrophoneStep: Equatable {
    private let name: String?

    public init(defaultName: String?) {
        let trimmed = defaultName?.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed?.isEmpty == false ? trimmed : nil
    }

    public var defaultTitle: String {
        MicrophoneDefaultPresentation.title(name)
    }

    public var accessibilityLabel: String {
        MicrophoneDefaultPresentation.accessibilityLabel(name)
    }

    public var changeTitle: String {
        MicrophoneDefaultPresentation.changeTitle
    }

    public var changeAccessibilityLabel: String {
        MicrophoneDefaultPresentation.changeAccessibilityLabel
    }

    public var isReady: Bool {
        name != nil
    }

    public var problem: String? {
        isReady ? nil : "No microphone found. Connect one, then pick it with Change…"
    }
}
