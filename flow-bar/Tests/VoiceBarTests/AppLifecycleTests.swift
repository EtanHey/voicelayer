@testable import VoiceBar
import XCTest

final class AppLifecycleTests: XCTestCase {
    // MARK: - Context menu snooze toggle

    func testContextMenuShowsHideWhenNotSnoozed() {
        let controller = PillContextMenuController()
        controller.isSnoozedProvider = { false }

        let menu = controller.makeMenu()
        let titles = (0 ..< menu.numberOfItems).compactMap { menu.item(at: $0)?.title }

        XCTAssertTrue(titles.contains("Hide for 1 hour"))
        XCTAssertFalse(titles.contains("Show VoiceBar"))
    }

    func testContextMenuShowsUnsnoozeWhenSnoozed() {
        let controller = PillContextMenuController()
        controller.isSnoozedProvider = { true }

        let menu = controller.makeMenu()
        let titles = (0 ..< menu.numberOfItems).compactMap { menu.item(at: $0)?.title }

        XCTAssertTrue(titles.contains("Show VoiceBar"))
        XCTAssertFalse(titles.contains("Hide for 1 hour"))
    }

    // MARK: - VoiceState snooze/unsnooze

    func testSnoozeSetsModeToDisconnected() {
        let state = VoiceState()
        state.mode = .idle

        state.snooze()

        XCTAssertEqual(state.mode, .disconnected)
    }

    func testUnsnoozeRestoresIdleMode() {
        let state = VoiceState()
        state.snooze()
        XCTAssertEqual(state.mode, .disconnected)

        state.unsnooze()

        XCTAssertEqual(state.mode, .idle)
    }

    func testUnsnoozeDoesNothingIfNotSnoozed() {
        let state = VoiceState()
        state.mode = .recording

        state.unsnooze()

        XCTAssertEqual(state.mode, .recording, "unsnooze should only act on .disconnected")
    }

    // MARK: - LaunchAgent plist validation

    func testLaunchAgentPlistExistsInRepo() {
        // Verify the fixed plist template is shipped in the repo
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VoiceBarTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // flow-bar/
            .deletingLastPathComponent() // voicelayer root
        let plistPath = repoRoot
            .appendingPathComponent("launchd")
            .appendingPathComponent("com.voicelayer.voicebar.plist")
            .path

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plistPath),
            "LaunchAgent plist should exist at launchd/com.voicelayer.voicebar.plist"
        )
    }

    func testLaunchAgentPlistUsesSuccessfulExitKeepAlive() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot
            .appendingPathComponent("launchd")
            .appendingPathComponent("com.voicelayer.voicebar.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any] else {
            XCTFail("Plist is not a dictionary")
            return
        }

        // KeepAlive should be a dict with SuccessfulExit, NOT a plain bool
        guard let keepAlive = dict["KeepAlive"] as? [String: Any] else {
            XCTFail("KeepAlive should be a dictionary, not a boolean — plain true causes respawn on Quit")
            return
        }

        let successfulExit = keepAlive["SuccessfulExit"] as? Bool
        XCTAssertEqual(successfulExit, false, "SuccessfulExit:false means only restart on crash, not clean quit")
    }

    func testF5HidutilLaunchAgentRunsMergeHelper() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot
            .appendingPathComponent("launchd")
            .appendingPathComponent("com.voicelayer.f5-to-f18-hidutil.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(plist as? [String: Any])
        let args = try XCTUnwrap(dict["ProgramArguments"] as? [String])

        XCTAssertEqual(dict["Label"] as? String, "com.voicelayer.f5-to-f18-hidutil")
        XCTAssertEqual(args.prefix(2), ["/bin/sh", "-c"])

        let command = try XCTUnwrap(args.last)
        XCTAssertTrue(
            command.contains("apply-voicebar-f5-hidutil.sh"),
            "LaunchAgent should run the helper that preserves non-VoiceBar hidutil mappings"
        )
    }

    func testF5HidutilHelperMapsDictationToF18AndFiltersStaleF5() throws {
        // Architecture: only the Apple Dictation consumer key (0xC000000CF)
        // is remapped to F18 globally. The physical F5 (0x70000003E) is
        // intentionally NOT pushed — VoiceBar's CGEventTap listens for keycode
        // 96 directly. A global F5 -> F18 remap would hide F5 from the OS
        // for every app, breaking system chords like Cmd+F5 (VoiceOver).
        // F5_SRC_DEC stays in the filter set to clean up stale F5 -> F18
        // entries from earlier VoiceBar installs.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperURL = repoRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("apply-voicebar-f5-hidutil.sh")

        let helper = try String(contentsOf: helperURL)
        XCTAssertTrue(
            helper.contains("30064771134"),
            "F5 source must remain referenced so the filter strips stale F5 -> F18 entries"
        )
        XCTAssertTrue(
            helper.contains("51539607759"),
            "Apple Dictation source must be remapped to F18"
        )
        XCTAssertTrue(
            helper.contains("30064771181"),
            "F18 destination must be present"
        )
        XCTAssertTrue(
            helper.contains("preserved.push"),
            "helper must merge VoiceBar's Dictation entry with existing user mappings"
        )
    }

    func testHotkeyEventFromSameSourceIsAllowedWhenNoOverlapExists() {
        let now = 10.0

        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .legacySocket,
                gestureState: .idle,
                activeHotkeySource: nil,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .native,
                gestureState: .idle,
                activeHotkeySource: nil,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
    }

    func testHotkeyEventFromOtherSourceIsIgnoredWhileGestureIsActive() {
        let now = 10.0

        XCTAssertTrue(
            shouldIgnoreHotkeyEvent(
                source: .legacySocket,
                gestureState: .pressing,
                activeHotkeySource: .native,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
        XCTAssertTrue(
            shouldIgnoreHotkeyEvent(
                source: .native,
                gestureState: .holding,
                activeHotkeySource: .legacySocket,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
    }

    func testHotkeyEventFromOwningSourceIsAllowedWhileGestureIsActive() {
        let now = 10.0

        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .legacySocket,
                gestureState: .waitingForDoubleTap,
                activeHotkeySource: .legacySocket,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .native,
                gestureState: .holding,
                activeHotkeySource: .native,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
    }

    func testHotkeyEventFromOtherSourceIsIgnoredShortlyAfterRecentAcceptedActivity() {
        let now = 10.0

        XCTAssertTrue(
            shouldIgnoreHotkeyEvent(
                source: .legacySocket,
                gestureState: .idle,
                activeHotkeySource: nil,
                lastHotkeyActivityAt: 9.5,
                lastHotkeyActivitySource: .native,
                now: now
            )
        )
        XCTAssertTrue(
            shouldIgnoreHotkeyEvent(
                source: .native,
                gestureState: .idle,
                activeHotkeySource: nil,
                lastHotkeyActivityAt: 9.5,
                lastHotkeyActivitySource: .legacySocket,
                now: now
            )
        )
    }

    func testHotkeyEventFromSameRecentSourceIsNotIgnored() {
        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .native,
                gestureState: .idle,
                activeHotkeySource: .native,
                lastHotkeyActivityAt: 10.0,
                lastHotkeyActivitySource: .native,
                now: 10.2
            )
        )
        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .legacySocket,
                gestureState: .idle,
                activeHotkeySource: nil,
                lastHotkeyActivityAt: 10.0,
                lastHotkeyActivitySource: .legacySocket,
                now: 10.2
            )
        )
    }
}
