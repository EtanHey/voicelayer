import AppKit
import SwiftUI
import XCTest
@testable import VoiceBarUI

/// 2.3 permission health: a permission revoked while VoiceBar runs surfaces without a relaunch. The provider is a
/// fake, so no test reads or requests a real permission.
final class PermissionHealthTests: XCTestCase {
    private final class FakePermissions {
        var reading = PermissionHealthReading.allGranted
        var reads = 0
    }

    private func setup(_ reading: PermissionHealthReading, listener: Bool = true) -> SettingsGeneralSetup {
        SettingsGeneralSetup(permissions: SetupPermissionsStep(snapshot: reading.snapshot(hotkeyListenerActive: listener)).rows,
                             hotkeyListenerActive: listener, f5CheckedAt: nil, voice: .ready)
    }

    func testRevokingAccessibilityAtRuntimePublishesAndSetupShowsOnlyThatRow() throws {
        let fake = FakePermissions()
        let monitor = PermissionHealthMonitor(read: { fake.reads += 1; return fake.reading })
        var published: [(PermissionHealthReading, PermissionHealthTrigger)] = []
        monitor.onChange = { published.append(($0, $1)) }

        XCTAssertTrue(monitor.refresh(.launch))
        XCTAssertTrue(setup(try XCTUnwrap(monitor.reading)).isHealthy)
        XCTAssertFalse(monitor.refresh(.poll), "an unchanged reading publishes nothing")
        XCTAssertEqual(published.count, 1)

        // Revoked in System Settings (or `tccutil reset`) while running; the F5 listener is still the launch one.
        fake.reading = PermissionHealthReading(microphone: .granted, accessibilityGranted: false,
                                               inputMonitoringGranted: true)
        XCTAssertTrue(monitor.refresh(.appActivated))
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(published.last?.1, .appActivated)
        let reading = try XCTUnwrap(published.last?.0)
        XCTAssertEqual(reading.missingPermissions, [.accessibility], "what the notch's orange dot shows")
        XCTAssertEqual(reading.missingHotkeyPermissions, [.accessibility])

        let broken = setup(reading)
        XCTAssertEqual(broken.steps.map(\.id), [.accessibility])
        XCTAssertEqual(broken.firstBroken, .accessibility)
        XCTAssertEqual(broken.steps.first?.fix, .permission(.openSettings(
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")))

        // Granted again: back to nothing, still without a relaunch.
        fake.reading = .allGranted
        XCTAssertTrue(monitor.refresh(.poll))
        XCTAssertTrue(setup(try XCTUnwrap(published.last?.0)).isHealthy)
        XCTAssertEqual(fake.reads, 4)
    }

    func testForceRepublishesAnUnchangedReading() {
        let monitor = PermissionHealthMonitor(read: { .allGranted })
        var count = 0
        monitor.onChange = { _, _ in count += 1 }
        monitor.refresh(.launch)
        XCTAssertFalse(monitor.refresh(.listenerChanged, force: true))
        XCTAssertEqual(count, 2)
    }

    func testTheNotchDotAndFirstBrokenAgreeOnOrder() {
        let reading = PermissionHealthReading(microphone: .denied, accessibilityGranted: false,
                                              inputMonitoringGranted: false)
        XCTAssertEqual(reading.missingPermissions, [.microphone, .accessibility, .inputMonitoring])
        XCTAssertEqual(reading.missingHotkeyPermissions, [.inputMonitoring, .accessibility])
        XCTAssertEqual(setup(reading).firstBroken, .microphone)
        XCTAssertEqual(PermissionHealthReading(microphone: .notRequested, accessibilityGranted: true,
                                               inputMonitoringGranted: true).missingPermissions, [.microphone])
    }

    /// Status reads only: the app's reader uses the non-prompting APIs and the monitor never requests anything.
    func testTheAppReaderNeverPrompts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBar/VoiceBarApp.swift"), encoding: .utf8)
        let reader = try XCTUnwrap(app.components(separatedBy: "static func readPermissionHealth()").dropFirst().first?
            .components(separatedBy: "func startPermissionHealth()").first)
        XCTAssertTrue(reader.contains("HotkeyManager.currentPermissionStatus()"))
        XCTAssertTrue(reader.contains("AVCaptureDevice.authorizationStatus(for: .audio)"))
        for prompting in ["requestAccess", "kAXTrustedCheckOptionPrompt", "CGRequestListenEventAccess", "requestPermissions"] {
            XCTAssertFalse(reader.contains(prompting), prompting)
        }
        let monitor = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/PermissionHealth.swift"),
                                 encoding: .utf8)
        for prompting in ["requestAccess", "kAXTrustedCheckOptionPrompt", "CGRequestListenEventAccess", "IOHIDRequestAccess"] {
            XCTAssertFalse(monitor.contains(prompting), prompting)
        }
        for seam in [".appActivated", ".settingsOpened", ".notchHovered", ".captureEnded", ".listenerChanged"] {
            XCTAssertTrue(app.contains("refreshPermissionHealth(\(seam)"), seam)
        }
    }
    // MARK: - Teardown (review R1 #795)

    final class FakeTicker: PermissionHealthTicker {
        var tick: (() -> Void)?
        private(set) var invalidated = false
        func invalidate() { invalidated = true }
    }

    func testAStoppedOrDisposedMonitorNeverReadsOrPublishesOnALaterTick() {
        let fake = FakePermissions()
        let ticker = FakeTicker()
        var published = 0
        var monitor: PermissionHealthMonitor? = PermissionHealthMonitor(
            read: { fake.reads += 1; return fake.reading },
            schedule: { _, tick in ticker.tick = tick; return ticker })
        monitor?.onChange = { _, _ in published += 1 }
        monitor?.startPolling()
        ticker.tick?()
        XCTAssertEqual(fake.reads, 1, "a live tick reads")
        XCTAssertEqual(published, 1)

        monitor?.stopPolling()
        XCTAssertTrue(ticker.invalidated)
        XCTAssertFalse(monitor?.isPolling ?? true)
        fake.reading = PermissionHealthReading(microphone: .granted, accessibilityGranted: false,
                                               inputMonitoringGranted: true)
        ticker.tick?()
        XCTAssertEqual(fake.reads, 1, "a tick after stopPolling reads nothing")
        XCTAssertEqual(published, 1, "and publishes nothing")

        // Owner teardown without stopPolling: deinit invalidates, and the orphan tick is inert.
        let orphan = FakeTicker()
        monitor = PermissionHealthMonitor(read: { fake.reads += 1; return fake.reading },
                                          schedule: { _, tick in orphan.tick = tick; return orphan })
        monitor?.onChange = { _, _ in published += 1 }
        monitor?.startPolling()
        monitor = nil
        XCTAssertTrue(orphan.invalidated, "deinit invalidates the repeating timer")
        orphan.tick?()
        XCTAssertEqual(fake.reads, 1)
        XCTAssertEqual(published, 1)
    }

    // MARK: - Healthy after a successful restart (review R1 #795)

    func testASuccessfulRestartLeavesNoSetupSectionOnceHealthy() {
        let success = HotkeyListenerRestartLine(outcome: .started)
        let failure = HotkeyListenerRestartLine(outcome: .failed(missing: [.accessibility]))
        let healthy = setup(.allGranted, listener: true)
        XCTAssertFalse(healthy.showsSection)
        XCTAssertNil(healthy.visibleRestartLine(success), "no leftover success row when healthy")
        let broken = setup(PermissionHealthReading(microphone: .granted, accessibilityGranted: false,
                                                   inputMonitoringGranted: true), listener: false)
        XCTAssertTrue(broken.showsSection)
        XCTAssertEqual(broken.visibleRestartLine(failure), failure, "failure keeps its Copy row while broken")
    }

    /// Rendered: General's laid-out height is the observable (an offscreen SwiftUI Form exposes no AX text). A
    /// healthy pane right after a successful restart is exactly as tall as one that never restarted.
    @MainActor
    func testRenderedGeneralShowsNoSetupRightAfterASuccessfulRestart() throws {
        let plain = try generalHeight(render(settings(listener: true, missing: [], restart: nil)))
        let afterRestart = try generalHeight(render(settings(listener: true, missing: [], restart: .started)))
        XCTAssertEqual(afterRestart, plain, accuracy: 0.5, "no Setup header or success row once healthy")

        let failed = try generalHeight(render(settings(listener: false, missing: [.accessibility],
                                                       restart: .failed(missing: [.accessibility]))))
        XCTAssertGreaterThan(failed, plain + 60, "a broken pane shows Setup, its row and the failure line")
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            windows.forEach { $0.orderOut(nil); $0.contentView = nil }
            windows.removeAll()
        }
        super.tearDown()
    }

    @MainActor
    private func settings(listener: Bool, missing: [HotkeyPermission],
                          restart: HotkeyListenerRestartOutcome?) -> SettingsView {
        SettingsView(hotkeyEnabled: listener, missingPermissions: missing, availableDevices: { [] },
                     selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
                     vocabularyRevision: { 0 }, microphoneAuthorization: { .granted }, initialTab: .general,
                     initialHotkeyListenerRestart: restart)
    }

    @MainActor
    func render(_ view: some View) -> NSView {
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
}

/// The laid-out height of General's Form: its scroll view's document, the tallest one in the host.
@MainActor
func generalHeight(_ root: NSView) throws -> CGFloat {
    var best: CGFloat = 0
    func visit(_ view: NSView) {
        if let scroll = view as? NSScrollView, let height = scroll.documentView?.frame.height { best = max(best, height) }
        view.subviews.forEach(visit)
    }
    visit(root)
    return try XCTUnwrap(best > 0 ? best : nil, "General's Form scroll view")
}
