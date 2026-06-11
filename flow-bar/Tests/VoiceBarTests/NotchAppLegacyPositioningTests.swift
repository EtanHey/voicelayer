@testable import VoiceBar
import XCTest

final class NotchAppLegacyPositioningTests: XCTestCase {
    func testVoiceBarAppDoesNotRetainLegacyVisibleFrameOrVerticalOffsetPath() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBar")
            .appendingPathComponent("VoiceBarApp.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(source.contains("voicebar.verticalOffset"))
        XCTAssertFalse(source.contains("verticalOffset"))
        XCTAssertFalse(source.contains("visibleFrame"))
        XCTAssertFalse(source.contains("savePanelPosition"))
    }
}
