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

    func testKarabinerRuleDoesNotOwnPlainF6HoldToRecord() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ruleURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("karabiner")
            .appendingPathComponent("voicebar-f6.json")

        let data = try Data(contentsOf: ruleURL)
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(object as? [String: Any])
        let manipulators = try XCTUnwrap(root["manipulators"] as? [[String: Any]])
        let plainF6 = manipulators.first { manipulator in
            guard let from = manipulator["from"] as? [String: Any] else { return false }
            let modifiers = from["modifiers"] as? [String: Any]
            return from["key_code"] as? String == "f6"
                && modifiers == nil
                && (manipulator["to_after_key_up"] as? [[String: Any]]) != nil
        }

        XCTAssertNil(
            plainF6,
            "Plain F6 should be owned by the native hotkey manager, not Karabiner socket start/stop commands"
        )
    }

    func testKarabinerRuleMapsDoNotDisturbConsumerKeyToInternalF18Relay() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ruleURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("karabiner")
            .appendingPathComponent("voicebar-f6.json")

        let data = try Data(contentsOf: ruleURL)
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(object as? [String: Any])
        let manipulators = try XCTUnwrap(root["manipulators"] as? [[String: Any]])
        let consumerMapping = manipulators.first { manipulator in
            guard let from = manipulator["from"] as? [String: Any],
                  from["consumer_key_code"] as? String == "do_not_disturb",
                  from["modifiers"] == nil,
                  let to = manipulator["to"] as? [[String: Any]],
                  let firstTo = to.first else { return false }
            return firstTo["key_code"] as? String == "f18"
        }

        XCTAssertNotNil(
            consumerMapping,
            "The shipped Karabiner rule should translate the hardware Do Not Disturb key into an internal F18 relay for VoiceBar"
        )
    }

    func testKarabinerRuleMapsPlainF6ToInternalF18Relay() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ruleURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("karabiner")
            .appendingPathComponent("voicebar-f6.json")

        let data = try Data(contentsOf: ruleURL)
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(object as? [String: Any])
        let manipulators = try XCTUnwrap(root["manipulators"] as? [[String: Any]])
        let relayMapping = manipulators.first { manipulator in
            guard let from = manipulator["from"] as? [String: Any],
                  from["key_code"] as? String == "f6",
                  from["modifiers"] == nil,
                  let to = manipulator["to"] as? [[String: Any]],
                  let firstTo = to.first else { return false }
            return firstTo["key_code"] as? String == "f18"
        }

        XCTAssertNotNil(
            relayMapping,
            "The shipped Karabiner rule should translate plain F6 into the same internal F18 relay for VoiceBar"
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
