import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchLookTests: XCTestCase {
    func testTranscribingHugsTwoControlsAtEveryCalibration() {
        for inset: CGFloat in [0, 12, 24] {
            let p = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
                mode: .transcribing, visibleCoreOcclusionInset: inset))
            XCTAssertEqual(p.geometry.leadingWingWidth, 70, "owner r2: the launcher's left wing, chevron on the rule")
            XCTAssertEqual(p.geometry.trailingWingWidth, 73.5)
        }
    }

    func testTranscribingRoutesHistoryAndSettingsAndDropsMeter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"))
        let meter = try XCTUnwrap(bar.components(separatedBy: "private var showsRecordingMeterRow: Bool").last)
            .components(separatedBy: "private var recordingMeterRow")[0]
        XCTAssertFalse(meter.contains("state.mode == .transcribing"))
        let compact = try XCTUnwrap(bar.components(separatedBy: "private var notchCompactStatusContent").last)
            .components(separatedBy: "case .speaking:")[0]
        XCTAssertTrue(compact.contains("historyButton"))
        XCTAssertTrue(compact.contains("settingsButton"))
        let app = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBar/VoiceBarApp.swift"))
        let config = try XCTUnwrap(app.components(separatedBy: "static func notchInteractionConfiguration(").last?.components(separatedBy: "case .transcribing:").dropFirst().first)
            .components(separatedBy: "case .speaking:")[0]
        XCTAssertTrue(config.contains("trailingControlCountFromCore: 2"))
        XCTAssertFalse(app.contains("holdsRecordingWings: voiceState.mode == .transcribing"))
    }
}
