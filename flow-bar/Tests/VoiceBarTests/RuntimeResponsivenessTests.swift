import XCTest
@testable import VoiceBar

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
        watchdog.start(interval: 0.01)
        wait(for: [stalled], timeout: 3)
        lock.lock()
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(receipts.count, 1)
        lock.unlock()
        release.signal()
        wait(for: [recovered], timeout: 3)
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
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, ack)
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

    func testStoppedWatchdogIgnoresLateAcknowledgement() {
        let queued = expectation(description: "probe queued")
        let lock = NSLock()
        var acknowledgement: (() -> Void)?
        let watchdog = RuntimeResponsivenessWatchdog(loop: "fixture", enqueue: { ack in
            lock.lock(); acknowledgement = ack; lock.unlock(); queued.fulfill()
        }, sink: { _ in XCTFail("stopped watchdog emitted a receipt") })
        watchdog.start()
        wait(for: [queued], timeout: 2)
        watchdog.stop()
        lock.lock(); let ack = acknowledgement; lock.unlock()
        ack?()
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
}
