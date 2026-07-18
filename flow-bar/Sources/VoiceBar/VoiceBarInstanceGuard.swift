import Darwin
import Foundation

struct VoiceBarInstanceDescriptor: Equatable {
    let pid: pid_t
    let bundlePath: String?
    let isIsolated: Bool

    init(pid: pid_t, bundlePath: String?, isIsolated: Bool = false) {
        self.pid = pid
        self.bundlePath = bundlePath
        self.isIsolated = isIsolated
    }
}

enum VoiceBarInstanceDecision: Equatable {
    case bypass
    case exitCurrent(canonicalPID: pid_t)
    case supersede([pid_t])
}

enum VoiceBarInstanceGuard {
    static let canonicalBundlePath = "/Applications/VoiceBar.app"

    static func plan(
        current: VoiceBarInstanceDescriptor,
        running: [VoiceBarInstanceDescriptor],
        canonicalBundlePath: String = canonicalBundlePath,
        enforcesSingleton: Bool
    ) -> VoiceBarInstanceDecision {
        guard enforcesSingleton else { return .bypass }

        let canonicalPath = normalizedPath(canonicalBundlePath)
        let currentPath = current.bundlePath.map(normalizedPath)
        let otherInstances = running.filter { instance in
            instance.pid > 0 && instance.pid != current.pid && !instance.isIsolated
        }

        if currentPath != canonicalPath,
           let canonicalPID = otherInstances
           .filter({ $0.bundlePath.map(normalizedPath) == canonicalPath })
           .map(\.pid)
           .min() {
            return .exitCurrent(canonicalPID: canonicalPID)
        }

        let exactPIDs = Array(Set(otherInstances.map(\.pid))).sorted()
        return .supersede(exactPIDs)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

enum VoiceBarInstanceIsolationRegistryError: Error {
    case launchDateUnavailable(pid: pid_t)
}

enum VoiceBarInstanceIsolationRegistry {
    private struct Marker: Codable {
        let pid: Int32
        let launchTimeMilliseconds: Int64
        let socketPath: String
    }

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceLayer")
        .appendingPathComponent("isolated-voicebar-instances", isDirectory: true)

    static func register(
        pid: pid_t,
        launchDate: Date,
        socketPath: String,
        directory: URL = defaultDirectory
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = Marker(
            pid: pid,
            launchTimeMilliseconds: launchTimeMilliseconds(launchDate),
            socketPath: socketPath
        )
        let url = markerURL(pid: pid, directory: directory)
        try JSONEncoder().encode(marker).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func isRegistered(
        pid: pid_t,
        launchDate: Date?,
        directory: URL = defaultDirectory
    ) -> Bool {
        guard let launchDate,
              let data = try? Data(contentsOf: markerURL(pid: pid, directory: directory)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data)
        else { return false }
        return marker.pid == pid &&
            marker.launchTimeMilliseconds == launchTimeMilliseconds(launchDate)
    }

    static func unregister(
        pid: pid_t,
        directory: URL = defaultDirectory
    ) {
        try? FileManager.default.removeItem(at: markerURL(pid: pid, directory: directory))
    }

    private static func markerURL(pid: pid_t, directory: URL) -> URL {
        directory.appendingPathComponent("\(pid).json", isDirectory: false)
    }

    private static func launchTimeMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

enum VoiceBarInstanceElectionLockError: Error {
    case openFailed(path: String, errno: Int32)
    case lockFailed(path: String, errno: Int32)
}

enum VoiceBarInstanceElectionLock {
    static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceLayer")
        .appendingPathComponent("voicebar-instance-election.lock")
        .path

    static func withExclusiveLock<T>(
        atPath path: String = defaultPath,
        _ body: () throws -> T
    ) throws -> T {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw VoiceBarInstanceElectionLockError.openFailed(path: path, errno: errno)
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw VoiceBarInstanceElectionLockError.lockFailed(path: path, errno: errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
