import Foundation
import VoiceBarUI

/// Shared VoiceLayer temp paths for the Swift client.
/// Must stay aligned with `src/paths.ts`.
enum VoiceLayerPaths {
    static let tmpDirectory = "/tmp"
    static let disableEnvironmentVariable = "DISABLE_VOICELAYER"
    static let disableFlagOverrideEnvironmentVariable = "QA_VOICE_DISABLE_FLAG_PATH"
    static let socketOverrideEnvironmentVariable = "QA_VOICE_SOCKET_PATH"
    static let mcpSocketOverrideEnvironmentVariable = "QA_VOICE_MCP_SOCKET_PATH"
    static let daemonPIDOverrideEnvironmentVariable = "QA_VOICE_MCP_PID_PATH"
    static let retainedRecordingOverrideEnvironmentVariable = "QA_VOICE_RETAINED_RECORDING_PATH"
    static let devInstanceEnvironmentVariable = "VOICELAYER_DEV_INSTANCE"

    static func tmpPath(_ name: String) -> String {
        "\(tmpDirectory)/\(name)"
    }

    private static func environmentValue(_ name: String) -> String? {
        guard let rawValue = getenv(name) else { return nil }
        let value = String(cString: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static var isDevInstance: Bool {
        environmentValue(devInstanceEnvironmentVariable) == "1"
    }

    static func voiceDisabledFlagPath() -> String {
        environmentValue(disableFlagOverrideEnvironmentVariable) ?? tmpPath(".voicelayer-daemon-disabled")
    }

    static func isVoicelayerDisabled() -> Bool {
        if environmentValue(disableEnvironmentVariable) == "1" {
            return true
        }
        return FileManager.default.fileExists(atPath: voiceDisabledFlagPath())
    }

    static var socketPath: String {
        environmentValue(socketOverrideEnvironmentVariable)
            ?? (isDevInstance ? tmpPath("voicelayer-dev.sock") : tmpPath("voicelayer.sock"))
    }

    static var mcpSocketPath: String {
        environmentValue(mcpSocketOverrideEnvironmentVariable)
            ?? (isDevInstance ? tmpPath("voicelayer-dev-mcp.sock") : tmpPath("voicelayer-mcp.sock"))
    }

    static var daemonPIDPath: String {
        environmentValue(daemonPIDOverrideEnvironmentVariable)
            ?? (isDevInstance ? tmpPath("voicelayer-dev-mcp.pid") : tmpPath("voicelayer-mcp.pid"))
    }

    static var retainedRecordingPath: String {
        environmentValue(retainedRecordingOverrideEnvironmentVariable)
            ?? (isDevInstance ? tmpPath("voicelayer-dev-last-recording.wav") : tmpPath("voicelayer-last-recording.wav"))
    }

    static var enforcesSingletonInstance: Bool {
        environmentValue(socketOverrideEnvironmentVariable) == nil && !isDevInstance
    }
}
