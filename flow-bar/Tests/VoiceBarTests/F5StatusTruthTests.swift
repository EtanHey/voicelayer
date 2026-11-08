import XCTest
@testable import VoiceBar
@testable import VoiceBarUI

final class F5StatusTruthTests: XCTestCase {
    private final class Listener: HotkeyListening {
        var isEnabled = true
        var missingPermissions: [HotkeyPermission] { [] }
        func start() -> Bool { true }
        func stop() { isEnabled = false }
    }

    func testHealthFollowsEnabledTapAfterItStopsWithoutAnExplicitLifecycleStop() {
        let listener = Listener()
        let lifecycle = HotkeyListenerLifecycle { listener }
        XCTAssertEqual(lifecycle.start(), .started)
        XCTAssertTrue(lifecycle.isRunning)
        listener.isEnabled = false
        XCTAssertFalse(lifecycle.isRunning, "a retained manager is not evidence of a live event tap")
    }

    private final class Ticker: PermissionHealthTicker {
        var tick: (() -> Void)?
        func invalidate() {}
    }

    func testUnchangedPermissionPollStillRefreshesTapHealthAndStopDropsTheCallback() {
        let listener = Listener(), ticker = Ticker()
        let lifecycle = HotkeyListenerLifecycle { listener }; _ = lifecycle.start()
        let monitor = PermissionHealthMonitor(read: { .allGranted },
            schedule: { _, tick in ticker.tick = tick; return ticker })
        var healthy = false, changes = 0, refreshes = 0
        monitor.onRefresh = { healthy = lifecycle.isRunning; refreshes += 1 }
        monitor.onChange = { _, _ in changes += 1 }
        monitor.refresh(.launch); monitor.startPolling()
        XCTAssertTrue(healthy)
        listener.isEnabled = false; ticker.tick?()
        XCTAssertFalse(healthy)
        XCTAssertEqual(changes, 1, "unchanged TCC still emits no permission change")
        XCTAssertEqual(refreshes, 2)
        monitor.stopPolling(); ticker.tick?()
        XCTAssertEqual(refreshes, 2)
    }

    func testAppRefreshWiresLiveTapHealthEvenWhenPermissionsAreUnchanged() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBar/VoiceBarApp.swift"))
        let start = try XCTUnwrap(app.components(separatedBy: "func startPermissionHealth()").last?
            .components(separatedBy: "func stopPermissionHealth()").first)
        XCTAssertTrue(start.contains("permissionHealth.onRefresh"), "polls must sample tap health even if TCC is unchanged")
        XCTAssertTrue(start.contains("refreshHotkeyListenerHealth()"))
        let refresh = try XCTUnwrap(app.components(separatedBy: "func refreshHotkeyListenerHealth()").last?
            .components(separatedBy: "func menuBarSetupAlert()").first)
        XCTAssertTrue(refresh.contains("hotkeyListener.isRunning"))
        XCTAssertTrue(refresh.contains("voiceState.setHotkeyEnabled"))
        XCTAssertTrue(refresh.contains("refreshSettingsWindowAnchorState()"))
    }
}
