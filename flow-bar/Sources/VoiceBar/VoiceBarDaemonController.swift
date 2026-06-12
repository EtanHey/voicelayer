import AppKit
import Darwin
import Foundation
import VoiceBarUI

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

enum VoiceBarDaemonEnvironment {
    private static let preserveQAOverridesEnvironmentVariable = "VOICEBAR_QA_PRESERVE_OVERRIDES"
    private static let legacyPreserveQAOverridesEnvironmentVariable = "QA_VOICEBAR_PRESERVE_TEST_OVERRIDES"

    private static let preservedQAOverrideAllowlist: Set<String> = [
        "QA_VOICE_DISABLE_FLAG_PATH",
        "QA_VOICE_MCP_PID_PATH",
        "QA_VOICE_MCP_SOCKET_PATH",
        "QA_VOICE_RECORDING_STATE_PATH",
        "QA_VOICE_RETAINED_RECORDING_PATH",
        "QA_VOICE_SOCKET_PATH",
    ]

    private static let inheritedEnvironmentDenylist: Set<String> = [
        "CODEX_CI",
        "DISABLE_VOICELAYER",
        "QA_VOICE_ALLOW_SOCKET_RECLAIM",
        "QA_VOICE_CHUNKED_STT",
        "QA_VOICE_DISABLE_FLAG_PATH",
        "QA_VOICE_MCP_PID_PATH",
        "QA_VOICE_MCP_SOCKET_PATH",
        "QA_VOICE_RECORDINGS_DIR",
        "QA_VOICE_RECORDING_STATE_PATH",
        "QA_VOICE_RETAINED_RECORDING_PATH",
        "QA_VOICE_SOCKET_PATH",
        "QA_VOICE_WISPR_DB_PATH",
    ]

    static func sanitizedDaemonEnvironment(
        from inherited: [String: String] = ProcessInfo.processInfo.environment,
        path: String
    ) -> [String: String] {
        var env = inherited
        let preservesQAOverrides = shouldPreserveQAOverrides(inherited)
        for key in inheritedEnvironmentDenylist {
            if preservesQAOverrides, preservedQAOverrideAllowlist.contains(key) {
                continue
            }
            env.removeValue(forKey: key)
        }
        env.removeValue(forKey: preserveQAOverridesEnvironmentVariable)
        env.removeValue(forKey: legacyPreserveQAOverridesEnvironmentVariable)
        env["PATH"] = path
        env.removeValue(forKey: "VOICELAYER_ALLOW_SOCKET_RECLAIM")
        env.removeValue(forKey: "QA_VOICE_ALLOW_SOCKET_RECLAIM")
        return env
    }

    private static func shouldPreserveQAOverrides(_ environment: [String: String]) -> Bool {
        environment[preserveQAOverridesEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ||
            environment[legacyPreserveQAOverridesEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
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
        socketProbe: (String) -> Bool = VoiceBarDaemonLivenessProbe.isSocketLive,
        excludingPID: Int32? = nil
    ) -> Bool {
        guard socketProbe(socketPath) else {
            return false
        }

        guard let pid = readDaemonPID(pidFilePath: pidFilePath, fileManager: fileManager) else {
            NSLog("[VoiceBar] Treating live MCP socket as occupied because PID file is absent")
            return true
        }
        if let excludingPID, pid == excludingPID {
            return false
        }

        let processAlive = kill(pid, 0) == 0 || errno == EPERM
        if !processAlive {
            NSLog("[VoiceBar] MCP socket is live but daemon PID %d is stale", pid)
        }
        return true
    }

    private static func readDaemonPID(
        pidFilePath: String,
        fileManager: FileManager
    ) -> Int32? {
        guard fileManager.fileExists(atPath: pidFilePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: pidFilePath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int32
        else {
            return nil
        }
        return pid
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
    typealias RestartScheduler = (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void
    typealias ProcessExitWaiter = (_ process: Process, _ timeout: TimeInterval) -> Bool
    typealias ForceKillProcess = (_ pid: Int32) -> Void
    typealias MicrophonePermissionPrompter = (_ message: String) -> Void

    private static let stabilityResetDelay: TimeInterval = 300
    private static let gracefulStopTimeout: TimeInterval = 1.0

    private let executableURLProvider: () -> URL?
    private let configurationProvider: (URL) -> VoiceBarDaemonLaunchConfiguration?
    private let processFactory: () -> Process
    private let restartScheduler: RestartScheduler
    private let processExitWaiter: ProcessExitWaiter
    private let forceKillProcess: ForceKillProcess
    private let microphonePermissionPrompter: MicrophonePermissionPrompter
    private let livenessProbe: () -> Bool
    private var process: Process?

    private(set) var ownsLaunchedProcess = false
    private var restartCount = 0
    private var isRestartScheduled = false
    private var consecutiveBrokenMicFailures = 0
    private var lastBrokenMicFailureAt: Date?
    private var stopping = false

    /// Enriched PATH for daemon — includes Homebrew paths that launchd doesn't provide.
    static let daemonPATH: String = {
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
        processFactory: @escaping () -> Process = { Process() },
        restartScheduler: @escaping RestartScheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        },
        processExitWaiter: @escaping ProcessExitWaiter = VoiceBarDaemonController.waitForProcessExit,
        forceKillProcess: @escaping ForceKillProcess = { pid in
            _ = Darwin.kill(pid, SIGKILL)
        },
        microphonePermissionPrompter: @escaping MicrophonePermissionPrompter = VoiceBarDaemonController
            .showMicrophonePermissionPrompt
    ) {
        self.executableURLProvider = executableURLProvider
        self.configurationProvider = configurationProvider
        self.processFactory = processFactory
        self.restartScheduler = restartScheduler
        self.processExitWaiter = processExitWaiter
        self.forceKillProcess = forceKillProcess
        self.microphonePermissionPrompter = microphonePermissionPrompter
        self.livenessProbe = livenessProbe
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

        return launch()
    }

    func handleCaptureFailure(type: String) {
        guard type == "broken-mic" else { return }
        guard !VoiceLayerPaths.isVoicelayerDisabled() else {
            NSLog("[VoiceBar] Broken-mic capture failure while VoiceLayer disabled — not restarting daemon")
            return
        }

        let now = Date()
        if let lastBrokenMicFailureAt,
           now.timeIntervalSince(lastBrokenMicFailureAt) <= 60 {
            consecutiveBrokenMicFailures += 1
        } else {
            consecutiveBrokenMicFailures = 1
        }
        lastBrokenMicFailureAt = now

        if consecutiveBrokenMicFailures < 2 {
            NSLog("[VoiceBar] Broken-mic capture failure — waiting for confirmation before daemon respawn")
            return
        }

        if consecutiveBrokenMicFailures >= 2 {
            microphonePermissionPrompter(
                "VoiceLayer is still receiving silence from the microphone after restarting its daemon. Re-grant Microphone permission to VoiceBar in System Settings, then retry recording."
            )
        }

        NSLog("[VoiceBar] Broken-mic capture failure — respawning child daemon to refresh microphone TCC")
        terminateOwnedChildForRespawn()
        scheduleRestart(exitKind: "broken-mic", code: 0, reason: .exit)
    }

    private func launch() -> VoiceBarDaemonActivationResult {
        guard !VoiceLayerPaths.isVoicelayerDisabled() else {
            process = nil
            ownsLaunchedProcess = false
            NSLog("[VoiceBar] VoiceLayer disabled — refusing daemon launch")
            return .unavailable
        }

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
        var daemonEnvironment = VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(path: Self.daemonPATH)
        daemonEnvironment["VOICEBAR_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        proc.environment = daemonEnvironment

        // Monitor: every unexpected death restarts. Exit 0 is terminal only
        // when the explicit disable flag is present.
        proc.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            let reason = terminated.terminationReason
            DispatchQueue.main.async { [weak self, terminated] in
                guard let self, !self.stopping else { return }
                if process === terminated {
                    process = nil
                    ownsLaunchedProcess = false
                }

                if VoiceLayerPaths.isVoicelayerDisabled() {
                    NSLog("[VoiceBar] Daemon exited (code %d) while VoiceLayer disabled — not restarting", code)
                    return
                }

                if code == 0, livenessProbe() {
                    restartCount = 0
                    isRestartScheduled = false
                    NSLog("[VoiceBar] Daemon exited cleanly while another MCP daemon is live — not restarting")
                    return
                }

                scheduleRestart(exitKind: code == 0 ? "exited cleanly" : "crashed", code: code, reason: reason)
            }
        }

        do {
            try proc.run()
            process = proc
            ownsLaunchedProcess = true
            isRestartScheduled = false
            scheduleStabilityReset(for: proc)
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

    private func scheduleRestart(
        exitKind: String,
        code: Int32,
        reason: Process.TerminationReason
    ) {
        guard !VoiceLayerPaths.isVoicelayerDisabled() else {
            isRestartScheduled = false
            ownsLaunchedProcess = false
            NSLog("[VoiceBar] Daemon %@ (code %d, reason %d) while VoiceLayer disabled — not restarting",
                  exitKind, code, reason.rawValue)
            return
        }

        guard !isRestartScheduled else {
            NSLog("[VoiceBar] Daemon %@ (code %d, reason %d) — restart already scheduled",
                  exitKind, code, reason.rawValue)
            return
        }
        isRestartScheduled = true

        NSLog("[VoiceBar] Daemon %@ (code %d, reason %d) — scheduling restart #%d",
              exitKind, code, reason.rawValue, restartCount + 1)

        // Exponential backoff: 1s, 2s, 4s, 8s, max 15s
        restartCount += 1
        let delay = min(15.0, pow(2.0, Double(restartCount - 1)))

        restartScheduler(delay) { [weak self] in
            guard let self, !stopping else { return }
            isRestartScheduled = false
            if let process, process.isRunning {
                NSLog("[VoiceBar] Skipping daemon restart; child process is already running")
                return
            }
            if livenessProbe() {
                restartCount = 0
                ownsLaunchedProcess = false
                NSLog("[VoiceBar] Skipping daemon restart; another MCP daemon is live")
                return
            }
            NSLog("[VoiceBar] Restarting daemon (attempt %d, after %.0fs)", restartCount, delay)
            let result = activateIfNeeded()
            if result == .unavailable, !VoiceLayerPaths.isVoicelayerDisabled() {
                NSLog("[VoiceBar] Daemon restart attempt failed — rescheduling")
                scheduleRestart(exitKind: "relaunch failed", code: -1, reason: .exit)
            }
        }
    }

    private func scheduleStabilityReset(for launchedProcess: Process) {
        restartScheduler(Self.stabilityResetDelay) { [weak self, weak launchedProcess] in
            guard let self,
                  !stopping,
                  let launchedProcess,
                  process === launchedProcess,
                  launchedProcess.isRunning,
                  restartCount > 0
            else {
                return
            }
            restartCount = 0
            consecutiveBrokenMicFailures = 0
            lastBrokenMicFailureAt = nil
            NSLog("[VoiceBar] Daemon stable for %.0fs — reset restart counter", Self.stabilityResetDelay)
        }
    }

    private func terminateOwnedChildForRespawn() {
        guard ownsLaunchedProcess, let process else {
            ownsLaunchedProcess = false
            self.process = nil
            return
        }
        if process.isRunning {
            process.terminate()
            if !processExitWaiter(process, Self.gracefulStopTimeout), process.isRunning {
                NSLog("[VoiceBar] Daemon did not exit after broken-mic SIGTERM — sending SIGKILL to PID %d",
                      process.processIdentifier)
                forceKillProcess(process.processIdentifier)
                _ = processExitWaiter(process, Self.gracefulStopTimeout)
            }
        }
        self.process = nil
        ownsLaunchedProcess = false
    }

    func stop() {
        stopping = true
        isRestartScheduled = false
        guard ownsLaunchedProcess, let process else { return }
        if process.isRunning {
            process.terminate()
            if !processExitWaiter(process, Self.gracefulStopTimeout), process.isRunning {
                NSLog("[VoiceBar] Daemon did not exit after SIGTERM — sending SIGKILL to PID %d",
                      process.processIdentifier)
                forceKillProcess(process.processIdentifier)
                _ = processExitWaiter(process, Self.gracefulStopTimeout)
            }
        }
        self.process = nil
        ownsLaunchedProcess = false
    }

    private static func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return !process.isRunning
    }

    private static func showMicrophonePermissionPrompt(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "VoiceLayer microphone permission needs attention"
            alert.informativeText = message
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
