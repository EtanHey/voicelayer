import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class SettingsRS5BuildTests: XCTestCase {
    private let installed = VoiceBarInstalledVersion(version: "2.4.0", commit: "abcdef012345")

    func testOnlyAnExactCleanTagGetsThePlainReleaseDisplay() {
        let release = VoiceBarGitDescribe.parse("v2.4.0")
        XCTAssertEqual(release?.isTaggedRelease, true)
        XCTAssertEqual(VoiceBarBuildLine.displayText(installed: installed, describe: release, status: .latest), "2.4.0")
        XCTAssertEqual(SettingsVersionFooter.identity(installed: installed, describe: release), "VoiceBar 2.4.0")
        XCTAssertNil(VoiceBarBuildLine.menuStatus(installed: installed, describe: release, status: .latest))
        for text in ["v2.4.0-dirty", "v2.4.0-0-gabcdef0", "v2.4.0-1-gabcdef0", "unknown"] {
            let describe = VoiceBarGitDescribe.parse(text)
            XCTAssertNotEqual(describe?.isTaggedRelease, true, text)
            XCTAssertTrue(VoiceBarBuildLine.displayText(installed: installed, describe: describe, status: .latest).contains("abcdef0"), text)
            XCTAssertTrue(SettingsVersionFooter.identity(installed: installed, describe: describe).contains("abcdef0"), text)
            XCTAssertTrue(VoiceBarBuildLine.menuStatus(installed: installed, describe: describe, status: .latest)?.contains("abcdef0") == true, text)
        }
    }

    func testTaggedReleaseControllerUsesThePlainDisplay() async {
        let controller = NotchUpdateController(installed: installed,
            describe: .init(releaseVersion: "2.4.0", commitsAhead: 0),
            check: VoiceBarVersionCheck(fetch: { "cask \"voicebar\" do\n version \"2.4.0\"\nend\n" }),
            launcher: NoLauncher(), isDictating: { false })
        await controller.checkForUpdates()
        XCTAssertEqual(controller.buildLine, "2.4.0")
        XCTAssertEqual(NotchSettingsDrawerPresentation.displayUpdateStatus(.ahead(latest: "2.3.0"), describe: controller.describe),
                       "No newer release is available.")
    }

    private struct NoLauncher: VoiceBarUpdateLaunching {
        let isAvailable = false
        func launch() { XCTFail("Rendering build identity must not launch an update") }
    }

    func testCandidateCountAndShaReachAllThreeSurfaces() {
        let describe = VoiceBarGitDescribe(releaseVersion: "2.3.0", commitsAhead: 14)
        for status in [VoiceBarVersionStatus.latest, .ahead(latest: "2.3.0"), .checking, .couldNotCheck] {
            XCTAssertEqual(VoiceBarBuildLine.displayText(installed: installed, describe: describe, status: status),
                           "2.4.0 · abcdef0 · ahead of release by 14 commits")
            XCTAssertEqual(SettingsVersionFooter.statusText(status, describe: describe), "Ahead of release by 14 commits")
            XCTAssertEqual(PillContextMenuController.versionLine(version: "2.4.0",
                updateStatus: VoiceBarBuildLine.menuStatus(installed: installed, describe: describe, status: status)),
                           "VoiceBar 2.4.0 · abcdef0 · ahead of release by 14 commits")
        }
        XCTAssertEqual(VoiceBarBuildLine.menuStatus(installed: installed, describe: describe, status: .available("2.4.1")),
                       "abcdef0 · update available: 2.4.1", "Keep the candidate's available-update priority")
    }

    func testVersionFooterRendersFullCandidateIdentityAndPlainRelease() throws {
        let installed = VoiceBarInstalledVersion(version: "2.4.0", commit: "123456789abc")
        for (name, describe) in [("candidate", VoiceBarGitDescribe(releaseVersion: "2.3.0", commitsAhead: 14)),
                                 ("release", VoiceBarGitDescribe(releaseVersion: "2.4.0", commitsAhead: 0))] {
            let bitmap = try SettingsPolishS5Tests.render(SettingsVersionFooter(installed: installed, status: .latest, describe: describe),
                width: 172, height: 100, name: "version-\(name)-sidebar")
            let text = try SettingsPolishS5Tests.ocr(bitmap).joined(separator: " ")
            XCTAssertTrue(text.contains("2.4.0"))
            XCTAssertEqual(text.contains("1234567"), name == "candidate")
            XCTAssertEqual(text.contains("14 commits"), name == "candidate")
            let menuLine = PillContextMenuController.versionLine(version: "2.4.0",
                updateStatus: VoiceBarBuildLine.menuStatus(installed: installed, describe: describe, status: .latest))
            let item = PillContextMenuController.versionItem(menuLine)
            _ = try SettingsPolishS5Tests.render(NativeVersionRow(view: try XCTUnwrap(item.view)),
                width: 620, height: 50, name: "version-\(name)-menu")
        }
    }

    func testConfiguredAndMeasuredEngineNamesShareOneVoiceKind() {
        for name in ["edge", "edge-tts"] { XCTAssertEqual(SpeechControlsState.voiceKindLabel(name), "Fast voice") }
        for name in ["clone", "xtts-v2", "qwen3-tts"] {
            XCTAssertEqual(SpeechControlsState.voiceKindLabel(name), "Cloned voice")
        }
    }

    private struct NativeVersionRow: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }
}
