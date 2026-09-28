@testable import VoiceBarUI
import XCTest

/// F3 entry points: when the wizard opens by itself, and the two ways to open it again.
final class SetupWizardLaunchPolicyTests: XCTestCase {
    private let working = SetupLaunchReadiness(permissionsGranted: true, listenerActive: true)
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SetupWizardLaunchPolicyTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    /// #211 r1 (the lead's upgrade check): a Mac that has dictated before, with its permissions and a working F5
    /// listener but no F5 key helper, is already set up. It must not see the wizard, and that is saved.
    func testAnUpgradedMacThatHasDictatedBeforeIsMarkedCompletedAndNeverShown() {
        let store = SetupWizardCompletionStore(defaults: defaults)
        XCTAssertFalse(SetupWizardLaunchPolicy.resolve(store: store, hasPriorUse: true, readiness: working))
        XCTAssertTrue(store.isCompleted, "saved, so the next launch doesn't decide again")
        XCTAssertFalse(SetupWizardLaunchPolicy.resolve(store: store, hasPriorUse: true, readiness: working))
    }

    /// The lead's default: a Mac used before but now missing a permission isn't shown the wizard; Settings shows
    /// the permission row, and Run setup… is in the menu.
    func testAMacUsedBeforeButMissingAPermissionIsNotShownTheWizard() {
        let store = SetupWizardCompletionStore(defaults: defaults)
        let missingMicrophone = SetupLaunchReadiness(permissionsGranted: false, listenerActive: true)
        XCTAssertFalse(SetupWizardLaunchPolicy.resolve(store: store, hasPriorUse: true, readiness: missingMicrophone))
        XCTAssertTrue(store.isCompleted)
    }

    func testAFreshInstallWithSomethingToSetUpShowsTheWizardOnce() {
        for readiness in [
            SetupLaunchReadiness(permissionsGranted: false, listenerActive: false),
            SetupLaunchReadiness(permissionsGranted: true, listenerActive: false),
            SetupLaunchReadiness(permissionsGranted: false, listenerActive: true),
        ] {
            XCTAssertEqual(
                SetupWizardLaunchPolicy.decide(
                    isCompleted: false, hasResumeStep: false, hasPriorUse: false, readiness: readiness
                ),
                .show,
                "\(readiness)"
            )
        }
        let store = SetupWizardCompletionStore(defaults: defaults)
        XCTAssertTrue(SetupWizardLaunchPolicy.resolve(
            store: store, hasPriorUse: false,
            readiness: SetupLaunchReadiness(permissionsGranted: false, listenerActive: false)
        ))
        XCTAssertFalse(
            store.isCompleted,
            "showing isn't completing: Finish, Skip setup or closing the window does that"
        )
    }

    /// Try it's rule: F5 is listened for directly, so a missing helper alone isn't "not ready".
    func testAFreshInstallThatAlreadyWorksIsMarkedCompletedWithoutShowing() {
        let store = SetupWizardCompletionStore(defaults: defaults)
        XCTAssertFalse(SetupWizardLaunchPolicy.resolve(store: store, hasPriorUse: false, readiness: working))
        XCTAssertTrue(store.isCompleted)
    }

    func testAnUnfinishedFirstRunResumesEvenWhenEverythingIsReadyNow() {
        XCTAssertEqual(
            SetupWizardLaunchPolicy.decide(
                isCompleted: false,
                hasResumeStep: true,
                hasPriorUse: true,
                readiness: working
            ),
            .show,
            "e.g. relaunched after Input Monitoring mid-setup; the wizard itself left the resume step"
        )
    }

    func testACompletedSetupNeverOpensByItself() {
        XCTAssertEqual(
            SetupWizardLaunchPolicy.decide(
                isCompleted: true,
                hasResumeStep: true,
                hasPriorUse: false,
                readiness: SetupLaunchReadiness(permissionsGranted: false, listenerActive: false)
            ),
            .none
        )
    }
}

/// The existing-install signal: the recordings archive (every recording is kept, by the daemon, outside the app's
/// defaults) or VoiceBar's own recent-transcriptions list.
final class SetupPriorUseTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupPriorUseTests-\(UUID().uuidString)")
            .appendingPathComponent("recordings")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relative), withIntermediateDirectories: true
        )
    }

    func testARecordingInTheArchiveMeansPriorUse() throws {
        try makeDirectory("2026-01-02/2026-01-02T10-00-00-000Z-synthetic")
        XCTAssertTrue(SetupPriorUse.detect(archiveRoot: root, recentTranscriptionCount: 0))
    }

    func testNoArchiveAnEmptyArchiveOrOnlyPartialWritesIsNoPriorUse() throws {
        XCTAssertFalse(SetupPriorUse.detect(archiveRoot: root, recentTranscriptionCount: 0), "no archive")
        try makeDirectory("")
        XCTAssertFalse(SetupPriorUse.detect(archiveRoot: root, recentTranscriptionCount: 0), "empty root")
        try makeDirectory("2026-01-02")
        XCTAssertFalse(SetupPriorUse.detect(archiveRoot: root, recentTranscriptionCount: 0), "an empty day")
        try makeDirectory("2026-01-02/.tmp-2026-01-02T10-00-00-000Z")
        XCTAssertFalse(SetupPriorUse.detect(archiveRoot: root, recentTranscriptionCount: 0), "a partial write")
        try makeDirectory(".hidden/2026-01-02T10-00-00-000Z")
        XCTAssertFalse(SetupPriorUse.detect(archiveRoot: root, recentTranscriptionCount: 0), "a hidden folder")
    }

    func testRecentTranscriptionsMeanPriorUseEvenWithoutAnArchive() {
        XCTAssertTrue(SetupPriorUse.detect(archiveRoot: root, recentTranscriptionCount: 3))
    }
}

final class SetupWizardEntryPointContractTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testSettingsGeneralOffersRunSetupAgain() throws {
        let settings = try source("Sources/VoiceBarUI/SettingsView.swift")
        XCTAssertTrue(settings.contains("public let onRunSetup: () -> Void"))
        XCTAssertTrue(settings.contains("Button(\"Run setup again\") {\n                    onRunSetup()"))
    }

    func testTheMenuBarPopoverOffersRunSetup() throws {
        let popover = try source("Sources/VoiceBarUI/MenuBarPopoverView.swift")
        XCTAssertTrue(popover.contains("public let onRunSetup: () -> Void"))
        XCTAssertTrue(popover.contains("Button(\"Run setup…\", action: onRunSetup)"))
    }
}
