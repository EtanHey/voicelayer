import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class DictationShortcutAlignmentTests: XCTestCase {
    func testSettingsWindowAlignsDictationShortcut() throws {
        try assertAligned(SettingsDrawerLaneSSnapshotTests.pane(.general, advanced: false),
                          width: 860, surface: "window")
    }

    func testNotchDrawerAlignsDictationShortcut() throws {
        try assertAligned(SettingsDrawerLaneSSnapshotTests.drawer(.general, updates: nil),
                          width: 420, surface: "drawer")
    }

    private func assertAligned(_ view: some View, width: CGFloat, surface: String) throws {
        var titleFrame: CGRect?
        var controls: [String: CGRect] = [:]
        let instrumented = view
            .onPreferenceChange(SettingsTextAuditKey.self) { entries in
                titleFrame = entries.first { $0.text == SettingsGeneralCopy.dictationKeyTitle }?.frame
            }
            .onPreferenceChange(SettingsControlFrameKey.self) { controls = $0 }

        let screenshot = ProcessInfo.processInfo.environment["S5_OUTPUT"] == nil ? nil : surface
        _ = try SettingsPolishS5Tests.render(instrumented, width: width, height: 960, name: screenshot)
        let label = try XCTUnwrap(titleFrame)
        let keyCap = try XCTUnwrap(controls["dictation-key-cap"])
        let button = try XCTUnwrap(controls["dictation-key-check"])
        print("\(surface) vertical centres (pt): label=\(label.midY), cap=\(keyCap.midY), button=\(button.midY)")
        XCTAssertGreaterThan(keyCap.minX, label.maxX)
        XCTAssertGreaterThan(button.minX, keyCap.maxX)
        let centres = [label.midY, keyCap.midY, button.midY]
        XCTAssertLessThanOrEqual(try XCTUnwrap(centres.max()) - XCTUnwrap(centres.min()), 0.5, surface)
    }
}
