import Foundation

public enum V5IslandFeatureFlag {
    public static let defaultsKey = "voicebar.v5IslandEnabled"
    public static let environmentKey = "VOICELAYER_V5_UI"

    public static func isEnabled(
        defaults: UserDefaults,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let override = environment[environmentKey].flatMap(parseOverride) {
            return override
        }
        if defaults.object(forKey: defaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    private static func parseOverride(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            true
        case "0", "false", "no", "off":
            false
        default:
            nil
        }
    }
}
