@testable import VoiceBarUI
import XCTest

/// Settings › General › Permissions, Microphone row. Until VoiceBar has asked once, macOS doesn't list it in the
/// Microphone pane, so "Open" was a dead end there (F3 lead call, 2026-09-28). A never-asked mic now asks first,
/// exactly like the wizard's row. Headless: the row models and the action dispatch only.
final class SettingsMicrophonePermissionRowTests: XCTestCase {
    private static let microphonePane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    private func settings(
        microphone: SetupMicrophoneAuthorization,
        missing: [HotkeyPermission] = []
    ) -> SettingsView {
        settings(missing: missing, microphoneAuthorization: { microphone })
    }

    private func settings(
        missing: [HotkeyPermission] = [],
        microphoneAuthorization: @escaping () -> SetupMicrophoneAuthorization
    ) -> SettingsView {
        SettingsView(
            hotkeyEnabled: missing.isEmpty,
            missingPermissions: missing,
            availableDevices: { [] },
            selectedDeviceID: { nil },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            microphoneAuthorization: microphoneAuthorization
        )
    }

    private func microphoneRow(_ view: SettingsView) throws -> SetupPermissionRow {
        try XCTUnwrap(view.permissionRowModels.first { $0.permission == .microphone })
    }

    func testANeverAskedMicrophoneOffersAllowWhichRequestsAccess() throws {
        let row = try microphoneRow(settings(microphone: .notRequested))
        XCTAssertFalse(row.isGranted)
        XCTAssertEqual(row.status, "Not requested")
        XCTAssertEqual(row.action, .requestMicrophone)
        XCTAssertEqual(row.action?.title, "Allow…")
    }

    func testADeniedMicrophoneKeepsOpenOnItsPane() throws {
        let row = try microphoneRow(settings(microphone: .denied))
        XCTAssertFalse(row.isGranted)
        XCTAssertEqual(row.status, "Missing")
        XCTAssertEqual(row.action, .openSettings(url: Self.microphonePane))
        XCTAssertEqual(row.action?.title, "Open")
    }

    func testAGrantedMicrophoneHasNoAction() throws {
        let row = try microphoneRow(settings(microphone: .granted))
        XCTAssertTrue(row.isGranted)
        XCTAssertEqual(row.status, "Granted")
        XCTAssertNil(row.action)
    }

    /// The provider is read live, so the row follows the answer to the prompt without reopening Settings.
    func testTheRowReadsTheProviderEachTime() throws {
        var status = SetupMicrophoneAuthorization.notRequested
        let view = settings(microphoneAuthorization: { status })
        XCTAssertEqual(try microphoneRow(view).action, .requestMicrophone)
        status = .granted
        XCTAssertNil(try microphoneRow(view).action)
    }

    func testTheOtherTwoRowsStillFollowTheLaunchCheck() {
        let view = settings(microphone: .granted, missing: [.inputMonitoring])
        XCTAssertEqual(view.permissionRowModels.map(\.permission), [.microphone, .accessibility, .inputMonitoring])
        XCTAssertEqual(view.permissionRowModels.map(\.isGranted), [true, true, false])
        XCTAssertEqual(
            view.permissionRowModels[2].action,
            .openSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        )
    }

    func testAllowRequestsAccessAndRefreshesWithoutOpeningSystemSettings() {
        var opened: [URL] = []
        var requests = 0
        var refreshes = 0
        var finishRequest: (() -> Void)?
        SettingsPermissionActions.perform(
            .requestMicrophone,
            openURL: { opened.append($0) },
            requestMicrophone: { completion in
                requests += 1
                finishRequest = completion
            },
            refresh: { refreshes += 1 }
        )
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(refreshes, 0, "the row refreshes once the prompt is answered, not before")
        finishRequest?()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(opened, [])
    }

    func testOpenGoesToThePaneWithoutPrompting() {
        var opened: [URL] = []
        var requests = 0
        SettingsPermissionActions.perform(
            .openSettings(url: Self.microphonePane),
            openURL: { opened.append($0) },
            requestMicrophone: { _ in requests += 1 },
            refresh: {}
        )
        XCTAssertEqual(opened.map(\.absoluteString), [Self.microphonePane])
        XCTAssertEqual(requests, 0)
    }
}
