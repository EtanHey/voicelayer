import Darwin
import Foundation

/// Probe is read-only: authentication + HTTP readiness, never /warmup or synthesis.
enum CloneEngineProbe {
    static func inspect(url: URL, tokenFile: String, completion: @escaping (CloneEngineObservation) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
            var info = stat()
            if lstat(tokenFile, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
               info.st_mode & 0o777 == 0o600, info.st_uid == getuid(),
               let token = try? String(contentsOfFile: tokenFile).trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let observation: CloneEngineObservation
                if request.value(forHTTPHeaderField: "Authorization") != nil,
                   (response as? HTTPURLResponse)?.statusCode == 200, let data,
                   let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   body["status"] as? String == "ok", let pid = body["pid"] as? Int, pid > 0, pid <= Int(Int32.max) {
                    observation = .healthy(pid)
                } else {
                    observation = endpointOccupied(port: url.port ?? 80) ? .occupied : .absent
                }
                DispatchQueue.main.async { completion(observation) }
            }.resume()
        }
    }

    /// A closed listener can leave TIME_WAIT tuples that reject bind without
    /// occupying the service endpoint. Probe connections, never reserve its port.
    private static func endpointOccupied(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return true }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { return true }
        let code = errno
        if code == ECONNREFUSED { return false }
        guard code == EINPROGRESS else { return true }
        var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pending, 1, 200) > 0 else { return true }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return true }
        return socketError != ECONNREFUSED // Other uncertainty fails closed.
    }
}

extension CloneEngineController {
    /// QA/candidate apps never probe or start the resident engine. Tests inject their own runtime.
    static func production(defaults: UserDefaults, executable: URL,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> CloneEngineController? {
        guard SocketBindingPolicy.allowsEnvironment(environment),
              environment[VoiceBarDefaults.suiteEnvironmentVariable] == nil,
              environment["VOICELAYER_TEST_ISOLATED"] != "1",
              environment["XCTestConfigurationFilePath"] == nil,
              environment["VOICEBAR_QA_PRESERVE_OVERRIDES"] != "1",
              environment["QA_VOICEBAR_PRESERVE_TEST_OVERRIDES"] != "1",
              VoiceBarDefaults.shouldEnforceSingleton(environment: environment),
              VoiceLayerPaths.socketPath == "/tmp/voicelayer.sock",
              Bundle.main.bundleIdentifier == "com.voicelayer.voicebar" else { return nil }
        let home = NSHomeDirectory()
        let autostart = defaults.object(forKey: preferenceKey) as? Bool ?? true
        let log = CloneEngineLog(url: URL(fileURLWithPath: home + "/Library/Logs/voicelayer/clone-engine.log"))
        return CloneEngineController(autostart: autostart, saveAutostart: { defaults.set($0, forKey: preferenceKey) },
            probe: { CloneEngineProbe.inspect(url: URL(string: "http://127.0.0.1:8880/health")!,
                                             tokenFile: home + "/.voicelayer/daemon.secret", completion: $0) },
            makeProcess: {
                let python = home + "/.voicelayer/venv/bin/python"
                guard FileManager.default.isExecutableFile(atPath: python) else { throw CloneEngineLaunchError.pythonMissing }
                guard let config = VoiceBarDaemonLaunchConfiguration.configuration(for: executable) else {
                    throw CloneEngineLaunchError.sourceUnavailable
                }
                let script = URL(fileURLWithPath: config.workingDirectory).appendingPathComponent("src/tts_daemon.py")
                guard FileManager.default.fileExists(atPath: script.path) else { throw CloneEngineLaunchError.scriptMissing }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = [script.path, "--host", "127.0.0.1", "--port", "8880"]
                process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
                // Deliberately no inherited API keys, Python injection, proxy or QA configuration.
                process.environment = ["HOME": home, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8"]
                process.standardInput = FileHandle.nullDevice
                log.attach(to: process)
                return process
            }, diagnostic: { log.appendLine($0) })
    }
}
