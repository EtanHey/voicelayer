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

    /// A resumed run: only setup steps that come before `step` can have been skipped.
    init(step: SetupWizardStep, skippedSteps: [SetupWizardStep]) {
        self.step = step
        var kept: [SetupWizardStep] = []
        for skipped in skippedSteps
            where skipped.isSetupStep && Self.order(skipped) < Self.order(step) && !kept.contains(skipped) {
            kept.append(skipped)
        }
        self.skippedSteps = kept.sorted { Self.order($0) < Self.order($1) }
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

    /// A step that points at an earlier one ("fix this in Allow access") jumps there; never forward, never from Done.
    public mutating func goBack(to target: SetupWizardStep) {
        guard step != .done, Self.order(target) < Self.order(step) else { return }
        step = target
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

/// The persisted `setupCompleted` flag, plus where to resume when VoiceBar quits mid-setup (granting Input Monitoring
/// can require a relaunch): the step, and the steps skipped so far so Done still names them.
public final class SetupWizardCompletionStore {
    public static let completedKey = "setupCompleted"
    public static let resumeStepKey = "setupResumeStep"
    public static let resumeSkippedStepsKey = "setupResumeSkippedSteps"

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

    /// Unreadable entries are dropped.
    public var resumeSkippedSteps: [SetupWizardStep] {
        (defaults.stringArray(forKey: Self.resumeSkippedStepsKey) ?? []).compactMap(SetupWizardStep.init(rawValue:))
    }

    public func markCompleted() {
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.resumeStepKey)
        defaults.removeObject(forKey: Self.resumeSkippedStepsKey)
    }

    func saveResume(_ model: SetupWizardModel) {
        defaults.set(model.step.rawValue, forKey: Self.resumeStepKey)
        defaults.set(model.skippedSteps.map(\.rawValue), forKey: Self.resumeSkippedStepsKey)
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

    public convenience init(
        store: SetupWizardCompletionStore,
        model: SetupWizardModel? = nil,
        onClose: @escaping () -> Void = {}
    ) {
        self.init(store: store, model: model, relayRun: nil, onClose: onClose)
    }

    /// Tests and artifacts start with a helper run already pending or finished.
    init(
        store: SetupWizardCompletionStore,
        model: SetupWizardModel?,
        relayRun: SetupRelayRun?,
        onClose: @escaping () -> Void = {}
    ) {
        self.relayRun = relayRun
        self.store = store
        self.onClose = onClose
        isFirstRun = !store.isCompleted
        // Done is resumed too: reaching it is not finishing, and only Finish (or skipping/closing) completes setup.
        let resumed = isFirstRun ? store.resumeStep.map {
            SetupWizardModel(step: $0, skippedSteps: store.resumeSkippedSteps)
        } : nil
        self.model = model ?? resumed ?? SetupWizardModel()
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

    /// The F5 key helper's last Set up / Reinstall (#208 r1): held here, not in the step's view, so leaving the F5
    /// step mid-run keeps its spinner, and a result that lands while another step shows is there on return. In
    /// memory only; the installer and its in-flight guard are the app's.
    public private(set) var relayRun: SetupRelayRun?

    public func startRelaySetup(
        _ action: SettingsRelaySetupFeedback.Action,
        using run: (@escaping (SettingsRelaySetupResult) -> Void) -> Void
    ) {
        guard !isClosed, relayRun == nil || relayRun?.result != nil else { return }
        relayRun = SetupRelayRun(action: action, result: nil)
        run { [weak self] result in
            self?.relayRun = SetupRelayRun(action: action, result: result)
        }
    }

    public func goBack(to step: SetupWizardStep) {
        guard !isClosed else { return }
        model.goBack(to: step)
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
        store.saveResume(model)
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
