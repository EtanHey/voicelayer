import Foundation

// VoiceBarDaemonLaunchConfiguration defined in VoiceBarDaemonController.swift

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
