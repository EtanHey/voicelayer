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
                    // Binding is a non-mutating occupancy check, including unresponsive servers.
                    let fd = socket(AF_INET, SOCK_STREAM, 0)
                    var address = sockaddr_in()
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = in_port_t(url.port ?? 80).bigEndian
                    address.sin_addr.s_addr = inet_addr("127.0.0.1")
                    let available = fd >= 0 && withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
                    }
                    if fd >= 0 { close(fd) }
                    observation = available ? .absent : .occupied
                }
                DispatchQueue.main.async { completion(observation) }
            }.resume()
        }
    }
}

extension CloneEngineController {
    /// QA/candidate apps never probe or start the resident engine. Tests inject their own runtime.
    static func production(defaults: UserDefaults, executable: URL,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> CloneEngineController? {
        guard environment[VoiceBarDefaults.suiteEnvironmentVariable] == nil,
              environment["VOICELAYER_TEST_ISOLATED"] != "1",
              environment["XCTestConfigurationFilePath"] == nil,
              environment["VOICEBAR_QA_PRESERVE_OVERRIDES"] != "1",
              environment["QA_VOICEBAR_PRESERVE_TEST_OVERRIDES"] != "1",
              VoiceBarDefaults.shouldEnforceSingleton(environment: environment),
              VoiceLayerPaths.socketPath == "/tmp/voicelayer.sock",
              Bundle.main.bundleIdentifier == "com.voicelayer.voicebar" else { return nil }
        let home = NSHomeDirectory()
        let autostart = defaults.object(forKey: preferenceKey) as? Bool ?? true
        return CloneEngineController(autostart: autostart, saveAutostart: { defaults.set($0, forKey: preferenceKey) },
            probe: { CloneEngineProbe.inspect(url: URL(string: "http://127.0.0.1:8880/health")!,
                                             tokenFile: home + "/.voicelayer/daemon.secret", completion: $0) },
            makeProcess: {
                guard let config = VoiceBarDaemonLaunchConfiguration.configuration(for: executable) else {
                    throw NSError(domain: "CloneEngine", code: 1)
                }
                let script = URL(fileURLWithPath: config.workingDirectory).appendingPathComponent("src/tts_daemon.py")
                let python = home + "/.voicelayer/venv/bin/python"
                guard FileManager.default.isExecutableFile(atPath: python), FileManager.default.fileExists(atPath: script.path) else {
                    throw NSError(domain: "CloneEngine", code: 2)
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = [script.path, "--host", "127.0.0.1", "--port", "8880"]
                process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
                // Deliberately no inherited API keys, Python injection, proxy or QA configuration.
                process.environment = ["HOME": home, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                return process
            })
    }
}
