import Foundation
import Observation

/// F3: first-run setup for someone installing VoiceBar without docs. Setup used to be scattered across Settings
/// (Permissions, the F5 key helper, Microphone priority); the wizard walks those same controls in order and ends
/// with a test dictation. It reuses the app's existing actions and never blocks the app: every step can be skipped.
public enum SetupWizardStep: String, CaseIterable, Sendable {
    case welcome
    case permissions
    case f5Key
    case microphone
    case tryIt
    case done

    /// The four steps that set something up; Welcome and Done frame them.
    public static let setupSteps: [SetupWizardStep] = [.permissions, .f5Key, .microphone, .tryIt]

    public var isSetupStep: Bool {
        Self.setupSteps.contains(self)
    }

    public var progressLabel: String? {
        guard let index = Self.setupSteps.firstIndex(of: self) else { return nil }
        return "Step \(index + 1) of \(Self.setupSteps.count)"
    }

    public var title: String {
        switch self {
        case .welcome: "Welcome to VoiceBar"
        case .permissions: "Allow access"
        case .f5Key: "Set up the F5 key"
        case .microphone: "Choose your microphone"
        case .tryIt: "Try it"
        case .done: "You're all set"
        }
    }

    public var primaryTitle: String {
        switch self {
        case .welcome: "Get started"
        case .permissions, .f5Key, .microphone, .tryIt: "Continue"
        case .done: "Start using VoiceBar"
        }
    }

    var next: SetupWizardStep? {
        guard let index = Self.allCases.firstIndex(of: self), index + 1 < Self.allCases.count else { return nil }
        return Self.allCases[index + 1]
    }

    var previous: SetupWizardStep? {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return nil }
        return Self.allCases[index - 1]
    }
}

public struct SetupWizardModel: Equatable, Sendable {
    public private(set) var step: SetupWizardStep
    /// Steps passed with "Skip this step", in step order; Done points back to them.
    public private(set) var skippedSteps: [SetupWizardStep] = []

    public init(step: SetupWizardStep = .welcome) {
        self.step = step
    }

    /// Done has no Back: setup is over, and Settings is where anything is changed afterwards.
    public var canGoBack: Bool {
        step != .done && step.previous != nil
    }

    public var canSkipStep: Bool {
        step.isSetupStep
    }

    public mutating func continueToNextStep() {
        skippedSteps.removeAll { $0 == step }
        if let next = step.next { step = next }
    }

    public mutating func goBack() {
        guard canGoBack, let previous = step.previous else { return }
        step = previous
    }

    public mutating func skipStep() {
        guard canSkipStep, let next = step.next else { return }
        if !skippedSteps.contains(step) {
            skippedSteps.append(step)
            skippedSteps.sort { Self.order($0) < Self.order($1) }
        }
        step = next
    }

    private static func order(_ step: SetupWizardStep) -> Int {
        SetupWizardStep.allCases.firstIndex(of: step) ?? 0
    }
}

/// The persisted `setupCompleted` flag, plus the step to resume at when VoiceBar quits mid-setup (granting Input
/// Monitoring can require a relaunch).
public final class SetupWizardCompletionStore {
    public static let completedKey = "setupCompleted"
    public static let resumeStepKey = "setupResumeStep"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var isCompleted: Bool {
        defaults.bool(forKey: Self.completedKey)
    }

    public var resumeStep: SetupWizardStep? {
        defaults.string(forKey: Self.resumeStepKey).flatMap(SetupWizardStep.init(rawValue:))
    }

    public func markCompleted() {
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.resumeStepKey)
    }

    func saveResumeStep(_ step: SetupWizardStep) {
        defaults.set(step.rawValue, forKey: Self.resumeStepKey)
    }
}

/// Drives one wizard window: moves the model, keeps the resume step while first-run setup is unfinished, and marks
/// setup completed on Finish, Skip setup, or the window closing.
@Observable
public final class SetupWizardController {
    public private(set) var model: SetupWizardModel
    @ObservationIgnored private let store: SetupWizardCompletionStore
    @ObservationIgnored private let onClose: () -> Void
    /// A re-run from Settings or the menu is not first-run setup: it starts at Welcome and never saves a resume step.
    @ObservationIgnored private let isFirstRun: Bool
    @ObservationIgnored private var isClosed = false

    public init(
        store: SetupWizardCompletionStore,
        model: SetupWizardModel? = nil,
        onClose: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onClose = onClose
        isFirstRun = !store.isCompleted
        let resume = isFirstRun ? store.resumeStep.flatMap { $0 == .done ? nil : $0 } : nil
        self.model = model ?? SetupWizardModel(step: resume ?? .welcome)
    }

    public func continueToNextStep() {
        guard !isClosed else { return }
        if model.step == .done {
            finish()
            return
        }
        model.continueToNextStep()
        saveProgress()
    }

    public func goBack() {
        guard !isClosed else { return }
        model.goBack()
        saveProgress()
    }

    public func skipStep() {
        guard !isClosed else { return }
        model.skipStep()
        saveProgress()
    }

    public func skipSetup() {
        finish()
    }

    /// The window's close button: counts as Skip setup, but the window is already closing.
    public func windowDidClose() {
        guard !isClosed else { return }
        isClosed = true
        store.markCompleted()
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        store.markCompleted()
        onClose()
    }

    private func saveProgress() {
        guard isFirstRun else { return }
        store.saveResumeStep(model.step)
    }
}

/// Which buttons frame a step. Welcome: Get started + Skip setup. Setup steps: Back, Skip this step, Continue, and
/// Skip setup. Done: its one button.
public struct SetupWizardFooter: Equatable {
    public let primaryTitle: String
    public let showsSkipSetup: Bool
    public let showsBack: Bool
    public let showsSkipStep: Bool
    /// Filled progress segments out of `SetupWizardStep.setupSteps.count`.
    public let completedSegments: Int

    public init(model: SetupWizardModel) {
        let step = model.step
        primaryTitle = step.primaryTitle
        showsSkipSetup = step != .done
        showsBack = model.canGoBack
        showsSkipStep = model.canSkipStep
        if step == .done {
            completedSegments = SetupWizardStep.setupSteps.count
        } else {
            completedSegments = SetupWizardStep.setupSteps.firstIndex(of: step).map { $0 + 1 } ?? 0
        }
    }
}

/// Done's summary: a skipped step is named, with where to finish it, so nothing fails silently.
public struct SetupWizardDoneSummary: Equatable {
    public let skippedNames: [String]

    public init(skippedSteps: [SetupWizardStep]) {
        skippedNames = skippedSteps.compactMap(\.shortName)
    }

    public var isComplete: Bool {
        skippedNames.isEmpty
    }

    public var unfinishedLine: String? {
        guard !isComplete else { return nil }
        return "Skipped: \(skippedNames.joined(separator: ", ")). "
            + "Finish them in Settings › General, or run setup again from the menu."
    }
}

extension SetupWizardStep {
    var shortName: String? {
        switch self {
        case .permissions: "Permissions"
        case .f5Key: "F5 key"
        case .microphone: "Microphone"
        case .tryIt: "Try it"
        case .welcome, .done: nil
        }
    }
}
