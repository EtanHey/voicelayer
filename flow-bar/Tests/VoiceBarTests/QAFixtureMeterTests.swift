import XCTest
@testable import VoiceBar
@testable import VoiceBarUI

@MainActor final class QAFixtureMeterTests: XCTestCase {
    func testFixtureMeterRequiresBothCandidateIdentityAndExplicitFlag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gate").path
        try Data(#"{"version":1,"kind":"OPEN","generation":0,"released":null}"#.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.createDirectory(atPath: path + ".admissions", withIntermediateDirectories: false)
        for (bundle, flag, expected) in [("com.voicelayer.voicebar.qa23", "1", true),
                                         ("com.voicelayer.voicebar.qa23", "0", false),
                                         ("com.voicelayer.voicebar.qa23", "", false),
                                         ("com.voicelayer.voicebar", "1", false)] {
            let app = AppDelegate(), original = UIE2ENoDeviceLevelEngine(), fixture = UIE2ENoDeviceLevelEngine()
            app.configureAudioLevelMonitoringForTesting(engine: original)
            let enabled = app.configureQAFixtureMeter(bundleIdentifier: bundle,
                environment: flag.isEmpty ? [:] : ["VOICEBAR_QA_FIXTURE_RECORDER": flag], engine: fixture)
            XCTAssertEqual(enabled, expected)
            app.startAudioLevelMonitoring(gate: NativeUpdateGate(path: path))
            XCTAssertEqual(fixture.starts, expected ? 1 : 0)
            XCTAssertEqual(original.starts, expected ? 0 : 1)
            app.stopAudioLevelMonitoring()
        }
    }
}
