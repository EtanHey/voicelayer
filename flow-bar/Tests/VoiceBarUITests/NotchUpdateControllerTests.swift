import Foundation
@testable import VoiceBarUI
import XCTest

/// 2.4 Lane A: the build line (untruncated, with "ahead of release by N") and Check for updates / Update, which
/// reuses the cask check and the `voicelayer update` flow and never starts while dictating.
@MainActor
final class NotchUpdateControllerTests: XCTestCase {
    private final class FakeLauncher: VoiceBarUpdateLaunching, @unchecked Sendable {
        var isAvailable = true
        var launches = 0
        var fails = false
        func launch() throws {
            if fails { throw CocoaError(.executableLoad) }
            launches += 1
        }
    }

    private func cask(_ version: String) -> String {
        "cask \"voicebar\" do\n  version \"\(version)\"\nend\n"
    }

    func testGitDescribeParsesTagAndCommitsAhead() {
        XCTAssertEqual(VoiceBarGitDescribe.parse("v2.2.61-14-gabc1234"), .init(releaseVersion: "2.2.61", commitsAhead: 14))
        XCTAssertEqual(VoiceBarGitDescribe.parse("v2.2.61"), .init(releaseVersion: "2.2.61", commitsAhead: 0))
        XCTAssertEqual(VoiceBarGitDescribe.parse("v2.3.0-1-g0f0f0f0-dirty"), .init(releaseVersion: "2.3.0", commitsAhead: 1))
        for bad in [nil, "", "2.2.61-3-gabc", "v2.2.61-x-gabc", "vnext", "v2.2.61-3-abc", "v2.2.61-3-gxyz"] {
            XCTAssertNil(VoiceBarGitDescribe.parse(bad), String(describing: bad))
        }
    }

    func testTheBuildLineShowsVersionAndUserFacingUpdateState() {
        let installed = VoiceBarInstalledVersion(version: "2.3.0", commit: "a1b2c3d4e5f6")
        let ahead = VoiceBarGitDescribe(releaseVersion: "2.2.61", commitsAhead: 14)
        XCTAssertEqual(VoiceBarBuildLine.text(installed: installed, describe: ahead, status: .ahead(latest: "2.2.61")),
                       "2.3.0 · ahead of release 2.2.61")
        XCTAssertEqual(VoiceBarBuildLine.text(installed: installed, describe: .init(releaseVersion: "2.3.0", commitsAhead: 1),
                                              status: .latest), "2.3.0 · up to date")
        XCTAssertEqual(VoiceBarBuildLine.text(installed: installed, describe: .init(releaseVersion: "2.3.0", commitsAhead: 0),
                                              status: .latest), "2.3.0 · up to date")
        XCTAssertEqual(VoiceBarBuildLine.text(installed: installed, describe: ahead, status: .available("2.3.1")),
                       "2.3.0 · update available: 2.3.1", "an available update outranks local commits")
        XCTAssertEqual(VoiceBarBuildLine.text(installed: installed, describe: nil, status: nil), "2.3.0")
        XCTAssertEqual(VoiceBarBuildLine.text(installed: installed, describe: nil, status: .ahead(latest: "2.2.61")),
                       "2.3.0 · ahead of release 2.2.61")
    }

    func testCheckForUpdatesFindsAnAvailableReleaseAndItsNotes() async {
        let check = VoiceBarVersionCheck(fetch: { [cask = cask("2.3.1")] in cask })
        let controller = NotchUpdateController(
            installed: .init(version: "2.3.0", commit: "abcdef1"), describe: nil, check: check,
            launcher: FakeLauncher(), isDictating: { false }
        )
        await controller.checkForUpdates()
        XCTAssertEqual(controller.phase, .available(version: "2.3.1"))
        XCTAssertEqual(controller.availableVersion, "2.3.1")
        XCTAssertTrue(controller.canUpdate)
        XCTAssertEqual(NotchUpdateController.releaseNotesURL(version: "2.3.1")?.absoluteString,
                       "https://github.com/EtanHey/voicelayer/releases/tag/v2.3.1")
        XCTAssertEqual(controller.buildLine, "2.3.0 · update available: 2.3.1")
    }

    func testTheButtonSkipsTheSixHourCache() async {
        final class Box: @unchecked Sendable { var version = "2.3.0"; var fetches = 0 }
        let box = Box()
        let check = VoiceBarVersionCheck(fetch: { box.fetches += 1; return "cask \"voicebar\" do\n  version \"\(box.version)\"\nend\n" })
        let controller = NotchUpdateController(installed: .init(version: "2.3.0", commit: nil), describe: nil,
                                               check: check, launcher: FakeLauncher(), isDictating: { false })
        await controller.checkForUpdates(force: false)
        XCTAssertEqual(controller.phase, .upToDate)
        box.version = "2.3.2"
        await controller.checkForUpdates(force: false)
        XCTAssertEqual(controller.phase, .upToDate, "opening the drawer again reuses the cache")
        await controller.checkForUpdates()
        XCTAssertEqual(controller.phase, .available(version: "2.3.2"), "the button asks again")
        XCTAssertEqual(box.fetches, 2)
    }

    func testUpdateNeverStartsWhileDictatingAndCanBePressedAgainAfter() async {
        var dictating = true
        let launcher = FakeLauncher()
        let controller = NotchUpdateController(
            installed: .init(version: "2.3.0", commit: nil), describe: nil,
            check: VoiceBarVersionCheck(fetch: { [cask = cask("2.4.0")] in cask }),
            launcher: launcher, isDictating: { dictating }
        )
        await controller.checkForUpdates()
        controller.update()
        XCTAssertEqual(launcher.launches, 0)
        XCTAssertEqual(controller.phase, .refused(NotchUpdateController.dictatingRefusal))
        XCTAssertTrue(controller.canUpdate, "the available release is kept")
        dictating = false
        controller.update()
        XCTAssertEqual(launcher.launches, 1)
        XCTAssertEqual(controller.phase, .updating)
        controller.update()
        XCTAssertEqual(launcher.launches, 1, "one updater at a time")
    }

    func testNoUpdaterOrAFailedLaunchSaysSo() async {
        let launcher = FakeLauncher()
        launcher.isAvailable = false
        let controller = NotchUpdateController(
            installed: .init(version: "2.3.0", commit: nil), describe: nil,
            check: VoiceBarVersionCheck(fetch: { [cask = cask("2.4.0")] in cask }),
            launcher: launcher, isDictating: { false }
        )
        await controller.checkForUpdates()
        XCTAssertFalse(controller.canUpdate)
        controller.update()
        XCTAssertEqual(controller.phase, .refused(NotchUpdateController.noUpdaterRefusal))
        launcher.isAvailable = true
        launcher.fails = true
        controller.update()
        guard case .refused = controller.phase else { return XCTFail("a failed launch is reported") }
    }

    func testOfflineIsCouldNotCheck() async {
        let controller = NotchUpdateController(
            installed: .init(version: "2.3.0", commit: nil), describe: nil,
            check: VoiceBarVersionCheck(fetch: { throw URLError(.notConnectedToInternet) }),
            launcher: FakeLauncher(), isDictating: { false }
        )
        await controller.checkForUpdates()
        XCTAssertEqual(controller.phase, .couldNotCheck)
        XCTAssertFalse(controller.canUpdate)
    }

    /// The launcher runs `voicelayer update` detached from VoiceBar (the updater restarts VoiceBar).
    func testTheLauncherRunsTheSameVoicelayerUpdateDetached() throws {
        final class Recorder: @unchecked Sendable { var calls: [(String, [String], [String: String])] = [] }
        let recorder = Recorder()
        let launcher = VoiceBarUpdateLauncher(
            fileExists: { $0 == "/opt/homebrew/bin/voicelayer" },
            run: { recorder.calls.append(($0, $1, $2)) }
        )
        XCTAssertEqual(launcher.cliPath, "/opt/homebrew/bin/voicelayer")
        try launcher.launch()
        let call = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(call.0, "/bin/bash")
        XCTAssertEqual(call.1[0], "-c")
        XCTAssertTrue(call.1[1].hasPrefix("nohup \"$0\" update "))
        XCTAssertTrue(call.1[1].hasSuffix("&"), "the shell returns at once; launchd adopts the updater")
        XCTAssertEqual(call.1[2], "/opt/homebrew/bin/voicelayer")
        XCTAssertEqual(call.1[3], VoiceBarUpdateLauncher.logPath)
        XCTAssertFalse(call.1[1].contains("--dry-run"))
        XCTAssertTrue(call.2["PATH"]?.hasPrefix("/opt/homebrew/bin") == true)
        XCTAssertFalse(VoiceBarUpdateLauncher(fileExists: { _ in false }).isAvailable)
    }
}
