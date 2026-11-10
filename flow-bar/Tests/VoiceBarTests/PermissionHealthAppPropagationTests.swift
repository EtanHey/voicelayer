import OffscreenTestSupport
import AppKit
import SwiftUI
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// Review R1 #795: a permission revoked while VoiceBar runs must reach what the user sees, through the real owner
/// (AppDelegate → VoiceState / makeSettingsView), with no relaunch. The status provider and the poll tick are fakes,
/// so nothing reads or requests a real permission and the native F5 listener is never started.
@MainActor
final class PermissionHealthAppPropagationTests: XCTestCase {
    private final class FakeTicker: PermissionHealthTicker {
        var tick: (() -> Void)?
        private(set) var invalidated = false
        func invalidate() { invalidated = true }
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            windows.forEach { $0.orderOut(nil); $0.contentView = nil }
            windows.removeAll()
        }
        super.tearDown()
    }

    func testRevokeAndRegrantReachSettingsTheNotchDotAndThePopoverWithoutRelaunch() throws {
        var reading = PermissionHealthReading.allGranted
        var reads = 0
        let ticker = FakeTicker()
        let app = AppDelegate()
        app.permissionHealth = PermissionHealthMonitor(read: { reads += 1; return reading },
                                                       schedule: { _, tick in ticker.tick = tick; return ticker })
        app.hotkeyEnabled = true // the listener as launched; this test never starts the real event tap
        app.startPermissionHealth()
        defer { app.stopPermissionHealth() }

        let healthyHeight = try assertHealthy(app, "launch")

        // Revoked in System Settings while running; the app notices on its next activation (the real observer).
        reading = PermissionHealthReading(microphone: .granted, accessibilityGranted: false, inputMonitoringGranted: true)
        VLPostTestActivation()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(app.voiceState.setupMissingPermissions, [.accessibility], "the notch gear's orange dot")
        XCTAssertTrue(app.voiceState.setupNeedsAttention)
        XCTAssertEqual(VoiceBarSetupAttention.tooltip(missing: app.voiceState.setupMissingPermissions),
                       "Accessibility is off, so F5 can’t start dictation. Click to fix.")
        XCTAssertEqual(app.missingHotkeyPermissions, [.accessibility])
        let brokenView = app.makeSettingsView()
        XCTAssertEqual(setup(of: brokenView).firstBroken, .accessibility,
                       "the dot's click lands General on this step (focus .permissions → firstBroken)")
        XCTAssertEqual(setup(of: brokenView).steps.map(\.id), [.accessibility])
        // Rendered: the Setup section (header + Accessibility row) appears in General's laid-out Form.
        XCTAssertGreaterThan(try generalHeight(render(brokenView)), healthyHeight + 30, "Setup row rendered")
        XCTAssertEqual(app.menuBarSetupAlert()?.title, "Fix Accessibility…")

        // Granted again; the 5 s poll tick (fake) picks it up, still without a relaunch.
        reading = .allGranted
        ticker.tick?()
        XCTAssertEqual(try assertHealthy(app, "regranted"), healthyHeight, accuracy: 0.5, "Setup row gone again")

        // Teardown: no reads after stop, even if a tick or an activation arrives late.
        app.stopPermissionHealth()
        XCTAssertTrue(ticker.invalidated)
        let readsAtStop = reads
        reading = PermissionHealthReading(microphone: .denied, accessibilityGranted: false, inputMonitoringGranted: false)
        ticker.tick?()
        VLPostTestActivation()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(reads, readsAtStop, "a stopped monitor reads nothing")
        XCTAssertEqual(app.voiceState.setupMissingPermissions, [], "and changes nothing")
    }

    @discardableResult
    private func assertHealthy(_ app: AppDelegate, _ moment: String) throws -> CGFloat {
        XCTAssertEqual(app.voiceState.setupMissingPermissions, [], moment)
        XCTAssertFalse(app.voiceState.setupNeedsAttention, moment)
        XCTAssertNil(app.menuBarSetupAlert(), moment)
        let view = app.makeSettingsView()
        XCTAssertNil(setup(of: view).firstBroken, moment)
        XCTAssertTrue(setup(of: view).steps.isEmpty, moment)
        return try generalHeight(render(view))
    }

    /// The same inputs SettingsView's General › Setup reads.
    private func setup(of view: SettingsView) -> SettingsGeneralSetup {
        SettingsGeneralSetup(permissions: view.permissionRowModels, hotkeyListenerActive: view.hotkeyEnabled,
                             f5CheckedAt: nil, voice: view.speakingVoiceStatus())
    }

    private func render(_ view: SettingsView) -> NSView {
        // Shorter than General, so the Form scrolls and its document height is the content's.
        let host = NSHostingView(rootView: view.frame(width: 780, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The laid-out height of General's Form (an offscreen SwiftUI Form exposes no AX text to read).
    private func generalHeight(_ root: NSView) throws -> CGFloat {
        var best: CGFloat = 0
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, let height = scroll.documentView?.frame.height {
                best = max(best, height)
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return try XCTUnwrap(best > 0 ? best : nil, "General's Form scroll view")
    }
}
