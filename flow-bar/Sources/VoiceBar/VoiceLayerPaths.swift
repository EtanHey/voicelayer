import Foundation

/// Shared VoiceLayer temp paths for the Swift client.
/// Must stay aligned with `src/paths.ts`.
enum VoiceLayerPaths {
    static let tmpDirectory = "/tmp"
    static let disableEnvironmentVariable = "DISABLE_VOICELAYER"
    static let disableFlagOverrideEnvironmentVariable = "QA_VOICE_DISABLE_FLAG_PATH"

    static func tmpPath(_ name: String) -> String {
        "\(tmpDirectory)/\(name)"
    }

    private static func environmentValue(_ name: String) -> String? {
        guard let rawValue = getenv(name) else { return nil }
        let value = String(cString: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func voiceDisabledFlagPath() -> String {
        environmentValue(disableFlagOverrideEnvironmentVariable) ?? tmpPath(".claude_voice_disabled")
    }

    static func isVoicelayerDisabled() -> Bool {
        if environmentValue(disableEnvironmentVariable) == "1" {
            return true
        }
        return FileManager.default.fileExists(atPath: voiceDisabledFlagPath())
    }

    static let socketPath = tmpPath("voicelayer.sock")
    static let mcpSocketPath = tmpPath("voicelayer-mcp.sock")
    static let daemonPIDPath = tmpPath("voicelayer-mcp.pid")
}
