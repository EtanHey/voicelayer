import Foundation

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

        var candidate = executableURL.deletingLastPathComponent()

        while true {
            let packagePath = candidate.appendingPathComponent("flow-bar/Package.swift").path
            let daemonPath = candidate.appendingPathComponent("src/daemon.ts").path
            if fileExists(packagePath), fileExists(daemonPath) {
                return candidate.path
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }
}

final class VoiceBarDaemonLauncher {
    private let executableURLProvider: () -> URL?
    private let configurationProvider: (URL) -> VoiceBarDaemonLaunchConfiguration?
    private let processFactory: () -> Process
    private var process: Process?

    init(
        executableURLProvider: @escaping () -> URL? = {
            Bundle.main.executableURL
        },
        configurationProvider: @escaping (URL) -> VoiceBarDaemonLaunchConfiguration? = {
            VoiceBarDaemonLaunchConfiguration.configuration(for: $0)
        },
        processFactory: @escaping () -> Process = { Process() }
    ) {
        self.executableURLProvider = executableURLProvider
        self.configurationProvider = configurationProvider
        self.processFactory = processFactory
    }

    func startIfNeeded() {
        if let process, process.isRunning {
            return
        }

        guard let executableURL = executableURLProvider(),
              let configuration = configurationProvider(executableURL)
        else {
            NSLog("[VoiceBar] Daemon auto-start unavailable: no launch configuration")
            return
        }

        let process = processFactory()
        process.executableURL = URL(fileURLWithPath: configuration.launchPath)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)

        do {
            try process.run()
            self.process = process
            NSLog("[VoiceBar] Auto-started daemon: %@", configuration.arguments.joined(separator: " "))
        } catch {
            NSLog("[VoiceBar] Failed to auto-start daemon: %@", error.localizedDescription)
            self.process = nil
        }
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
    }
}
