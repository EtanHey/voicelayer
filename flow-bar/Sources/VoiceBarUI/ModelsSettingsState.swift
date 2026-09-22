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
    }

    private static let unavailable = ModelsSettingsState(availability: .unavailable)

    private static func nonempty(status value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
