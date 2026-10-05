import Foundation

/// Only the installed, non-QA app may use resident socket paths.
enum SocketBindingPolicy {
    static let livePaths: Set<String> = ["/tmp/voicelayer.sock", "/tmp/voicelayer-mcp.sock"]
    static var isQABuild: Bool {
        #if VOICEBAR_QA
            return true
        #else
            return false
        #endif
    }

    static func allowsBind(
        bundlePath: String,
        socketPath: String,
        environment: [String: String],
        qaBuild: Bool = isQABuild,
        protectedPaths: Set<String> = livePaths
    ) -> Bool {
        let path = normalizedSocketPath(socketPath)
        guard protectedPaths.contains(where: { normalizedSocketPath($0) == path }) else { return true }
        return bundlePath == "/Applications/VoiceBar.app" && !qaBuild &&
            environment["VOICEBAR_QA_BUILD"]?.trimmingCharacters(in: .whitespacesAndNewlines) != "1"
    }

    /// /tmp is /private/tmp on macOS; a spelling alias is not an isolation override.
    private static func normalizedSocketPath(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized.hasPrefix("/private/tmp/") ? String(normalized.dropFirst(8)) : normalized
    }

    /// Check both the supplied name and its filesystem aliases before any unlink/bind.
    static func allowsRuntimeBind(
        bundlePath: String, socketPath: String, environment: [String: String], qaBuild: Bool = isQABuild
    ) -> Bool {
        [socketPath, URL(fileURLWithPath: socketPath).resolvingSymlinksInPath().path].allSatisfy {
            allowsBind(bundlePath: bundlePath, socketPath: $0, environment: environment, qaBuild: qaBuild)
        }
    }

    static func allowsEnvironment(
        _ environment: [String: String],
        bundlePath: String = Bundle.main.bundlePath,
        qaBuild: Bool = isQABuild
    ) -> Bool {
        [VoiceLayerPaths.socketPath(environment: environment),
         VoiceLayerPaths.mcpSocketPath(environment: environment)].allSatisfy {
            allowsRuntimeBind(bundlePath: bundlePath, socketPath: $0, environment: environment, qaBuild: qaBuild)
        }
    }
}
