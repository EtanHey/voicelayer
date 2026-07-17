@testable import VoiceBar
import XCTest

final class VoiceBarInstanceGuardTests: XCTestCase {
    private let canonicalPath = "/Applications/VoiceBar.app"

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
