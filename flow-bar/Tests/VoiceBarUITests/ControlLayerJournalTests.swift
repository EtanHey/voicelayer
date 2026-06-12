@testable import VoiceBarUI
import XCTest

final class ControlLayerJournalTests: XCTestCase {
    func testMarkerTagMatchesTypeScriptTopicCanonicalization() {
        XCTAssertEqual(ControlLayerJournal.markerTag(for: "voice.paste"), "voice_paste")
        XCTAssertEqual(ControlLayerJournal.markerTag(for: "a..b"), "a_b")
        XCTAssertEqual(ControlLayerJournal.markerTag(for: "a._.b"), "a___b")
        XCTAssertEqual(ControlLayerJournal.markerTag(for: "__voice--health__"), "voice--health")
        XCTAssertEqual(ControlLayerJournal.markerTag(for: "voice.\u{05E9}\u{05DC}\u{05D5}\u{05DD}"), "voice")
        XCTAssertEqual(ControlLayerJournal.markerTag(for: "..."), "root")
    }
}
