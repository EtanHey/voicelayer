import Foundation

/// Shared VoiceLayer temp paths for the Swift client.
/// Must stay aligned with `src/paths.ts`.
enum VoiceLayerPaths {
    static let tmpDirectory = "/tmp"

    static func tmpPath(_ name: String) -> String {
        "\(tmpDirectory)/\(name)"
    }

    static let socketPath = tmpPath("voicelayer.sock")
    static let mcpSocketPath = tmpPath("voicelayer-mcp.sock")
    static let daemonPIDPath = tmpPath("voicelayer-mcp.pid")
}
