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

    func testKarabinerRuleDoesNotMatchShiftF6AsPlainHoldToRecord() throws {
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
        let plainF6 = try XCTUnwrap(manipulators.first { manipulator in
            guard let from = manipulator["from"] as? [String: Any] else { return false }
            return from["key_code"] as? String == "f6"
                && (manipulator["to_after_key_up"] as? [[String: Any]]) != nil
        })
        let from = try XCTUnwrap(plainF6["from"] as? [String: Any])
        let modifiers = from["modifiers"] as? [String: Any]

        XCTAssertNil(
            modifiers?["optional"],
            "Plain F6 hold-to-record must not use optional:any because Shift+F6 is reserved for re-paste"
        )
    }
}
