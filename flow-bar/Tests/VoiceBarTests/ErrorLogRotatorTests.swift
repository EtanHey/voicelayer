import XCTest
@testable import VoiceBar

/// c8 X: voicebar-err.log is capped by copy-then-truncate. Small caps here; the app uses 10 MB and 5 files.
final class ErrorLogRotatorTests: XCTestCase {
    private var directory: URL!
    private var log: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-logrotate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = directory.appendingPathComponent("voicebar-err.log")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// The way launchd and every child write: one descriptor, append mode.
    private func appender() -> Int32 {
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        return fd
    }

    private func put(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        XCTAssertEqual(write(fd, bytes, bytes.count), bytes.count)
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func testUnderTheCapNothingMoves() throws {
        let fd = appender(); defer { close(fd) }
        put(fd, "one\n")
        XCTAssertEqual(try ErrorLogRotator.rotateIfNeeded(url: log, policy: .init(maxBytes: 64, keep: 3)), .underCap)
        XCTAssertEqual(files(), ["voicebar-err.log"])
        XCTAssertEqual(read(log), "one\n")
    }

    func testOverTheCapKeepsExactlyNFilesNewestFirstAndPrivate() throws {
        let fd = appender(); defer { close(fd) }
        let policy = ErrorLogRotator.Policy(maxBytes: 40, keep: 3)
        for generation in 1...5 {
            put(fd, "generation \(generation) " + String(repeating: "x", count: 40) + "\n")
            XCTAssertEqual(try ErrorLogRotator.rotateIfNeeded(url: log, policy: policy), .rotated(copiedBytes: 54, pruned: true))
            XCTAssertEqual(read(log), "", "the live file is emptied in place")
        }
        put(fd, "after\n")
        XCTAssertEqual(read(log), "after\n", "an append-mode writer continues at the start, with no hole")
        XCTAssertEqual(files(), ["voicebar-err.log", "voicebar-err.log.1", "voicebar-err.log.2"], "live + keep-1 files")
        XCTAssertTrue(read(ErrorLogRotator.rotatedURL(log, 1)).hasPrefix("generation 5 "))
        XCTAssertTrue(read(ErrorLogRotator.rotatedURL(log, 2)).hasPrefix("generation 4 "))
        for name in files() {
            let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, name)
        }
    }

    /// Lines written while the copy is running land in the rotated file: the tail is re-read before the truncate.
    func testLinesWrittenDuringTheCopyAreKept() throws {
        let fd = appender(); defer { close(fd) }
        put(fd, String(repeating: "before\n", count: 20))
        var hooks = ErrorLogRotator.Hooks()
        hooks.afterFirstPass = { self.put(fd, "during 1\n"); self.put(fd, "during 2\n") }
        let outcome = try ErrorLogRotator.rotateIfNeeded(url: log, policy: .init(maxBytes: 100, keep: 5), hooks: hooks)
        XCTAssertEqual(outcome, .rotated(copiedBytes: 20 * 7 + 18, pruned: true))
        XCTAssertEqual(read(ErrorLogRotator.rotatedURL(log, 1)), String(repeating: "before\n", count: 20) + "during 1\nduring 2\n")
        XCTAssertEqual(read(log), "")
    }

    /// A writer that never stops, through 30 rotations. Every line is whole and appears once, in order.
    /// Copy-then-truncate has one honest gap (a write between the last read and the truncate); the count of
    /// lines lost there is printed and bounded, never asserted away.
    func testAWriterThatNeverStopsLosesNothingOutsideTheTruncateGap() throws {
        let fd = appender(); defer { close(fd) }
        let policy = ErrorLogRotator.Policy(maxBytes: 4_096, keep: 200)
        let lock = NSLock()
        var stop = false, written = 0
        let finished = DispatchSemaphore(value: 0)
        let writer = Thread {
            var n = 0
            while true {
                lock.lock(); let done = stop; lock.unlock()
                if done { break }
                n += 1
                self.put(fd, "line \(n) " + String(repeating: "y", count: n % 40) + "\n")
                if n % 50 == 0 { usleep(200) }
            }
            lock.lock(); written = n; lock.unlock()
            finished.signal()
        }
        writer.start()
        var rotations = 0
        let deadline = Date().addingTimeInterval(20)
        while rotations < 30, Date() < deadline {
            if case .rotated = try ErrorLogRotator.rotateIfNeeded(url: log, policy: policy) { rotations += 1 }
        }
        lock.lock(); stop = true; lock.unlock()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(rotations, 30)
        var text = ""
        for index in stride(from: rotations, through: 1, by: -1) { text += read(ErrorLogRotator.rotatedURL(log, index)) }
        text += read(log)
        XCTAssertTrue(text.hasSuffix("\n"))
        var previous = 0, lost = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "line", let n = Int(parts[1]),
                  parts[2] == Substring(String(repeating: "y", count: n % 40)) else {
                return XCTFail("torn line: \(line)")
            }
            XCTAssertGreaterThan(n, previous, "duplicated or reordered line \(n)")
            lost += n - previous - 1
            previous = n
        }
        lost += written - previous
        print("LOG_ROTATION_STRESS written=\(written) rotations=\(rotations) lost_lines=\(lost)")
        XCTAssertLessThanOrEqual(lost, rotations, "more than the truncate gap can explain")
    }

    /// A copy left behind by a rotation that truncated but could not publish is filed as `.1`, never deleted.
    func testALeftoverCopyIsFiledNotDeleted() throws {
        let fd = appender(); defer { close(fd) }
        try "orphaned lines\n".write(to: URL(fileURLWithPath: log.path + ".rotating"), atomically: false, encoding: .utf8)
        put(fd, String(repeating: "z", count: 80) + "\n")
        XCTAssertEqual(try ErrorLogRotator.rotateIfNeeded(url: log, policy: .init(maxBytes: 40, keep: 4)), .rotated(copiedBytes: 81, pruned: true))
        XCTAssertEqual(read(ErrorLogRotator.rotatedURL(log, 2)), "orphaned lines\n")
        XCTAssertEqual(files(), ["voicebar-err.log", "voicebar-err.log.1", "voicebar-err.log.2"])
    }

    /// The app rotates only the file its own stderr appends to: a dev run, a test or the UI fixture never does.
    func testOnlyAnAppendDescriptorOnThatFileQualifies() throws {
        let fd = appender(); defer { close(fd) }
        XCTAssertTrue(ErrorLogRotator.descriptorAppends(fd, to: log))
        XCTAssertFalse(ErrorLogRotator.descriptorAppends(STDERR_FILENO, to: log), "the test runner's stderr is another file")
        let plain = open(log.path, O_WRONLY); defer { close(plain) }
        XCTAssertFalse(ErrorLogRotator.descriptorAppends(plain, to: log), "no append flag: a truncate would leave a hole")
        let link = directory.appendingPathComponent("link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: log)
        XCTAssertFalse(ErrorLogRotator.descriptorAppends(fd, to: link))
        XCTAssertFalse(ErrorLogRotator.descriptorAppends(fd, to: directory.appendingPathComponent("missing.log")))
    }

    /// A small flag two threads share.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
    }

    /// Review r2 P2-1: a take that begins during the copy stops the rotation before anything is destroyed.
    func testActivityThatBeginsDuringTheCopyLeavesTheLiveLogUntouched() throws {
        let fd = appender(); defer { close(fd) }
        let original = String(repeating: "kept\n", count: 40)
        put(fd, original)
        try "older\n".write(to: ErrorLogRotator.rotatedURL(log, 1), atomically: false, encoding: .utf8)
        let eligible = Flag(true)
        var hooks = ErrorLogRotator.Hooks()
        hooks.afterFirstPass = { eligible.value = false; self.put(fd, "take started\n") }
        let outcome = try ErrorLogRotator.rotateIfNeeded(url: log, policy: .init(maxBytes: 100, keep: 2),
                                                         isEligible: { eligible.value }, hooks: hooks)
        XCTAssertEqual(outcome, .abandoned)
        XCTAssertEqual(read(log), original + "take started\n", "the live log is not truncated")
        XCTAssertEqual(files(), ["voicebar-err.log", "voicebar-err.log.1"], "the partial copy is removed, nothing is pruned")
        XCTAssertEqual(read(ErrorLogRotator.rotatedURL(log, 1)), "older\n")
    }

    /// A stall that is outstanding from the start: no copy, no truncate, no pruning, however many times the
    /// timer fires and however full the log gets. The archive holding the hang's first line survives.
    func testAnOutstandingStallBlocksRotationAndKeepsItsArchive() throws {
        let fd = appender(); defer { close(fd) }
        let stall = "[VoiceBar][responsiveness] loop=main state=stalled elapsed_ms=2121 pid=1\n"
        try stall.write(to: ErrorLogRotator.rotatedURL(log, 2), atomically: false, encoding: .utf8)
        try "newer\n".write(to: ErrorLogRotator.rotatedURL(log, 1), atomically: false, encoding: .utf8)
        let policy = ErrorLogRotator.Policy(maxBytes: 64, keep: 3) // .2 is the oldest kept file: next in line to go
        for round in 1...6 {
            put(fd, String(repeating: "noise during the hang\n", count: 10))
            XCTAssertEqual(try ErrorLogRotator.rotateIfNeeded(url: log, policy: policy, isEligible: { false }), .abandoned, "round \(round)")
        }
        XCTAssertEqual(read(ErrorLogRotator.rotatedURL(log, 2)), stall)
        XCTAssertEqual(read(log).count, 6 * 10 * 22)
        XCTAssertEqual(files(), ["voicebar-err.log", "voicebar-err.log.1", "voicebar-err.log.2"])
    }

    /// A stall that begins after the truncate: the fresh copy is still filed, but nothing old is deleted, so
    /// the oldest archive outlives the policy until a later rotation is allowed to prune.
    func testAStallThatBeginsAfterTheTruncateStopsThePruning() throws {
        let fd = appender(); defer { close(fd) }
        let policy = ErrorLogRotator.Policy(maxBytes: 20, keep: 2)
        try "oldest\n".write(to: ErrorLogRotator.rotatedURL(log, 1), atomically: false, encoding: .utf8)
        put(fd, String(repeating: "a", count: 30) + "\n")
        let eligible = Flag(true)
        var hooks = ErrorLogRotator.Hooks()
        hooks.afterTruncate = { eligible.value = false }
        XCTAssertEqual(try ErrorLogRotator.rotateIfNeeded(url: log, policy: policy, isEligible: { eligible.value }, hooks: hooks),
                       .rotated(copiedBytes: 31, pruned: false))
        XCTAssertEqual(read(ErrorLogRotator.rotatedURL(log, 2)), "oldest\n", "over the policy, and still there")
        eligible.value = true
        put(fd, String(repeating: "b", count: 30) + "\n")
        XCTAssertEqual(try ErrorLogRotator.rotateIfNeeded(url: log, policy: policy, isEligible: { eligible.value }),
                       .rotated(copiedBytes: 31, pruned: true))
        XCTAssertEqual(files(), ["voicebar-err.log", "voicebar-err.log.1"], "the next allowed rotation prunes back to the policy")
        XCTAssertTrue(read(ErrorLogRotator.rotatedURL(log, 1)).hasPrefix("b"))
    }

    /// Review r2 P2-2: bytes copied after an earlier sync are synced again before the truncate, and a sync
    /// that fails late leaves the live file whole.
    func testALateSyncFailureLeavesTheLiveFileIntact() throws {
        let fd = appender(); defer { close(fd) }
        put(fd, String(repeating: "first\n", count: 30))
        var syncs = 0
        var hooks = ErrorLogRotator.Hooks()
        // A line arrives while the first sync is running; the sync that would cover it fails.
        hooks.sync = { descriptor in
            syncs += 1
            if syncs == 1 { self.put(fd, "arrived during the first sync\n"); return fsync(descriptor) }
            errno = EIO; return -1
        }
        XCTAssertThrowsError(try ErrorLogRotator.rotateIfNeeded(url: log, policy: .init(maxBytes: 100, keep: 3), hooks: hooks)) {
            XCTAssertEqual($0 as? ErrorLogRotator.RotationError, .init(step: "sync", code: EIO))
        }
        XCTAssertEqual(syncs, 2, "the late tail got its own sync")
        XCTAssertEqual(read(log), String(repeating: "first\n", count: 30) + "arrived during the first sync\n")
        XCTAssertEqual(files(), ["voicebar-err.log"], "no truncate, no partial copy left behind")
        // With working syncs the same sequence commits, and every sync precedes the truncate.
        syncs = 0
        hooks.sync = { descriptor in
            syncs += 1
            if syncs == 1 { self.put(fd, "second arrival\n") }
            XCTAssertGreaterThan(self.read(self.log).count, 0, "sync ran before the truncate")
            return fsync(descriptor)
        }
        XCTAssertEqual(try ErrorLogRotator.rotateIfNeeded(url: log, policy: .init(maxBytes: 100, keep: 3), hooks: hooks),
                       .rotated(copiedBytes: 30 * 6 + 30 + 15, pruned: true))
        XCTAssertEqual(syncs, 2)
        XCTAssertTrue(read(ErrorLogRotator.rotatedURL(log, 1)).hasSuffix("second arrival\n"))
    }

    /// The first rotation on a Mac that has years of log: a file far larger than the cap is streamed in
    /// pieces (here 64-byte pieces of a 100 KB file) and archived whole.
    func testAnOversizedFirstRotationIsStreamedAndArchivedWhole() throws {
        let fd = appender(); defer { close(fd) }
        var expected = ""
        for n in 0..<2_000 { expected += "historic line \(n) " + String(repeating: "h", count: 30) + "\n" }
        put(fd, expected)
        let policy = ErrorLogRotator.Policy(maxBytes: 1_024, keep: 5, chunkBytes: 64)
        XCTAssertEqual(try ErrorLogRotator.rotateIfNeeded(url: log, policy: policy),
                       .rotated(copiedBytes: expected.utf8.count, pruned: true))
        XCTAssertEqual(read(ErrorLogRotator.rotatedURL(log, 1)), expected)
        XCTAssertEqual(read(log), "")
        XCTAssertEqual(ErrorLogRotator.Policy().chunkBytes, 256 * 1024, "what a 113 MB rotation holds in memory")
        XCTAssertEqual(ErrorLogRotator.Policy(), .init(maxBytes: 10 * 1024 * 1024, keep: 5, chunkBytes: 256 * 1024))
    }

    /// The real timer, while eligibility changes under it: nothing rotates while a take or stall is live,
    /// the first tick after it clears rotates, and a take that starts mid-copy defers that tick.
    func testTheTimerRotatesOnlyWhileEligible() throws {
        let fd = appender(); defer { close(fd) }
        put(fd, String(repeating: "x", count: 200) + "\n")
        let eligible = Flag(false)
        let lock = NSLock()
        var lines: [String] = []
        var asked = 0
        let rotator = ErrorLogRotator(url: log, policy: .init(maxBytes: 64, keep: 3),
                                      isEligible: { lock.lock(); asked += 1; lock.unlock(); return eligible.value },
                                      appendsToLog: { ErrorLogRotator.descriptorAppends(fd, to: self.log) },
                                      log: { line in lock.lock(); lines.append(line); lock.unlock() })
        func logged() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
        func wait(_ what: String, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !done(), Date() < deadline { usleep(10_000) }
            XCTAssertTrue(done(), what)
        }
        rotator.start(firstCheckAfter: 0.02, every: 0.02, leeway: 0.001)
        defer { rotator.stop() }
        wait("the timer asked several times while busy") { lock.lock(); defer { lock.unlock() }; return asked >= 5 }
        XCTAssertEqual(read(log).count, 201, "busy: the timer fired and did nothing")
        XCTAssertEqual(logged(), [])
        XCTAssertEqual(files(), ["voicebar-err.log"])

        // A take begins during the copy of the first allowed tick: that tick is deferred, the log is whole.
        rotator.hooks.afterFirstPass = { eligible.value = false }
        eligible.value = true
        wait("a deferred tick is reported") { logged().contains("[VoiceBar] error log rotation deferred reason=activity") }
        XCTAssertEqual(read(log).count, 201)
        XCTAssertEqual(files(), ["voicebar-err.log"])

        rotator.hooks.afterFirstPass = nil
        eligible.value = true
        wait("the next eligible tick rotates") { logged().contains { $0.hasPrefix("[VoiceBar] error log rotated bytes=201 keep=3 pruned=true") } }
        XCTAssertEqual(read(log), "")
        XCTAssertEqual(read(ErrorLogRotator.rotatedURL(log, 1)).count, 201)

        // Stopped: later ticks never run, even over the cap and eligible.
        rotator.stop()
        usleep(60_000)
        put(fd, String(repeating: "y", count: 300) + "\n")
        usleep(150_000)
        XCTAssertEqual(read(log).count, 301)
    }
}
