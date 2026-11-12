import Darwin
import Foundation

/// Caps `voicebar-err.log`. launchd, VoiceBar and every child (daemon, recognizer, polish server) append to
/// it through one inherited descriptor, so the file cannot be renamed away: it is copied to `.1` and then
/// truncated in place (copy-then-truncate), which every appender follows without reopening.
///
/// What is kept: every byte that was in the file when the last read before the truncate returned. The copy
/// re-reads the tail until two reads in a row find nothing new. What can still be lost: a write that lands
/// between that last read and the truncate, one system call later. Rotation therefore runs only while
/// VoiceBar is idle, when the writers are quiet.
final class ErrorLogRotator {
    struct Policy: Equatable {
        /// Rotate once the live file is at least this big.
        var maxBytes: Int = 10 * 1024 * 1024
        /// Files kept in total: the live file plus `.1` … `.(keep - 1)`.
        var keep: Int = 5
    }

    enum Outcome: Equatable {
        case underCap
        case rotated(copiedBytes: Int)
    }

    struct RotationError: Error, Equatable {
        var step: String
        var code: Int32
    }

    static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/voicelayer/voicebar-err.log")
    }

    private let url: URL
    private let policy: Policy
    private let isIdle: () -> Bool
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "VoiceBar.ErrorLogRotator", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(url: URL = ErrorLogRotator.defaultLogURL, policy: Policy = Policy(),
         isIdle: @escaping () -> Bool, log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.url = url
        self.policy = policy
        self.isIdle = isIdle
        self.log = log
    }

    /// One check a minute after launch, then hourly, off the main thread.
    func start(firstCheckAfter: TimeInterval = 60, every interval: TimeInterval = 3600) {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + firstCheckAfter, repeating: interval, leeway: .seconds(30))
            timer.setEventHandler { [weak self] in self?.check() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync { timer?.cancel(); timer = nil }
    }

    deinit { timer?.cancel() }

    private func check() {
        // Dev runs, tests and the UI fixture write stderr elsewhere: never touch the real log for them. An
        // appender that is not in append mode would keep its old offset after a truncate and leave a hole.
        guard isIdle(), Self.descriptorAppends(STDERR_FILENO, to: url) else { return }
        do {
            if case let .rotated(bytes) = try Self.rotateIfNeeded(url: url, policy: policy) {
                log("[VoiceBar] error log rotated bytes=\(bytes) keep=\(policy.keep)")
            }
        } catch let error as RotationError {
            log("[VoiceBar] error log rotation failed step=\(error.step) errno=\(error.code)")
        } catch {
            log("[VoiceBar] error log rotation failed step=unknown errno=0")
        }
    }

    /// True when `descriptor` is open on the file at `url` in append mode.
    static func descriptorAppends(_ descriptor: Int32, to url: URL) -> Bool {
        var open = stat(), named = stat()
        guard fstat(descriptor, &open) == 0, lstat(url.path, &named) == 0,
              named.st_mode & S_IFMT == S_IFREG,
              open.st_dev == named.st_dev, open.st_ino == named.st_ino else { return false }
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && flags & O_APPEND != 0
    }

    static func rotatedURL(_ url: URL, _ index: Int) -> URL {
        URL(fileURLWithPath: url.path + ".\(index)")
    }

    /// `afterFirstPass` is a test seam: it runs after the first full copy, before the tail re-reads.
    @discardableResult
    static func rotateIfNeeded(url: URL, policy: Policy, afterFirstPass: (() -> Void)? = nil) throws -> Outcome {
        precondition(policy.keep >= 2 && policy.maxBytes > 0)
        let live = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard live >= 0 else { throw RotationError(step: "open", code: errno) }
        defer { close(live) }
        var info = stat()
        guard fstat(live, &info) == 0 else { throw RotationError(step: "stat", code: errno) }
        guard info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) >= policy.maxBytes else { return .underCap }

        // Copy first, into a private temporary file. Nothing is truncated until the copy is whole.
        let pending = URL(fileURLWithPath: url.path + ".rotating")
        // A copy left by a rotation that truncated but could not publish is real log: file it, never delete it.
        if access(pending.path, F_OK) == 0 { try publish(pending, as: url, keep: policy.keep) }
        let copy = open(pending.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard copy >= 0 else { throw RotationError(step: "create", code: errno) }
        var truncated = false
        defer { close(copy); if !truncated { unlink(pending.path) } }

        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        func drain() throws -> Int {
            var moved = 0
            while true {
                let got = buffer.withUnsafeMutableBytes { pread(live, $0.baseAddress, $0.count, offset) }
                if got < 0 { if errno == EINTR { continue }; throw RotationError(step: "read", code: errno) }
                if got == 0 { return moved }
                var written = 0
                while written < got {
                    let put = buffer.withUnsafeBytes { write(copy, $0.baseAddress! + written, got - written) }
                    if put < 0 { if errno == EINTR { continue }; throw RotationError(step: "write", code: errno) }
                    written += put
                }
                offset += off_t(got)
                moved += got
            }
        }
        _ = try drain()
        afterFirstPass?()
        guard fsync(copy) == 0 else { throw RotationError(step: "sync", code: errno) }
        // Lines written during the copy: keep reading until two reads in a row find nothing, then truncate
        // with no work in between.
        var quiet = 0
        while quiet < 2 { quiet = try drain() == 0 ? quiet + 1 : 0 }
        guard ftruncate(live, 0) == 0 else { throw RotationError(step: "truncate", code: errno) }
        truncated = true // From here the copy is the only holder of those lines: it is never unlinked.
        try publish(pending, as: url, keep: policy.keep)
        return .rotated(copiedBytes: Int(offset))
    }

    /// Drops the oldest file, shifts `.1 … .(keep - 2)` up by one and names `pending` as `.1`.
    private static func publish(_ pending: URL, as url: URL, keep: Int) throws {
        unlink(rotatedURL(url, keep - 1).path)
        if keep > 2 {
            for index in stride(from: keep - 2, through: 1, by: -1) {
                if rename(rotatedURL(url, index).path, rotatedURL(url, index + 1).path) != 0, errno != ENOENT {
                    throw RotationError(step: "shift", code: errno)
                }
            }
        }
        guard rename(pending.path, rotatedURL(url, 1).path) == 0 else { throw RotationError(step: "publish", code: errno) }
    }
}
