import Foundation
import VoiceBarUI

/// Shared VoiceLayer temp paths for the Swift client.
/// Must stay aligned with `src/paths.ts`.
enum VoiceLayerPaths {
    static let tmpDirectory = "/tmp"
    static let stateDirectoryOverrideEnvironmentVariable = "VOICELAYER_STATE_DIR"
    static var stateDirectory: String {
        environmentValue(stateDirectoryOverrideEnvironmentVariable) ??
            NSHomeDirectory() + "/.local/state/voicelayer"
    }

    static let disableEnvironmentVariable = "DISABLE_VOICELAYER"
    static let disableFlagOverrideEnvironmentVariable = "QA_VOICE_DISABLE_FLAG_PATH"
    static let socketOverrideEnvironmentVariable = "QA_VOICE_SOCKET_PATH"
    static let mcpSocketOverrideEnvironmentVariable = "QA_VOICE_MCP_SOCKET_PATH"
    static let daemonPIDOverrideEnvironmentVariable = "QA_VOICE_MCP_PID_PATH"
    static let daemonHeartbeatOverrideEnvironmentVariable = "QA_VOICE_MCP_HEARTBEAT_PATH"
    static let retainedRecordingOverrideEnvironmentVariable = "QA_VOICE_RETAINED_RECORDING_PATH"

    static func tmpPath(_ name: String) -> String {
        "\(tmpDirectory)/\(name)"
    }

    private static func environmentValue(_ name: String) -> String? {
        guard let rawValue = getenv(name) else { return nil }
        let value = String(cString: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
        environmentValue(socketOverrideEnvironmentVariable) ?? tmpPath("voicelayer.sock")
    }

    static var mcpSocketPath: String {
        environmentValue(mcpSocketOverrideEnvironmentVariable) ?? tmpPath("voicelayer-mcp.sock")
    }

    static var daemonPIDPath: String {
        environmentValue(daemonPIDOverrideEnvironmentVariable) ?? tmpPath("voicelayer-mcp.pid")
    }

    static var daemonHeartbeatPath: String {
        mcpHeartbeatPath(value: environmentValue)
    }

    /// Heartbeat path the daemon will publish, given its environment.
    /// Must match `mcpHeartbeatFilePath` in `src/paths.ts`.
    static func mcpHeartbeatPath(environment: [String: String]) -> String {
        mcpHeartbeatPath { key in
            guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawValue.isEmpty
            else {
                return nil
            }
            return rawValue
        }
    }

    private static func mcpHeartbeatPath(value: (String) -> String?) -> String {
        if let override = value(daemonHeartbeatOverrideEnvironmentVariable) {
            return override
        }
        if let pidOverride = value(daemonPIDOverrideEnvironmentVariable) {
            return heartbeatPath(besidePidPath: pidOverride)
        }
        if let socketOverride = value("VOICELAYER_MCP_SOCKET_PATH") ??
            value(mcpSocketOverrideEnvironmentVariable)
        {
            return socketOverride + ".heartbeat"
        }
        return (value(stateDirectoryOverrideEnvironmentVariable) ??
            NSHomeDirectory() + "/.local/state/voicelayer") + "/voicelayer-mcp.heartbeat"
    }

    private static func heartbeatPath(besidePidPath pidPath: String) -> String {
        if pidPath.hasSuffix(".pid") {
            return String(pidPath.dropLast(4)) + ".heartbeat"
        }
        return pidPath + ".heartbeat"
    }

    static var retainedRecordingPath: String {
        environmentValue(retainedRecordingOverrideEnvironmentVariable) ?? tmpPath("voicelayer-last-recording.wav")
    }

    static var enforcesSingletonInstance: Bool {
        environmentValue(socketOverrideEnvironmentVariable) == nil
    }
}
