import Darwin
import Foundation

/// Caps `voicebar-err.log`. **Off by default**: it starts only when `voicebar.diagnostics.logRotation` is true.
///
/// launchd, VoiceBar and every child (daemon, recognizer, polish server) append to the log through one
/// inherited descriptor, so the file cannot be renamed away: it is copied to `.1` and then truncated in place
/// (copy-then-truncate), which every appender follows without reopening.
///
/// What is kept: every byte that was in the file when the last read before the truncate returned, and every
/// one of those bytes is synced to disk before the truncate. What can still be lost: log lines written
/// between that last read and the truncate. Recordings and transcripts are never touched.
///
/// When it runs (`isEligible`): rotation is skipped when a take, handoff, transcription or stall is in
/// progress at the moment of a check. The check is made before the copy, before the truncate and before old
/// files are deleted, and each answer is a snapshot: a take that starts after an answer, or that starts and
/// ends during the copy, is not seen, so it can overlap the truncate or the pruning. Closing that needs a
/// shared admission with the activity transitions (open: review RX-r3 P2), which is why this is parked
/// behind the defaults key.
final class ErrorLogRotator {
    struct Policy: Equatable {
        /// Rotate once the live file is at least this big.
        var maxBytes: Int = 10 * 1024 * 1024
        /// Files kept in total: the live file plus `.1` … `.(keep - 1)`.
        var keep: Int = 5
        /// The copy streams in pieces of this size, so a 113 MB first rotation holds 256 KB in memory.
        var chunkBytes: Int = 256 * 1024
    }

    enum Outcome: Equatable {
        case underCap
        /// `pruned` is false when old files were left alone because eligibility ended after the truncate.
        case rotated(copiedBytes: Int, pruned: Bool)
        /// Eligibility ended during the copy (or the owner stopped): nothing was truncated or deleted.
        case abandoned
    }

    struct RotationError: Error, Equatable {
        var step: String
        var code: Int32
    }

    /// Seams for tests. `afterFirstPass` runs after the first full copy; `sync` replaces `fsync`.
    struct Hooks {
        var afterFirstPass: (() -> Void)?
        var afterTruncate: (() -> Void)?
        var sync: (Int32) -> Int32 = { fsync($0) }
    }

    static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/voicelayer/voicebar-err.log")
    }

    /// `defaults write com.voicelayer.voicebar voicebar.diagnostics.logRotation -bool YES`, then relaunch.
    static let enabledDefaultsKey = "voicebar.diagnostics.logRotation"

    private let url: URL
    private let policy: Policy
    private let isEnabled: () -> Bool
    private let isEligible: () -> Bool
    private let appendsToLog: () -> Bool
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "VoiceBar.ErrorLogRotator", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var stopped = false
    var hooks = Hooks()

    /// `appendsToLog` defaults to "this process's stderr is an append-mode descriptor on that file": dev runs,
    /// tests and the UI fixture write stderr elsewhere and must never touch the real log, and a writer that
    /// is not in append mode would keep its old offset after a truncate and leave a hole.
    init(url: URL = ErrorLogRotator.defaultLogURL, policy: Policy = Policy(),
         isEnabled: @escaping () -> Bool = { false },
         isEligible: @escaping () -> Bool, appendsToLog: (() -> Bool)? = nil,
         log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.url = url
        self.policy = policy
        self.isEnabled = isEnabled
        self.isEligible = isEligible
        self.appendsToLog = appendsToLog ?? { ErrorLogRotator.descriptorAppends(STDERR_FILENO, to: url) }
        self.log = log
    }

    /// One check a minute after launch, then hourly, off the main thread. Does nothing at all (no timer, no
    /// look at the file) unless `isEnabled` says so when this is called.
    func start(firstCheckAfter: TimeInterval = 60, every interval: TimeInterval = 3600, leeway: TimeInterval = 30) {
        guard isEnabled() else { return }
        queue.async { [self] in
            guard timer == nil, !isStopped else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + firstCheckAfter, repeating: interval,
                           leeway: .milliseconds(max(1, Int(leeway * 1000))))
            timer.setEventHandler { [weak self] in self?.check() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Never waits for a copy in progress: that copy sees the flag at its next piece and abandons.
    func stop() {
        stateLock.lock(); stopped = true; stateLock.unlock()
        queue.async { [self] in timer?.cancel(); timer = nil }
    }

    deinit { timer?.cancel() }

    /// Tests: whether `start` installed a timer (waits for the start block to run).
    var hasTimerForTesting: Bool { queue.sync { timer != nil } }

    private var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopped }

    private func check() {
        let allowed = { [self] in !isStopped && isEligible() }
        guard allowed(), appendsToLog() else { return }
        do {
            switch try Self.rotateIfNeeded(url: url, policy: policy, isEligible: allowed,
                                           isCancelled: { [self] in isStopped }, hooks: hooks) {
            case .underCap: break
            case let .rotated(bytes, pruned):
                log("[VoiceBar] error log rotated bytes=\(bytes) keep=\(policy.keep) pruned=\(pruned)")
            case .abandoned:
                log("[VoiceBar] error log rotation deferred reason=activity")
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

    /// The highest `.N` that exists (0 when none), from the directory itself: no assumed upper bound, so a
    /// shift can never land on an archive it did not see. Throws when the directory cannot be listed.
    private static func highestArchive(_ url: URL) throws -> Int {
        let prefix = url.lastPathComponent + "."
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) }
        catch { throw RotationError(step: "list", code: Int32((error as NSError).code)) }
        return names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else { return nil }
            let suffix = name.dropFirst(prefix.count)
            guard !suffix.isEmpty, suffix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isNumber),
                  let index = Int(suffix), index >= 1, String(index) == suffix else { return nil }
            return index
        }.max() ?? 0
    }

    @discardableResult
    static func rotateIfNeeded(url: URL, policy: Policy, isEligible: () -> Bool = { true },
                               isCancelled: () -> Bool = { false }, hooks: Hooks = Hooks()) throws -> Outcome {
        precondition(policy.keep >= 2 && policy.maxBytes > 0 && policy.chunkBytes > 0)
        let live = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard live >= 0 else { throw RotationError(step: "open", code: errno) }
        defer { close(live) }
        var info = stat()
        guard fstat(live, &info) == 0 else { throw RotationError(step: "stat", code: errno) }
        guard info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) >= policy.maxBytes else { return .underCap }
        guard isEligible() else { return .abandoned }

        // Copy first, into a private temporary file. Nothing is truncated until the copy is whole and synced.
        let pending = URL(fileURLWithPath: url.path + ".rotating")
        // A copy left by a rotation that truncated but could not publish is real log: file it, never delete it.
        if access(pending.path, F_OK) == 0 { try publish(pending, as: url) }
        let copy = open(pending.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard copy >= 0 else { throw RotationError(step: "create", code: errno) }
        var truncated = false
        defer { close(copy); if !truncated { unlink(pending.path) } }

        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: policy.chunkBytes)
        /// Copies everything past `offset`. Returns nil when the owner stopped mid-copy.
        func drain() throws -> Int? {
            var moved = 0
            while true {
                if isCancelled() { return nil }
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
        guard try drain() != nil else { return .abandoned }
        hooks.afterFirstPass?()

        // Commit loop. Each round: copy what arrived, sync the copy, ask again whether rotation is allowed
        // right now (activity that began and ended during the copy is not seen), then look once more. Only a round whose last look finds nothing new may truncate, so every
        // byte about to be discarded from the live file is in the synced copy. A failed sync or a lost
        // eligibility leaves the live file untouched (the deferred unlink removes the partial copy).
        var rounds = 0
        while true {
            rounds += 1
            guard rounds <= 64 else { throw RotationError(step: "writers-too-busy", code: EBUSY) }
            guard try drain() != nil else { return .abandoned }
            guard hooks.sync(copy) == 0 else { throw RotationError(step: "sync", code: errno) }
            guard isEligible() else { return .abandoned }
            guard let late = try drain() else { return .abandoned }
            if late == 0 { break }
        }
        guard ftruncate(live, 0) == 0 else { throw RotationError(step: "truncate", code: errno) }
        truncated = true // From here the copy is the only holder of those lines: it is never unlinked.
        hooks.afterTruncate?()
        try publish(pending, as: url)
        // Deleting old files is a second destructive step: ask again (a snapshot, like every answer here).
        // Left-over files are pruned by the next rotation that is allowed to.
        let pruned = isEligible()
        if pruned { try prune(url, keep: policy.keep) }
        return .rotated(copiedBytes: Int(offset), pruned: pruned)
    }

    /// Shifts every existing archive up by one and names `pending` as `.1`. Deletes nothing and never
    /// renames onto an existing file.
    private static func publish(_ pending: URL, as url: URL) throws {
        let highest = try highestArchive(url)
        if highest >= 1 {
            for index in stride(from: highest, through: 1, by: -1) {
                // The slot above was vacated by the previous step (or is past the highest archive).
                guard access(rotatedURL(url, index + 1).path, F_OK) != 0 else {
                    throw RotationError(step: "shift-occupied", code: EEXIST)
                }
                if rename(rotatedURL(url, index).path, rotatedURL(url, index + 1).path) != 0, errno != ENOENT {
                    throw RotationError(step: "shift", code: errno)
                }
            }
        }
        guard rename(pending.path, rotatedURL(url, 1).path) == 0 else { throw RotationError(step: "publish", code: errno) }
    }

    /// Deletes archives numbered `keep` and above, oldest first.
    private static func prune(_ url: URL, keep: Int) throws {
        let highest = try highestArchive(url)
        guard highest >= keep else { return }
        for index in stride(from: highest, through: keep, by: -1) { unlink(rotatedURL(url, index).path) }
    }
}
