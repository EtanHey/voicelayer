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
            XCTAssertEqual(try ErrorLogRotator.rotateIfNeeded(url: log, policy: policy), .rotated(copiedBytes: 54))
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
        let outcome = try ErrorLogRotator.rotateIfNeeded(url: log, policy: .init(maxBytes: 100, keep: 5)) {
            self.put(fd, "during 1\n"); self.put(fd, "during 2\n")
        }
        XCTAssertEqual(outcome, .rotated(copiedBytes: 20 * 7 + 18))
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
        XCTAssertEqual(try ErrorLogRotator.rotateIfNeeded(url: log, policy: .init(maxBytes: 40, keep: 4)), .rotated(copiedBytes: 81))
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

    func testTheTimerRotatesOnlyWhileIdle() throws {
        // The timer path needs stderr on the log; that gate is covered above. Here: the idle gate and policy defaults.
        XCTAssertEqual(ErrorLogRotator.Policy(), .init(maxBytes: 10 * 1024 * 1024, keep: 5))
        XCTAssertEqual(ErrorLogRotator.defaultLogURL.path.hasSuffix("Library/Logs/voicelayer/voicebar-err.log"), true)
        let board = RuntimePhaseBoard()
        XCTAssertTrue(board.isIdle)
        board.setMode("transcribing")
        XCTAssertFalse(board.isIdle)
    }
}
