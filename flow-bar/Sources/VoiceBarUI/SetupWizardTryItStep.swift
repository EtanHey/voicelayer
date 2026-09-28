import Foundation

/// F3 step 4: a real F5 dictation, watched through the same last-dictation state Settings' "Last dictation" card
/// shows. VoiceBar deliberately never types into its own windows (VoiceState drops a VoiceBar-frontmost paste
/// target), so the wizard shows what was heard in its own field and says where the text was typed; it changes
/// nothing about capture or paste.
public enum SetupTryItActivity: Equatable, Sendable {
    case idle
    case recording
    case transcribing
}

public struct SetupTryItObservation: Equatable {
    public let entry: RecentTranscriptionEntry?
    public let insertion: DictationInsertionStatus
    public let activity: SetupTryItActivity
    public init(entry: RecentTranscriptionEntry?, insertion: DictationInsertionStatus, activity: SetupTryItActivity) {
        self.entry = entry
        self.insertion = insertion
        self.activity = activity
    }

    public static let none = Self(entry: nil, insertion: .unverified, activity: .idle)
}

public struct SetupReadiness: Equatable {
    public let permissions: SetupPermissionSnapshot
    public let f5Key: SetupF5KeyStatus
    public let microphoneName: String?
    public init(permissions: SetupPermissionSnapshot, f5Key: SetupF5KeyStatus, microphoneName: String?) {
        self.permissions = permissions
        self.f5Key = f5Key
        self.microphoneName = microphoneName
    }
}

public struct SetupTryItProblem: Equatable {
    public let step: SetupWizardStep
    public let text: String

    public var fixTitle: String {
        "Go to \(step.fixName)"
    }
}

private extension SetupWizardStep {
    /// "Go to Allow access" reads better than "Go to Permissions" once the user has seen the step's title.
    var fixName: String {
        self == .permissions ? "Allow access" : shortName ?? title
    }
}

public struct SetupTryItStep: Equatable {
    public enum Phase: Equatable {
        case waiting
        case listening
        case transcribing
        case heard
    }

    public enum Tone: Equatable {
        case success
        case attention
        case neutral
    }

    private let newEntry: RecentTranscriptionEntry?
    private let observation: SetupTryItObservation
    private let readiness: SetupReadiness

    /// `baseline` is the last dictation when the step opened; only a different one counts.
    public init(baseline: RecentTranscriptionEntry?, observation: SetupTryItObservation, readiness: SetupReadiness) {
        newEntry = observation.entry.flatMap { $0 == baseline ? nil : $0 }
        self.observation = observation
        self.readiness = readiness
    }

    public var phase: Phase {
        switch observation.activity {
        case .recording: .listening
        case .transcribing: .transcribing
        case .idle: newEntry == nil ? .waiting : .heard
        }
    }

    public var phaseLine: String? {
        switch phase {
        case .listening: "Listening… let go of F5 when you're done."
        case .transcribing: "Transcribing…"
        case .waiting, .heard: nil
        }
    }

    public var heardText: String? {
        guard phase == .heard, let text = newEntry?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// Hearing a sentence proves permissions, F5, the microphone and transcription; typing it is the app's paste.
    public var succeeded: Bool {
        heardText != nil
    }

    public var insertionLine: String? {
        guard succeeded else { return nil }
        switch observation.insertion {
        case .insertedAtCursor, .pasted:
            return "Typed into the app you were in."
        case .failed, .notInserted:
            return "It wasn't typed anywhere: VoiceBar types into the app you were in, not into this window. "
                + "Click into Notes or TextEdit and try again."
        case .pending, .unverified:
            return nil
        }
    }

    public var insertionTone: Tone {
        switch observation.insertion {
        case .insertedAtCursor, .pasted: .success
        case .failed, .notInserted: .attention
        case .pending, .unverified: .neutral
        }
    }

    /// What is still unfinished, each with the step that fixes it.
    public var problems: [SetupTryItProblem] {
        if phase == .heard, heardText == nil {
            return [SetupTryItProblem(step: .microphone, text: "VoiceBar heard nothing. Check your microphone.")]
        }
        var problems: [SetupTryItProblem] = []
        if !SetupPermissionsStep(snapshot: readiness.permissions).allGranted {
            problems.append(SetupTryItProblem(step: .permissions, text: "Allow access isn't finished."))
        }
        if !readiness.f5Key.listenerActive {
            problems.append(SetupTryItProblem(step: .f5Key, text: "F5 isn't on yet."))
        }
        if !SetupMicrophoneStep(defaultName: readiness.microphoneName).isReady {
            problems.append(SetupTryItProblem(step: .microphone, text: "No microphone found."))
        }
        return problems
    }
}
