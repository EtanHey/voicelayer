import AppKit
import XCTest
import os
import StallSampler
@testable import VoiceBar
import VoiceBarUI

/// A flag two threads share in the stress test.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

final class RuntimeResponsivenessTests: XCTestCase {
    func testBlockedLoopHasOneProbeAndBoundedReceiptsThenDispatchResumes() {
        let blocked = DispatchQueue(label: "watchdog.test.loop")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        blocked.async { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        defer { release.signal() }
        let stalled = expectation(description: "off-loop receipt during stall")
        let recovered = expectation(description: "loop resumed")
        let lock = NSLock()
        var probes = 0
        var receipts: [String] = []
        let watchdog = RuntimeResponsivenessWatchdog(loop: "fixture", threshold: 0.03, enqueue: { ack in
            lock.lock(); probes += 1; lock.unlock()
            blocked.async(execute: ack)
        }, sink: { line in
            lock.lock(); receipts.append(line); lock.unlock()
            if line.contains("state=stalled") { stalled.fulfill() }
            if line.contains("state=recovered") { recovered.fulfill() }
        })
        XCTAssertFalse(watchdog.isStallOutstanding)
        watchdog.start(interval: 0.01)
        wait(for: [stalled], timeout: 3)
        XCTAssertTrue(watchdog.isStallOutstanding, "the log rotator reads this to stay away from a hang in progress")
        lock.lock()
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(receipts.count, 1)
        lock.unlock()
        release.signal()
        wait(for: [recovered], timeout: 3)
        XCTAssertFalse(watchdog.isStallOutstanding)
        watchdog.stop()
        let dispatched = expectation(description: "ordinary work retained")
        blocked.async { dispatched.fulfill() }
        wait(for: [dispatched], timeout: 2)
        lock.lock()
        XCTAssertEqual(receipts.count, 2)
        XCTAssertTrue(receipts.allSatisfy { $0.hasPrefix("[VoiceBar][responsiveness] loop=fixture state=") })
        lock.unlock()
    }

    func testActualMainRunLoopStallIsObservedOffMain() {
        XCTAssertTrue(Thread.isMainThread)
        let stalled = DispatchSemaphore(value: 0)
        let recovered = expectation(description: "main recovered")
        let loop = CFRunLoopGetMain()!
        let watchdog = RuntimeResponsivenessWatchdog(loop: "main", threshold: 0.03, enqueue: { ack in
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { ack.perform() }
            CFRunLoopWakeUp(loop)
        }, sink: { line in
            if line.contains("state=stalled") { stalled.signal() }
            if line.contains("state=recovered") { recovered.fulfill() }
        })
        watchdog.start(interval: 0.01)
        XCTAssertEqual(stalled.wait(timeout: .now() + 3), .success)
        wait(for: [recovered], timeout: 3)
        watchdog.stop()
    }

    /// c8 X (2026-11-11 hang): the app's own settings must report a main stall well under the old 2 s line,
    /// with the phase, so the next occurrence names what the app was doing.
    func testAppThresholdReportsASubSecondMainStallWithItsPhase() {
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertLessThanOrEqual(AppDelegate.mainStallThreshold, 0.5)
        XCTAssertLessThanOrEqual(AppDelegate.mainStallProbeInterval, AppDelegate.mainStallThreshold / 2)
        XCTAssertGreaterThanOrEqual(AppDelegate.mainStallProbeInterval, 0.25, "no more than 4 wakeups a second")
        let board = RuntimePhaseBoard(uptime: { 1_000 }, thermal: { .fair })
        board.setMode("transcribing")
        board.noteSurfaceTransition(line: "[VoiceBar] notch surface closed -> settings(general) (open settings general)")
        let lock = NSLock()
        var receipts: [String] = []
        let recovered = expectation(description: "main recovered")
        let loop = CFRunLoopGetMain()!
        let watchdog = RuntimeResponsivenessWatchdog(
            loop: "main", threshold: AppDelegate.mainStallThreshold, context: { board.snapshot() },
            phaseKey: { board.phaseKey() }, quietPeriod: AppDelegate.mainStallQuietPeriod,
            enqueue: { ack in
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { ack.perform() }
                CFRunLoopWakeUp(loop)
            }, sink: { line in
                lock.lock(); receipts.append(line); lock.unlock()
                if line.contains("state=recovered") { recovered.fulfill() }
            })
        watchdog.start(interval: AppDelegate.mainStallProbeInterval, leeway: AppDelegate.mainStallProbeLeeway)
        // Let one probe round-trip, then hold the main thread the way a slow layout pass does.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        Thread.sleep(forTimeInterval: 1.2)
        wait(for: [recovered], timeout: 3)
        watchdog.stop()
        lock.lock(); let lines = receipts; lock.unlock()
        XCTAssertEqual(lines.filter { $0.contains("state=stalled") }.count, 1, "\(lines)")
        for line in lines {
            XCTAssertTrue(line.hasSuffix(" phase=transcribing/settings(general) mem_pressure=none thermal=fair"), line)
        }
        let elapsed = lines.last.flatMap { line -> Int? in
            line.split(separator: " ").first { $0.hasPrefix("elapsed_ms=") }.flatMap { Int($0.dropFirst(11)) }
        }
        XCTAssertGreaterThanOrEqual(elapsed ?? 0, 500)
        XCTAssertLessThan(elapsed ?? .max, 2_000, "a stall the old 2 s threshold never reported")
    }

    /// Review P2: the board is published at the START of a mode transition. Hold the transition's first real
    /// dependency (the microphone-priority apply) and read the board from another thread while it is held.
    func testModeTransitionPublishesItsPhaseBeforeItsFirstBlockingDependency() {
        XCTAssertTrue(Thread.isMainThread)
        _ = NSApplication.shared // the transition's diagnostics read NSApp
        let delegate = AppDelegate()
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var entered = false
        delegate.microphonePriorityApply = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: {
                guard entered else { return nil } // The arming call below must not block.
                held.signal(); release.wait(); return nil
            },
            applyDeviceID: { _ in true })
        delegate.microphonePriorityApply.requestApply(mode: .recording, captureLive: true) // pending, nothing resolved
        RuntimePhaseBoard.shared.setMode("recording")
        defer { RuntimePhaseBoard.shared.setMode("idle") }
        entered = true
        var seen: String?
        let reader = Thread {
            XCTAssertEqual(held.wait(timeout: .now() + 5), .success, "the transition never reached its dependency")
            seen = RuntimePhaseBoard.shared.phaseKey()
            release.signal()
        }
        reader.start()
        delegate.handleVoiceModeChangeForTesting(.idle) // blocks in resolveDeviceID until the reader has looked
        XCTAssertEqual(seen?.split(separator: "/").first.map(String.init), "idle",
                       "a stall inside the transition would have been logged with the previous mode")
    }

    /// One stalled/recovered pair per quiet period in an unchanged phase; the next logged stall says how many
    /// were skipped; a new phase and a long stall are always logged.
    func testRepeatedHitchesInOnePhaseAreCountedNotLogged() {
        let blocked = DispatchQueue(label: "watchdog.test.ratelimit")
        let lock = NSLock()
        var receipts: [String] = []
        var phase = "recording/closed"
        let watchdog = RuntimeResponsivenessWatchdog(
            loop: "fixture", threshold: 0.03,
            phaseKey: { lock.lock(); defer { lock.unlock() }; return phase },
            quietPeriod: 30, alwaysReportAfter: 0.6,
            enqueue: { ack in blocked.async(execute: ack) },
            sink: { line in lock.lock(); receipts.append(line); lock.unlock() })
        watchdog.start(interval: 0.01)
        func hitch(_ seconds: TimeInterval) {
            let done = DispatchSemaphore(value: 0)
            blocked.async { Thread.sleep(forTimeInterval: seconds); done.signal() }
            done.wait()
            Thread.sleep(forTimeInterval: 0.08) // let the acknowledgement land
        }
        func lines() -> [String] { lock.lock(); defer { lock.unlock() }; return receipts }
        hitch(0.15)
        XCTAssertEqual(lines().count, 2, "first hitch is logged: \(lines())")
        hitch(0.15); hitch(0.15); hitch(0.15)
        XCTAssertEqual(lines().count, 2, "same phase inside the quiet period: counted, not logged")
        lock.lock(); phase = "transcribing/closed"; lock.unlock()
        hitch(0.15)
        XCTAssertEqual(lines().count, 4, "a new phase is logged at once")
        XCTAssertTrue(lines()[2].hasSuffix(" suppressed=3"), lines()[2])
        hitch(0.15)
        XCTAssertEqual(lines().count, 4)
        hitch(0.9)
        watchdog.stop()
        let all = lines()
        XCTAssertEqual(all.count, 6, "a stall past alwaysReportAfter is never hidden: \(all)")
        XCTAssertTrue(all[4].contains("state=stalled") && all[4].hasSuffix(" suppressed=1"), all[4])
        XCTAssertTrue(all[5].contains("state=recovered"))
    }

    @inline(never) private func c8xHoldMainThread(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    /// A stall past `stackAfter` logs the stuck thread's stack once: where it was, as function names.
    func testLongMainStallLogsItsStackOnce() {
        XCTAssertTrue(Thread.isMainThread)
        let mainThread = StalledThreadStack.currentThreadPort()
        XCTAssertEqual(StalledThreadStack.sample(mainThread), .init(addresses: [], resumeFailure: nil),
                       "a thread never suspends itself")
        let lock = NSLock()
        var receipts: [String] = []
        let recovered = expectation(description: "main recovered")
        let loop = CFRunLoopGetMain()!
        let watchdog = RuntimeResponsivenessWatchdog(
            loop: "main", threshold: 0.05, stackAfter: 0.2,
            stack: { StalledThreadStack.describe(StalledThreadStack.sample(mainThread).addresses) },
            enqueue: { ack in
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { ack.perform() }
                CFRunLoopWakeUp(loop)
            }, sink: { line in
                lock.lock(); receipts.append(line); lock.unlock()
                if line.contains("state=recovered") { recovered.fulfill() }
            })
        watchdog.start(interval: 0.02)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        c8xHoldMainThread(seconds: 0.8)
        wait(for: [recovered], timeout: 3)
        watchdog.stop()
        lock.lock(); let lines = receipts; lock.unlock()
        let stacks = lines.filter { $0.contains("state=stack") }
        XCTAssertEqual(stacks.count, 1, "\(lines)")
        let frames = stacks.first?.components(separatedBy: "frames=").last?.components(separatedBy: " < ") ?? []
        XCTAssertGreaterThanOrEqual(frames.count, 4, "\(frames)")
        XCTAssertTrue(frames.contains { $0.contains("c8xHoldMainThread") }, "the stack names the function that held the loop: \(frames)")
        XCTAssertEqual(lines.map { $0.contains("state=stalled") ? "stalled" : $0.contains("state=stack") ? "stack" : "recovered" },
                       ["stalled", "stack", "recovered"])
    }

    /// Stack capture is off unless the diagnostics key is set, and a failed resume is logged.
    func testStackCaptureIsOffUntilTheDiagnosticsKeyIsSet() throws {
        let suite = "vl-ui-stall-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        var port: thread_act_t = 0
        let parked = Thread { port = StalledThreadStack.currentThreadPort(); ready.signal(); done.wait() }
        parked.start(); ready.wait()
        defer { done.signal() }
        XCTAssertEqual(StalledThreadStack.frames(of: port, defaults: defaults), [], "off by default")
        defaults.set(true, forKey: StalledThreadStack.enabledDefaultsKey)
        XCTAssertEqual(StalledThreadStack.enabledDefaultsKey, "voicebar.diagnostics.stallStacks")
        XCTAssertGreaterThanOrEqual(StalledThreadStack.frames(of: port, defaults: defaults).count, 2)
        var logged: [String] = []
        XCTAssertEqual(StalledThreadStack.frames(of: mach_port_t(MACH_PORT_NULL), defaults: defaults) { logged.append($0) }, [])
        XCTAssertEqual(logged, [], "a thread that was never suspended has no resume to fail")
    }

    /// Review P3: a frame with no symbol keeps an address that can be symbolicated against that build.
    func testFrameWithoutASymbolKeepsItsImageRelativeAddress() {
        let table: [UInt: StalledThreadStack.Location] = [
            0x1_0000_4a2c: .init(image: "VoiceBar", imageBase: 0x1_0000_0000, symbol: nil, symbolBase: nil),
            0x1_0000_5000: .init(image: "VoiceBar", imageBase: 0x1_0000_0000, symbol: "$s8VoiceBar3fooyyF", symbolBase: 0x1_0000_4ff0),
            0x2_0000_0010: .init(image: "AppKit", imageBase: nil, symbol: nil, symbolBase: nil),
        ]
        XCTAssertEqual(StalledThreadStack.describe([0x1_0000_4a2c, 0x1_0000_5000, 0x2_0000_0010, 0xdead], lookup: { table[$0] }),
                       ["VoiceBar+0x4a2c", "VoiceBar:$s8VoiceBar3fooyyF+16", "AppKit@0x200000010", "0xdead"])
        // The real lookup: an address inside this test binary resolves to a basename, never a path.
        let real = StalledThreadStack.describe([UInt(bitPattern: dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc"))])
        XCTAssertEqual(real.count, 1)
        XCTAssertFalse(real[0].contains("/"), real[0])
        XCTAssertTrue(real[0].contains("malloc"), real[0])
    }

    /// Lead ruling 2c: 2,000 captures of a thread that is hammering malloc/free and locks must never
    /// deadlock. The sampled thread holds the allocator's lock for much of its life; anything that allocated
    /// or locked while it is stopped would hang here, and the deadline below turns that into a failure.
    func testTwoThousandCapturesOfAnAllocatingThreadNeverDeadlock() {
        let ready = DispatchSemaphore(value: 0)
        let stop = ManagedAtomicFlag()
        var port: thread_act_t = 0
        let shared = DispatchQueue(label: "vl.stall.stress.shared")
        var unfair = os_unfair_lock()
        let hammer = Thread {
            port = StalledThreadStack.currentThreadPort()
            ready.signal()
            var bag: [UnsafeMutableRawPointer] = []
            var n = 0
            while !stop.isSet {
                n &+= 1
                bag.append(malloc(16 + (n % 2048))!)
                if bag.count > 64 { for pointer in bag { free(pointer) }; bag.removeAll(keepingCapacity: n % 3 == 0) }
                os_unfair_lock_lock(&unfair); os_unfair_lock_unlock(&unfair)
                shared.sync { _ = String(repeating: "x", count: n % 97).count }
                _ = NSString(format: "%d", n)
            }
            for pointer in bag { free(pointer) }
        }
        hammer.start(); ready.wait()
        let finished = DispatchSemaphore(value: 0)
        var captures = 0, nonEmpty = 0, resumeFailures = 0
        let sampler = Thread {
            for _ in 0..<2_000 {
                // The sampler allocates and takes the same locks between captures, as the watchdog does.
                let sample = StalledThreadStack.sample(port)
                captures += 1
                if !sample.addresses.isEmpty { nonEmpty += 1 }
                if sample.resumeFailure != nil { resumeFailures += 1 }
                shared.sync { _ = StalledThreadStack.describe(Array(sample.addresses.prefix(2))) }
            }
            finished.signal()
        }
        sampler.start()
        let outcome = finished.wait(timeout: .now() + 120)
        stop.set()
        XCTAssertEqual(outcome, .success, "deadlock: \(captures) of 2000 captures returned")
        XCTAssertEqual(captures, 2_000)
        XCTAssertEqual(resumeFailures, 0)
        XCTAssertGreaterThan(nonEmpty, 1_900, "captures really stopped and walked the thread")
    }

    /// Lead ruling 3: idle cost of the main-loop probe. Opt-in (4 minutes):
    /// `VOICEBAR_MEASURE_WATCHDOG_CPU=1 swift test --filter testMeasureIdleWatchdogCPU`.
    func testMeasureIdleWatchdogCPU() throws {
        guard ProcessInfo.processInfo.environment["VOICEBAR_MEASURE_WATCHDOG_CPU"] == "1" else {
            throw XCTSkip("opt-in measurement")
        }
        func cpuSeconds() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let loop = CFRunLoopGetMain()!
        let window: TimeInterval = 60
        for (name, interval, leeway) in [("none", 0.0, 0.0), ("candidate 500ms/100ms", 0.5, 0.1),
                                         ("round1 125ms/31ms", 0.125, 0.031), ("round2 250ms/100ms", 0.25, 0.1)] {
            var watchdog: RuntimeResponsivenessWatchdog?
            if interval > 0 {
                watchdog = RuntimeResponsivenessWatchdog(loop: "main", threshold: 0.5, enqueue: { ack in
                    CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { ack.perform() }
                    CFRunLoopWakeUp(loop)
                }, sink: { _ in })
                watchdog?.start(interval: interval, leeway: leeway)
            }
            let before = cpuSeconds()
            RunLoop.main.run(until: Date().addingTimeInterval(window))
            let used = cpuSeconds() - before
            watchdog?.stop()
            print(String(format: "WATCHDOG_CPU config=%@ window_s=%.0f cpu_ms=%.1f cpu_percent=%.4f",
                         name, window, used * 1000, used / window * 100))
        }
    }

    func testPhaseBoardHoldsStateNamesOnlyAndAgesMemoryPressure() {
        var now: TimeInterval = 50
        let board = RuntimePhaseBoard(uptime: { now }, thermal: { .nominal })
        XCTAssertEqual(board.snapshot(), "phase=idle/closed mem_pressure=none thermal=nominal")
        board.noteMemoryPressure(level: "warning")
        now = 233
        board.setMode("some words a person said, at length, that must never reach a log line")
        board.noteSurfaceTransition(line: "no arrow here")
        let line = board.snapshot()
        XCTAssertEqual(line, "phase=somewordsapersonsaidatlengththatmustneve/closed mem_pressure=warning@183s thermal=nominal")
        XCTAssertEqual(line.split(separator: " ").count, 3, "every field is one token")
    }

    func testStoppedWatchdogIgnoresLateAcknowledgement() {
        let queued = expectation(description: "probe queued")
        let lock = NSLock()
        var acknowledgement: DispatchWorkItem?
        let watchdog = RuntimeResponsivenessWatchdog(loop: "fixture", enqueue: { ack in
            lock.lock(); acknowledgement = ack; lock.unlock(); queued.fulfill()
        }, sink: { _ in XCTFail("stopped watchdog emitted a receipt") })
        watchdog.start()
        wait(for: [queued], timeout: 2)
        watchdog.stop()
        lock.lock(); let ack = acknowledgement; lock.unlock()
        XCTAssertEqual(ack?.isCancelled, true)
        ack?.perform()
        watchdog.stop() // Serial drain after the stale callback.
    }

    func testLaunchCustodyOnlyRedirectsCanonicalManualLaunch() {
        XCTAssertTrue(VoiceBarLaunchCustody.needsHandoff(bundlePath: "/Applications/VoiceBar.app", singleton: true, service: "application.com.voicelayer.voicebar.123"))
        XCTAssertFalse(VoiceBarLaunchCustody.needsHandoff(bundlePath: "/Applications/VoiceBar.app", singleton: true, service: VoiceBarLaunchCustody.label))
        XCTAssertFalse(VoiceBarLaunchCustody.needsHandoff(bundlePath: "/tmp/vl-ui-fixture/QA.app", singleton: true, service: nil))
        XCTAssertFalse(VoiceBarLaunchCustody.needsHandoff(bundlePath: "/Applications/VoiceBar.app", singleton: false, service: nil))
    }

    func testLaunchCustodyRejectsOtherTargetsAndArguments() throws {
        func data(_ target: String, extra: Bool = false) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["Label": VoiceBarLaunchCustody.label,
                "ProgramArguments": [target] + (extra ? ["--other"] : [])], format: .xml, options: 0)
        }
        XCTAssertTrue(VoiceBarLaunchCustody.validAgent(try data(VoiceBarLaunchCustody.executable)))
        XCTAssertFalse(VoiceBarLaunchCustody.validAgent(try data("/tmp/VoiceBar")))
        XCTAssertFalse(VoiceBarLaunchCustody.validAgent(try data(VoiceBarLaunchCustody.executable, extra: true)))
        XCTAssertFalse(VoiceBarLaunchCustody.validAgent(Data()))
    }

    func testManualLaunchDispositionFallsThroughUnlessHandoffSucceeds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = root.appendingPathComponent("agent.plist")
        let valid = try PropertyListSerialization.data(fromPropertyList: ["Label": VoiceBarLaunchCustody.label,
            "ProgramArguments": [VoiceBarLaunchCustody.executable]], format: .xml, options: 0)
        for (data, loaded, commandOK, expectedExit, reason) in [
            (Optional<Data>.none, true, true, false, "missing_agent"),
            (Data("invalid".utf8), true, true, false, "invalid_agent"),
            (valid, true, true, true, "handoff=accepted"),
            (valid, true, false, false, "kickstart_failed"),
            (valid, false, true, true, "handoff=accepted"),
            (valid, false, false, false, "bootstrap_failed"),
        ] {
            if let data { try data.write(to: plist) }
            else { try? FileManager.default.removeItem(at: plist) }
            var events: [String] = []
            let exitsSuccessfully = VoiceBarLaunchCustody.handoff(plist: plist, attachLog: {
                events.append("file_log_attached"); return true
            }, run: { arguments in
                events.append(arguments[0])
                return arguments[0] == "print" ? loaded : commandOK
            }, log: { events.append($0) })
            XCTAssertEqual(exitsSuccessfully, expectedExit, reason)
            XCTAssertEqual(events.first, "file_log_attached", reason)
            XCTAssertTrue(events.last?.contains(reason) == true, reason)
            if expectedExit { XCTAssertTrue(events.contains(loaded ? "kickstart" : "bootstrap")) }
            else { XCTAssertTrue(events.last?.contains("fallthrough=") == true) }
            if data == nil || data != valid { XCTAssertFalse(events.contains("print")) }
        }
    }

}
