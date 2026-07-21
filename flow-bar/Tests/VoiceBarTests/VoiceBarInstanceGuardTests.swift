@testable import VoiceBar
import XCTest

final class VoiceBarInstanceGuardTests: XCTestCase {
    private let canonicalPath = "/Applications/VoiceBar.app"

    func testIsolatedLaunchDateUsesObservedWorkspaceValueOrImmediateFallback() {
        let observed = Date(timeIntervalSince1970: 1_784_333_000.125)
        let fallback = Date(timeIntervalSince1970: 1_784_333_001.250)

        XCTAssertEqual(
            VoiceBarInstanceLaunchDate.resolve(observed: observed, fallback: fallback),
            observed
        )
        XCTAssertEqual(
            VoiceBarInstanceLaunchDate.resolve(observed: nil, fallback: fallback),
            fallback
        )
    }

    func testCanonicalLaunchSupersedesEveryOlderNoncanonicalInstanceByExactPID() {
        let decision = VoiceBarInstanceGuard.plan(
            current: .init(pid: 300, bundlePath: canonicalPath),
            running: [
                .init(pid: 300, bundlePath: canonicalPath),
                .init(pid: 91, bundlePath: "/tmp/VoiceBar-old.app"),
                .init(pid: 42, bundlePath: "/Users/test/VoiceBar-dev.app"),
                .init(pid: 91, bundlePath: "/tmp/VoiceBar-old.app"),
            ],
            canonicalBundlePath: canonicalPath,
            enforcesSingleton: true
        )

        XCTAssertEqual(decision, .supersede([42, 91]))
    }

    func testCanonicalLaunchDefersToExistingIsolatedQASurface() {
        let decision = VoiceBarInstanceGuard.plan(
            current: .init(pid: 300, bundlePath: canonicalPath),
            running: [
                .init(pid: 300, bundlePath: canonicalPath),
                .init(pid: 91, bundlePath: "/tmp/VoiceBar-qa.app", isIsolated: true),
                .init(pid: 42, bundlePath: "/Users/test/VoiceBar-dev.app"),
            ],
            canonicalBundlePath: canonicalPath,
            enforcesSingleton: true
        )

        XCTAssertEqual(decision, .exitCurrent(canonicalPID: 91))
    }

    func testNoncanonicalLaunchExitsWhenCanonicalInstanceAlreadyRuns() {
        let decision = VoiceBarInstanceGuard.plan(
            current: .init(pid: 300, bundlePath: "/tmp/VoiceBar-new.app"),
            running: [
                .init(pid: 20, bundlePath: canonicalPath),
                .init(pid: 300, bundlePath: "/tmp/VoiceBar-new.app"),
            ],
            canonicalBundlePath: canonicalPath,
            enforcesSingleton: true
        )

        XCTAssertEqual(decision, .exitCurrent(canonicalPID: 20))
    }

    func testNewestNoncanonicalNormalStackLaunchSupersedesOlderNoncanonicalInstances() {
        let decision = VoiceBarInstanceGuard.plan(
            current: .init(pid: 300, bundlePath: "/tmp/VoiceBar-new.app"),
            running: [
                .init(pid: 75, bundlePath: "/tmp/VoiceBar-old.app"),
                .init(pid: 300, bundlePath: "/tmp/VoiceBar-new.app"),
            ],
            canonicalBundlePath: canonicalPath,
            enforcesSingleton: true
        )

        XCTAssertEqual(decision, .supersede([75]))
    }

    func testIsolatedSocketLaunchBypassesSingleInstanceGuard() {
        let decision = VoiceBarInstanceGuard.plan(
            current: .init(pid: 300, bundlePath: "/tmp/VoiceBar-qa.app"),
            running: [
                .init(pid: 20, bundlePath: canonicalPath),
                .init(pid: 300, bundlePath: "/tmp/VoiceBar-qa.app"),
            ],
            canonicalBundlePath: canonicalPath,
            enforcesSingleton: false
        )

        XCTAssertEqual(decision, .bypass)
    }

    func testIsolatedSurfaceDefersToAnyExistingVoiceBarSibling() {
        let canonical = VoiceBarInstanceGuard.plan(
            current: .init(pid: 300, bundlePath: "/tmp/VoiceBar-qa.app", isIsolated: true),
            running: [
                .init(pid: 20, bundlePath: canonicalPath),
                .init(pid: 300, bundlePath: "/tmp/VoiceBar-qa.app", isIsolated: true),
            ],
            canonicalBundlePath: canonicalPath,
            enforcesSingleton: true
        )
        let noncanonical = VoiceBarInstanceGuard.plan(
            current: .init(pid: 300, bundlePath: "/tmp/VoiceBar-new.app", isIsolated: true),
            running: [
                .init(pid: 75, bundlePath: "/tmp/VoiceBar-old.app", isIsolated: true),
                .init(pid: 300, bundlePath: "/tmp/VoiceBar-new.app", isIsolated: true),
            ],
            canonicalBundlePath: canonicalPath,
            enforcesSingleton: true
        )

        XCTAssertEqual(canonical, .exitCurrent(canonicalPID: 20))
        XCTAssertEqual(noncanonical, .exitCurrent(canonicalPID: 75))
    }

    func testCanonicalSurfaceDefersToAnExistingIsolatedProofInsteadOfCoexisting() {
        let decision = VoiceBarInstanceGuard.plan(
            current: .init(pid: 300, bundlePath: canonicalPath),
            running: [
                .init(pid: 75, bundlePath: "/tmp/VoiceBar-proof.app", isIsolated: true),
                .init(pid: 300, bundlePath: canonicalPath),
            ],
            canonicalBundlePath: canonicalPath,
            enforcesSingleton: true
        )

        XCTAssertEqual(decision, .exitCurrent(canonicalPID: 75))
    }

    func testIsolationRegistryMatchesTheExactPIDAcrossObserverLaunchDateSkew() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceBarIsolationRegistryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let launchDate = Date(timeIntervalSince1970: 1_784_333_000.125)

        try VoiceBarInstanceIsolationRegistry.register(
            pid: 91,
            launchDate: launchDate,
            socketPath: "/tmp/voicelayer-qa/voicebar.sock",
            directory: directory
        )

        XCTAssertTrue(
            VoiceBarInstanceIsolationRegistry.isRegistered(
                pid: 91,
                launchDate: launchDate,
                directory: directory
            )
        )
        XCTAssertTrue(
            VoiceBarInstanceIsolationRegistry.isRegistered(
                pid: 91,
                launchDate: launchDate.addingTimeInterval(0.25),
                directory: directory
            ),
            "NSRunningApplication observers can report the same launch with sub-second skew"
        )
        XCTAssertFalse(
            VoiceBarInstanceIsolationRegistry.isRegistered(
                pid: 91,
                launchDate: launchDate.addingTimeInterval(2),
                directory: directory
            ),
            "a reused PID from a later launch must not inherit the old isolation marker"
        )

        VoiceBarInstanceIsolationRegistry.unregister(pid: 91, directory: directory)
        XCTAssertFalse(
            VoiceBarInstanceIsolationRegistry.isRegistered(
                pid: 91,
                launchDate: launchDate,
                directory: directory
            )
        )
    }

    func testIsolationRegistryRejectsAnOverflowingMarkerTimestamp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceBarIsolationRegistryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker: [String: Any] = [
            "pid": 91,
            "launchTimeMilliseconds": Int64.min,
            "socketPath": "/tmp/voicelayer-qa/voicebar.sock",
        ]
        let data = try JSONSerialization.data(withJSONObject: marker)
        try data.write(to: directory.appendingPathComponent("91.json"))

        XCTAssertFalse(
            VoiceBarInstanceIsolationRegistry.isRegistered(
                pid: 91,
                launchDate: Date(timeIntervalSince1970: 1_784_333_000.125),
                directory: directory
            )
        )
    }

    func testElectionLockSerializesConcurrentLaunchPlanning() {
        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceBarInstanceGuardTests-\(UUID().uuidString).lock")
            .path
        defer { try? FileManager.default.removeItem(atPath: lockPath) }
        let firstEntered = expectation(description: "first launch entered election")
        let firstExited = expectation(description: "first launch exited election")
        let secondEntered = expectation(description: "second launch entered election")
        let releaseFirst = DispatchSemaphore(value: 0)
        let orderLock = NSLock()
        var order: [String] = []

        DispatchQueue.global().async {
            try? VoiceBarInstanceElectionLock.withExclusiveLock(atPath: lockPath) {
                orderLock.withLock { order.append("first-enter") }
                firstEntered.fulfill()
                releaseFirst.wait()
                orderLock.withLock { order.append("first-exit") }
            }
            firstExited.fulfill()
        }
        wait(for: [firstEntered], timeout: 1)

        DispatchQueue.global().async {
            try? VoiceBarInstanceElectionLock.withExclusiveLock(atPath: lockPath) {
                orderLock.withLock { order.append("second-enter") }
                secondEntered.fulfill()
            }
        }

        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(orderLock.withLock { order }, ["first-enter"])
        releaseFirst.signal()
        wait(for: [firstExited, secondEntered], timeout: 2)
        XCTAssertEqual(
            orderLock.withLock { order },
            ["first-enter", "first-exit", "second-enter"]
        )
    }
}
