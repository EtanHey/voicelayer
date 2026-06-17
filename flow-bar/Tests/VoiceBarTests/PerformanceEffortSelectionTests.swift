@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class PerformanceEffortSelectionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "voicebar.performanceEffort")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "voicebar.performanceEffort")
        super.tearDown()
    }

    func testEffortSelectionWaitsForDaemonAcceptBeforePersisting() throws {
        let app = AppDelegate()
        var sentCommand: [String: Any]?
        app.voiceState.sendCommand = { sentCommand = $0 }

        app.selectPerformanceEffort(.fast)

        let id = try XCTUnwrap(sentCommand?["id"] as? String)
        XCTAssertEqual(sentCommand?["cmd"] as? String, "set_whisper_effort")
        XCTAssertEqual(sentCommand?["effort"] as? String, "fast")
        XCTAssertEqual(app.currentPerformanceEffort(), .fast)
        XCTAssertNil(UserDefaults.standard.string(forKey: "voicebar.performanceEffort"))

        app.voiceState.handleEvent([
            "type": "ack",
            "command": "set_whisper_effort",
            "outcome": "accept",
            "id": id,
        ])

        XCTAssertEqual(app.currentPerformanceEffort(), .fast)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "voicebar.performanceEffort"), "fast")
        XCTAssertNil(app.currentPerformanceEffortNotice())
    }

    func testEffortSelectionCommitsImmediatelyWithoutSecondClick() {
        let app = AppDelegate()
        var sentCommands: [[String: Any]] = []
        app.voiceState.sendCommand = { sentCommands.append($0) }

        app.selectPerformanceEffort(.fast)

        XCTAssertEqual(app.currentPerformanceEffort(), .fast)
        XCTAssertEqual(sentCommands.count, 1)

        app.selectPerformanceEffort(.fast)

        XCTAssertEqual(app.currentPerformanceEffort(), .fast)
        XCTAssertEqual(sentCommands.count, 1)
        XCTAssertNil(UserDefaults.standard.string(forKey: "voicebar.performanceEffort"))
    }

    func testRejectedEffortSelectionKeepsCurrentValueAndShowsNotice() throws {
        let app = AppDelegate()
        var sentCommand: [String: Any]?
        app.voiceState.sendCommand = { sentCommand = $0 }

        app.selectPerformanceEffort(.balanced)
        let id = try XCTUnwrap(sentCommand?["id"] as? String)
        app.voiceState.handleEvent([
            "type": "ack",
            "command": "set_whisper_effort",
            "outcome": "reject",
            "id": id,
            "reason": "busy",
        ])

        XCTAssertEqual(app.currentPerformanceEffort(), .accurate)
        XCTAssertNil(UserDefaults.standard.string(forKey: "voicebar.performanceEffort"))
        XCTAssertEqual(app.currentPerformanceEffortNotice(), "Couldn't change effort - busy, try again")
    }

    func testMissingCommandClientDoesNotPersistEffort() {
        let app = AppDelegate()

        app.selectPerformanceEffort(.fast)

        XCTAssertEqual(app.currentPerformanceEffort(), .accurate)
        XCTAssertNil(UserDefaults.standard.string(forKey: "voicebar.performanceEffort"))
        XCTAssertEqual(
            app.currentPerformanceEffortNotice(),
            "Couldn't change effort - VoiceLayer is starting, try again"
        )
    }
}
