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
            .components(separatedBy: "private func startPermissionHealth()").first)
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
}
