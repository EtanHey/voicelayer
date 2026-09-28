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
    /// VoiceState's error message while its mode is `.error` (an empty final is "Transcription failed").
    public let failure: String?

    public init(
        entry: RecentTranscriptionEntry?,
        insertion: DictationInsertionStatus,
        activity: SetupTryItActivity,
        failure: String? = nil
    ) {
        self.entry = entry
        self.insertion = insertion
        self.activity = activity
        self.failure = failure
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

/// What Try it remembers between polls (#210 r1): the last dictation when the step first showed, and a failed
/// attempt. VoiceState reports an empty final as mode `.error` ("Transcription failed") with no new entry, and the
/// error clears to idle a moment later, so a failure is held until the next attempt starts or a new dictation lands.
public struct SetupTryItTracker: Equatable {
    public let baseline: RecentTranscriptionEntry?
    public private(set) var failure: String?
    private var entryAtFailure: RecentTranscriptionEntry?
    /// An error already showing when the step opened belongs to an earlier attempt.
    private var staleFailure: String?

    public init(first: SetupTryItObservation) {
        baseline = first.entry
        staleFailure = first.activity == .idle ? first.failure : nil
    }

    public mutating func observe(_ observation: SetupTryItObservation) {
        if observation.activity != .idle {
            failure = nil
            staleFailure = nil
            return
        }
        if let reported = observation.failure {
            guard reported != staleFailure, failure == nil else { return }
            failure = reported
            entryAtFailure = observation.entry
            return
        }
        staleFailure = nil
        if failure != nil, observation.entry != entryAtFailure {
            failure = nil
        }
    }
}

public struct SetupTryItStep: Equatable {
    public enum Phase: Equatable {
        case waiting
        case failed
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
    private var failure: String?

    /// `baseline` is the last dictation when the step opened; only a different one counts.
    public init(baseline: RecentTranscriptionEntry?, observation: SetupTryItObservation, readiness: SetupReadiness) {
        newEntry = observation.entry.flatMap { $0 == baseline ? nil : $0 }
        self.observation = observation
        self.readiness = readiness
    }

    public init(tracker: SetupTryItTracker, observation: SetupTryItObservation, readiness: SetupReadiness) {
        self.init(baseline: tracker.baseline, observation: observation, readiness: readiness)
        failure = tracker.failure
    }

    /// VoiceState's message for an empty final transcript (`failTranscription`).
    static let emptyTranscriptFailure = "Transcription failed"

    public var phase: Phase {
        switch observation.activity {
        case .recording: .listening
        case .transcribing: .transcribing
        case .idle: failure != nil ? .failed : newEntry == nil ? .waiting : .heard
        }
    }

    public var phaseLine: String? {
        switch phase {
        case .listening: "Listening… let go of F5 when you're done."
        case .transcribing: "Transcribing…"
        case .waiting, .heard, .failed: nil
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
        case .failed:
            // Also a paste-handler failure, an AX timeout or a competing insertion with the target focused (#210 r1).
            return "VoiceBar heard you but couldn't type it. Put the cursor in a text box in another app and try "
                + "again; if it keeps failing, check Accessibility in Allow access."
        case .notInserted:
            // VoiceBar didn't try to type this dictation; say what to do, not why.
            return "It wasn't typed anywhere. Click into Notes or TextEdit, hold F5, and try again."
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
        if phase == .failed, let failure {
            let text = failure == Self.emptyTranscriptFailure
                ? "VoiceBar heard nothing. Check your microphone."
                : "That try didn't work (\(failure)). Check your microphone."
            return [SetupTryItProblem(step: .microphone, text: text)]
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
