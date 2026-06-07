import Foundation
import VoiceBarUI

/// Shared VoiceLayer temp paths for the Swift client.
/// Must stay aligned with `src/paths.ts`.
enum VoiceLayerPaths {
    static let tmpDirectory = "/tmp"
    static let disableEnvironmentVariable = "DISABLE_VOICELAYER"
    static let disableFlagOverrideEnvironmentVariable = "QA_VOICE_DISABLE_FLAG_PATH"
    static let devInstanceEnvironmentVariable = "VOICELAYER_DEV_INSTANCE"
    static let socketOverrideEnvironmentVariable = "VOICELAYER_SOCKET_PATH"
    static let legacySocketOverrideEnvironmentVariable = "QA_VOICE_SOCKET_PATH"
    static let mcpSocketOverrideEnvironmentVariable = "VOICELAYER_MCP_SOCKET_PATH"
    static let legacyMcpSocketOverrideEnvironmentVariable = "QA_VOICE_MCP_SOCKET_PATH"
    static let daemonPIDOverrideEnvironmentVariable = "VOICELAYER_MCP_PID_PATH"
    static let legacyDaemonPIDOverrideEnvironmentVariable = "QA_VOICE_MCP_PID_PATH"
    static let retainedRecordingOverrideEnvironmentVariable = "VOICELAYER_RETAINED_RECORDING_PATH"
    static let legacyRetainedRecordingOverrideEnvironmentVariable = "QA_VOICE_RETAINED_RECORDING_PATH"

    static func tmpPath(_ name: String) -> String {
        "\(tmpDirectory)/\(name)"
    }

    private static func environmentValue(_ name: String) -> String? {
        guard let rawValue = getenv(name) else { return nil }
        let value = String(cString: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func environmentValue(_ names: String...) -> String? {
        for name in names {
            if let value = environmentValue(name) {
                return value
            }
        }
        return nil
    }

    static var isDevInstance: Bool {
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
        environmentValue(socketOverrideEnvironmentVariable, legacySocketOverrideEnvironmentVariable) ??
            tmpPath(isDevInstance ? "voicelayer-dev.sock" : "voicelayer.sock")
    }

    static var mcpSocketPath: String {
        environmentValue(mcpSocketOverrideEnvironmentVariable, legacyMcpSocketOverrideEnvironmentVariable) ??
            tmpPath(isDevInstance ? "voicelayer-dev-mcp.sock" : "voicelayer-mcp.sock")
    }

    static var daemonPIDPath: String {
        environmentValue(daemonPIDOverrideEnvironmentVariable, legacyDaemonPIDOverrideEnvironmentVariable) ??
            tmpPath(isDevInstance ? "voicelayer-dev-mcp.pid" : "voicelayer-mcp.pid")
    }

    static var retainedRecordingPath: String {
        environmentValue(
            retainedRecordingOverrideEnvironmentVariable,
            legacyRetainedRecordingOverrideEnvironmentVariable
        ) ?? tmpPath(isDevInstance ? "voicelayer-dev-last-recording.wav" : "voicelayer-last-recording.wav")
    }

    static var enforcesSingletonInstance: Bool {
        !isDevInstance && environmentValue(
            socketOverrideEnvironmentVariable,
            legacySocketOverrideEnvironmentVariable
        ) ==
            nil
    }
}
