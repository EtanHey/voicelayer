import Foundation

public enum ModelsStatusAvailability: Equatable, Sendable {
    case loading
    case available
    case unavailable
}

public enum VoiceModelResidency: String, Equatable, Sendable {
    case loaded
    case notLoaded = "not_loaded"
    case unknown
}

public struct ModelsSettingsState: Equatable, Sendable {
    public let availability: ModelsStatusAvailability
    public let configuredModelName: String?
    public let configuredModelSizeBytes: Int64?
    public let isInstalled: Bool?
    public let residency: VoiceModelResidency
    public let activeModelName: String?
    public let configuredEffort: VoiceBarPerformanceEffort?
    public let activeEffort: VoiceBarPerformanceEffort?
    public let isBusy: Bool
    public let busyReason: String?
    public let polishControls: PolishControlsState?

    private init(availability: ModelsStatusAvailability) {
        self.availability = availability
        configuredModelName = nil
        configuredModelSizeBytes = nil
        isInstalled = nil
        residency = .unknown
        activeModelName = nil
        configuredEffort = nil
        activeEffort = nil
        isBusy = true
        busyReason = nil
        polishControls = nil
    }

    public static let loading = ModelsSettingsState(availability: .loading)

    public init(healthEvent: [String: Any]) {
        guard healthEvent["type"] as? String == "health",
              let status = healthEvent["model_status"] as? [String: Any],
              let configured = status["configured_model"] as? [String: Any],
              let installed = configured["installed"] as? Bool,
              let residencyValue = status["residency"] as? String,
              let residency = VoiceModelResidency(rawValue: residencyValue),
              let effortValue = status["configured_effort"] as? String,
              let configuredEffort = VoiceBarPerformanceEffort(rawValue: effortValue)
        else {
            self = Self.unavailable
            return
        }
        availability = .available
        configuredModelName = Self.nonempty(status: configured["name"])
        configuredModelSizeBytes = (configured["size_bytes"] as? NSNumber)?.int64Value
        isInstalled = installed
        self.residency = residency
        activeModelName = Self.nonempty(status: status["active_model"])
        self.configuredEffort = configuredEffort
        activeEffort = (status["active_effort"] as? String).flatMap(VoiceBarPerformanceEffort.init)
        isBusy = healthEvent["recording_state"] as? String != "idle"
            || (healthEvent["queue_depth"] as? Int ?? 0) > 0
        busyReason = (healthEvent["recording_state"] as? String).flatMap(Self.busyReason(recordingState:))
            ?? ((healthEvent["queue_depth"] as? Int ?? 0) > 0 ? "Playing back" : nil)
        polishControls = PolishControlsState(healthEvent: healthEvent)
    }

    /// Spec §5 busy wording, shared by the health initializer and VoiceState's runtime overrides.
    static func busyReason(recordingState: String) -> String? {
        switch recordingState {
        case "recording": "Recording…"
        case "transcribing": "Transcribing…"
        default: nil
        }
    }

    static func busyReason(mode: VoiceMode) -> String? {
        switch mode {
        case .recording: busyReason(recordingState: "recording")
        case .transcribing: busyReason(recordingState: "transcribing")
        default: nil
        }
    }

    public static let unavailable = ModelsSettingsState(availability: .unavailable)

    func settingBusy(_ isBusy: Bool, reason: String? = nil) -> ModelsSettingsState {
        ModelsSettingsState(
            availability: availability,
            configuredModelName: configuredModelName,
            configuredModelSizeBytes: configuredModelSizeBytes,
            isInstalled: isInstalled,
            residency: residency,
            activeModelName: activeModelName,
            configuredEffort: configuredEffort,
            activeEffort: activeEffort,
            isBusy: isBusy,
            busyReason: isBusy ? reason : nil,
            polishControls: polishControls
        )
    }

    func replacingPolishControls(_ controls: PolishControlsState?) -> ModelsSettingsState {
        ModelsSettingsState(
            availability: availability,
            configuredModelName: configuredModelName,
            configuredModelSizeBytes: configuredModelSizeBytes,
            isInstalled: isInstalled,
            residency: residency,
            activeModelName: activeModelName,
            configuredEffort: configuredEffort,
            activeEffort: activeEffort,
            isBusy: isBusy,
            busyReason: busyReason,
            polishControls: controls
        )
    }

    func retainingPolishControls(from previous: ModelsSettingsState) -> ModelsSettingsState {
        ModelsSettingsState(
            availability: availability,
            configuredModelName: configuredModelName,
            configuredModelSizeBytes: configuredModelSizeBytes,
            isInstalled: isInstalled,
            residency: residency,
            activeModelName: activeModelName,
            configuredEffort: configuredEffort,
            activeEffort: activeEffort,
            isBusy: isBusy,
            busyReason: busyReason,
            polishControls: previous.polishControls
        )
    }

    private init(
        availability: ModelsStatusAvailability,
        configuredModelName: String?,
        configuredModelSizeBytes: Int64?,
        isInstalled: Bool?,
        residency: VoiceModelResidency,
        activeModelName: String?,
        configuredEffort: VoiceBarPerformanceEffort?,
        activeEffort: VoiceBarPerformanceEffort?,
        isBusy: Bool,
        busyReason: String?,
        polishControls: PolishControlsState?
    ) {
        self.availability = availability
        self.configuredModelName = configuredModelName
        self.configuredModelSizeBytes = configuredModelSizeBytes
        self.isInstalled = isInstalled
        self.residency = residency
        self.activeModelName = activeModelName
        self.configuredEffort = configuredEffort
        self.activeEffort = activeEffort
        self.isBusy = isBusy
        self.busyReason = busyReason
        self.polishControls = polishControls
    }

    private static func nonempty(status value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
