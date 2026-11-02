import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// QA-20 (Etan, 2026-11-02: "We don't need a copy word. The copy icon is very known") and QA-03
/// (two copy controls nobody could tell apart): every shared copy control is a bare icon whose tooltip
/// and VoiceOver label name what it copies.
@MainActor
final class SettingsCopyIconOnlyTests: XCTestCase {
    func testSharedCopyButtonRendersAsABareIcon() {
        let iconOnly = fittingWidth(SettingsCopyButton(text: "payload", label: "term payload"))
        let withWord = fittingWidth(Button {} label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(.borderless))
        XCTAssertGreaterThan(iconOnly, 0)
        XCTAssertLessThan(iconOnly, 30, "an icon is all that renders")
        XCTAssertLessThan(iconOnly + 15, withWord, "the word Copy is gone (word+icon is \(withWord) pt)")
    }

    func testTooltipNamesWhatIsCopied() {
        XCTAssertEqual(SettingsCopyButton.tooltip("transcript"), "Copy transcript")
        XCTAssertEqual(SettingsCopyButton.tooltip("recording ID"), "Copy recording ID")
    }

    private func fittingWidth<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }
}
