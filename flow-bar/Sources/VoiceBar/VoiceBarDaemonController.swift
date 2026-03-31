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

    static func configuration(
        for executableURL: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> VoiceBarDaemonLaunchConfiguration? {
        if let repoRoot = repositoryRoot(for: executableURL, fileExists: fileExists) {
            return VoiceBarDaemonLaunchConfiguration(
                launchPath: "/usr/bin/env",
                arguments: ["bun", "run", "\(repoRoot)/src/daemon.ts"],
                workingDirectory: repoRoot
            )
        }

        let resourcesDirectory = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let bundledDaemon = resourcesDirectory
            .appendingPathComponent("src")
            .appendingPathComponent("daemon.ts")
            .path

        guard fileExists(bundledDaemon) else { return nil }
        return VoiceBarDaemonLaunchConfiguration(
            launchPath: "/usr/bin/env",
            arguments: ["bun", "run", bundledDaemon],
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

        // Walk up from the executable looking for the repo root.
        // Cap at 10 levels to prevent runaway traversal when running
        // from /Applications (URL.deletingLastPathComponent can produce
        // /../.. paths that never converge on macOS).
        var candidate = executableURL.deletingLastPathComponent()
        for _ in 0 ..< 10 {
            let candidatePath = candidate.path
            if candidatePath == "/" || candidatePath.isEmpty {
                return nil
            }
            let packagePath = candidate.appendingPathComponent("flow-bar/Package.swift").path
            let daemonPath = candidate.appendingPathComponent("src/daemon.ts").path
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
        "python3 -c \"import json, os, signal, sys; p='/tmp/voicelayer-daemon.pid'; data=json.load(open(p)); os.kill(int(data['pid']), 0)\""

    static func isDaemonRunning(
        pidFilePath: String = VoiceLayerPaths.daemonPIDPath,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: pidFilePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: pidFilePath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int32
        else {
            return false
        }

        return kill(pid, 0) == 0 || errno == EPERM
    }
}

final class VoiceBarDaemonController {
    private let executableURLProvider: () -> URL?
    private let configurationProvider: (URL) -> VoiceBarDaemonLaunchConfiguration?
    private let livenessProbe: () -> Bool
    private let processFactory: () -> Process
    private var process: Process?

    private(set) var ownsLaunchedProcess = false

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
        if livenessProbe() {
            ownsLaunchedProcess = false
            return .alreadyRunning
        }

        guard let executableURL = executableURLProvider(),
              let configuration = configurationProvider(executableURL)
        else {
            ownsLaunchedProcess = false
            return .unavailable
        }

        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: configuration.launchPath)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)

        do {
            try process.run()
            self.process = process
            ownsLaunchedProcess = true
            return .launched
        } catch {
            self.process = nil
            ownsLaunchedProcess = false
            return .unavailable
        }
    }

    func stop() {
        guard ownsLaunchedProcess else { return }
        process?.terminate()
        process = nil
        ownsLaunchedProcess = false
    }
}
