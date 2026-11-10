import Foundation
import Darwin

/// Runs before AppDelegate exists: a manual canonical launch cannot displace a live owner.
enum VoiceBarLaunchCustody {
    static let label = "com.voicelayer.voicebar"
    static let executable = "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar"

    static func needsHandoff(bundlePath: String, singleton: Bool, service: String?) -> Bool {
        singleton && bundlePath == "/Applications/VoiceBar.app" && service != label
    }

    static func validAgent(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == label else { return false }
        let arguments = plist["ProgramArguments"] as? [String]
        return (plist["Program"] as? String ?? arguments?.first) == executable
            && (arguments == nil || arguments == [executable])
    }

    static func handoff(
        plist: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist"),
        attachLog: () -> Bool = attachFileLog,
        run: ([String]) -> Bool = run,
        log: (String) -> Void = { NSLog("%@", $0) }
    ) -> Bool {
        // Keep the log attached even when setup has not installed a usable agent yet.
        guard attachLog() else {
            log("[VoiceBar][launch_custody] fallthrough=file_log_unavailable")
            return false
        }
        let data: Data
        do { data = try Data(contentsOf: plist) }
        catch {
            let reason = (error as? CocoaError)?.code == .fileReadNoSuchFile ? "missing_agent" : "unreadable_agent"
            log("[VoiceBar][launch_custody] fallthrough=\(reason)")
            return false
        }
        guard validAgent(data) else {
            log("[VoiceBar][launch_custody] fallthrough=invalid_agent")
            return false
        }
        let domain = "gui/\(getuid())"
        let job = "\(domain)/\(label)"
        // No -k, bootout, plist rewrite, second daemon owner, or incumbent signal.
        let loaded = run(["print", job])
        guard run(loaded ? ["kickstart", job] : ["bootstrap", domain, plist.path]) else {
            log("[VoiceBar][launch_custody] fallthrough=\(loaded ? "kickstart_failed" : "bootstrap_failed")")
            return false
        }
        log("[VoiceBar][launch_custody] handoff=accepted pid=\(getpid())")
        return true
    }

    private static func attachFileLog() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/voicelayer")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent("voicebar-err.log").path
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return fchmod(fd, 0o600) == 0 && dup2(fd, STDERR_FILENO) >= 0
        } catch { return false }
    }

    private static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        guard finished.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}
