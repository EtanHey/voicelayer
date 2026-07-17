import Darwin
import Foundation

struct VoiceBarInstanceDescriptor: Equatable {
    let pid: pid_t
    let bundlePath: String?
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
            instance.pid > 0 && instance.pid != current.pid
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
