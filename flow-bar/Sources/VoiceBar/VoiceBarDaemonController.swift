import Foundation

enum VoiceBarDaemonActivationResult: Equatable {
    case alreadyRunning
    case launched
    case unavailable
}

struct VoiceBarDaemonLaunchConfiguration: Equatable {
    let launchPath: String
    let arguments: [String]
    let workingDirectory: String

    /// Resolve the full path to the `bun` binary.
    /// CRITICAL: Must NOT use /usr/bin/env as launchPath — env creates an intermediate
    /// process that exits, orphaning the daemon to launchd (PPID=1). Orphaned processes
    /// lose TCC mic permission inheritance from VoiceBar.
    private static func resolveBunPath(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let candidates = [
            NSHomeDirectory() + "/.bun/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
        ]
        return candidates.first(where: fileExists)
    }

    static func configuration(
        for executableURL: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> VoiceBarDaemonLaunchConfiguration? {
        guard let bunPath = resolveBunPath(fileExists: fileExists) else {
            NSLog("[VoiceBar] Cannot find bun binary")
            return nil
        }

        if let repoRoot = repositoryRoot(for: executableURL, fileExists: fileExists) {
            return VoiceBarDaemonLaunchConfiguration(
                launchPath: bunPath,
                arguments: ["run", "\(repoRoot)/src/mcp-server-daemon.ts"],
                workingDirectory: repoRoot
            )
        }

        let resourcesDirectory = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let bundledDaemon = resourcesDirectory
            .appendingPathComponent("src")
            .appendingPathComponent("mcp-server-daemon.ts")
            .path

        guard fileExists(bundledDaemon) else { return nil }
        return VoiceBarDaemonLaunchConfiguration(
            launchPath: bunPath,
            arguments: ["run", bundledDaemon],
            workingDirectory: resourcesDirectory.path
        )
    }

    private static func repositoryRoot(
        for executableURL: URL,
        fileExists: (String) -> Bool
    ) -> String? {
        let pathComponents = executableURL.pathComponents
        if let flowBarIndex = pathComponents.firstIndex(of: "flow-bar"), flowBarIndex > 0 {
            let repoComponents = Array(pathComponents[0 ..< flowBarIndex])
            let repoRoot = NSString.path(withComponents: repoComponents)
            if !repoRoot.isEmpty {
                return repoRoot
            }
        }

        var candidate = executableURL.deletingLastPathComponent()
        for _ in 0 ..< 10 {
            let candidatePath = candidate.path
            if candidatePath == "/" || candidatePath.isEmpty {
                return nil
            }
            let packagePath = candidate.appendingPathComponent("flow-bar/Package.swift").path
            let daemonPath = candidate.appendingPathComponent("src/mcp-server-daemon.ts").path
            if fileExists(packagePath), fileExists(daemonPath) {
                return candidatePath
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }
}

enum VoiceBarDaemonLivenessProbe {
    static let freshSessionCheckCommand =
        "python3 -c \"import json, os, signal, sys; p='/tmp/voicelayer-mcp.pid'; data=json.load(open(p)); os.kill(int(data['pid']), 0)\""

    static func isSocketLive(at socketPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return false
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return false
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                connect(fd, ptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        return result == 0
    }

    static func isDaemonRunning(
        pidFilePath: String = VoiceLayerPaths.daemonPIDPath,
        socketPath: String = VoiceLayerPaths.mcpSocketPath,
        fileManager: FileManager = .default,
        socketProbe: (String) -> Bool = VoiceBarDaemonLivenessProbe.isSocketLive
    ) -> Bool {
        guard fileManager.fileExists(atPath: pidFilePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: pidFilePath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int32
        else {
            return false
        }

        let processAlive = kill(pid, 0) == 0 || errno == EPERM
        guard processAlive else {
            return false
        }

        guard socketProbe(socketPath) else {
            NSLog("[VoiceBar] Ignoring stale daemon PID %d because MCP socket is not live", pid)
            return false
        }

        return true
    }
}

// MARK: - Daemon Controller (Ollama pattern: spawn → monitor → restart)

/// Manages the MCP daemon as a CHILD process of VoiceBar.
///
/// CRITICAL: The daemon MUST remain a child of VoiceBar (not orphaned to launchd)
/// so it inherits VoiceBar's TCC microphone permission. If PPID becomes 1 (launchd),
/// macOS silently denies mic access and sox records silence (rms=0).
///
/// Pattern from Ollama: menu bar app spawns server, monitors via terminationHandler,
/// restarts on crash with exponential backoff.
final class VoiceBarDaemonController {
    private let executableURLProvider: () -> URL?
    private let configurationProvider: (URL) -> VoiceBarDaemonLaunchConfiguration?
    private let livenessProbe: () -> Bool
    private let processFactory: () -> Process
    private var process: Process?

    private(set) var ownsLaunchedProcess = false
    private var restartCount = 0
    private var stopping = false

    /// Enriched PATH for daemon — includes Homebrew paths that launchd doesn't provide.
    private static let daemonPATH: String = {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let extras = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        var parts = base.split(separator: ":").map(String.init)
        for extra in extras where !parts.contains(extra) {
            parts.insert(extra, at: 0)
        }
        return parts.joined(separator: ":")
    }()

    init(
        executableURLProvider: @escaping () -> URL? = {
            Bundle.main.executableURL
        },
        configurationProvider: @escaping (URL) -> VoiceBarDaemonLaunchConfiguration? = {
            VoiceBarDaemonLaunchConfiguration.configuration(for: $0)
        },
        livenessProbe: @escaping () -> Bool = {
            VoiceBarDaemonLivenessProbe.isDaemonRunning()
        },
        processFactory: @escaping () -> Process = { Process() }
    ) {
        self.executableURLProvider = executableURLProvider
        self.configurationProvider = configurationProvider
        self.livenessProbe = livenessProbe
        self.processFactory = processFactory
    }

    func activateIfNeeded() -> VoiceBarDaemonActivationResult {
        if VoiceLayerPaths.isVoicelayerDisabled() {
            ownsLaunchedProcess = false
            NSLog("[VoiceBar] VoiceLayer disabled — skipping daemon activation")
            return .unavailable
        }

        // If we already own a running child, skip
        if let process, process.isRunning {
            return .alreadyRunning
        }

        // External MCP processes can share the PID file, but they do not inherit
        // VoiceBar's TCC microphone grant. Keep an owned child for VoiceBar;
        // mcp-server-daemon.ts serializes ownership with acquireProcessLock().
        if livenessProbe() {
            NSLog("[VoiceBar] External daemon already running — launching owned child for TCC inheritance")
        }

        return launch()
    }

    private func launch() -> VoiceBarDaemonActivationResult {
        guard let executableURL = executableURLProvider(),
              let configuration = configurationProvider(executableURL)
        else {
            ownsLaunchedProcess = false
            return .unavailable
        }

        let proc = processFactory()
        proc.executableURL = URL(fileURLWithPath: configuration.launchPath)
        proc.arguments = configuration.arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)

        // Set environment with enriched PATH — critical for sox/whisper/python3 resolution
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.daemonPATH
        proc.environment = env

        // Monitor: restart on crash (non-zero exit), don't restart on clean exit
        proc.terminationHandler = { [weak self] terminated in
            guard let self, !stopping else { return }
            let code = terminated.terminationStatus
            let reason = terminated.terminationReason

            if code == 0 {
                NSLog("[VoiceBar] Daemon exited cleanly (code 0)")
                ownsLaunchedProcess = false
                return
            }

            NSLog("[VoiceBar] Daemon crashed (code %d, reason %d) — scheduling restart #%d",
                  code, reason.rawValue, restartCount + 1)

            // Exponential backoff: 1s, 2s, 4s, 8s, max 15s
            restartCount += 1
            let delay = min(15.0, pow(2.0, Double(restartCount - 1)))

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !stopping else { return }
                NSLog("[VoiceBar] Restarting daemon (attempt %d, after %.0fs)", restartCount, delay)
                _ = launch()
            }
        }

        do {
            try proc.run()
            process = proc
            ownsLaunchedProcess = true
            NSLog("[VoiceBar] Daemon launched as child (PID %d, PPID %d)",
                  proc.processIdentifier, ProcessInfo.processInfo.processIdentifier)
            return .launched
        } catch {
            NSLog("[VoiceBar] Failed to launch daemon: %@", error.localizedDescription)
            process = nil
            ownsLaunchedProcess = false
            return .unavailable
        }
    }

    func stop() {
        stopping = true
        guard ownsLaunchedProcess, let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        ownsLaunchedProcess = false
    }
}
