import Foundation

public enum VoiceBarDevState {
    public static let keepExpandedEnvironmentVariable = "VOICEBAR_DEV_KEEP_EXPANDED"
    public static let keepExpandedFlagPath = "/tmp/.voicelayer-voicebar-expanded"

    public static func shouldKeepExpanded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let environmentValue = environment[keepExpandedEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return environmentValue == "1" || fileExists(keepExpandedFlagPath)
    }
}
