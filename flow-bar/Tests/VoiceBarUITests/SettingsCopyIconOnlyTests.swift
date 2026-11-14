import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// QA-20, 2026-11-02 and QA-03: shared copy controls use a bare icon and tooltip,
/// avoiding duplicate or ambiguous text controls; the tooltip
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
