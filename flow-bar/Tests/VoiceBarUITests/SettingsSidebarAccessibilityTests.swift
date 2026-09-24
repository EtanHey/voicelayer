@testable import VoiceBarUI
import XCTest

/// The sidebar draws its own white-on-accent selection (P07 R5), so it must still tell VoiceOver which tab
/// is selected and move between tabs with the arrow keys, as the native `List(selection:)` did.
final class SettingsSidebarAccessibilityTests: XCTestCase {
    // AIDEV-NOTE: SwiftUI materialises its accessibility tree only for a live AX client, so an offscreen
    // host exposes a single AXGroup and the trait cannot be observed in-process. The wiring is pinned in
    // source here; the VoiceOver announcement itself is a P10 installed-app check.
    func testSelectedSidebarRowCarriesTheSelectedTraitAndArrowKeysMoveSelection() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SettingsNavigationShell.swift"))

        XCTAssertTrue(source.contains(".accessibilityAddTraits(selection == tab ? .isSelected : [])"))
        XCTAssertTrue(source.contains(".onMoveCommand { selection = selection.moved($0) }"))
    }

    func testArrowKeysMoveBetweenTabsAndStopAtTheEnds() {
        XCTAssertEqual(SettingsTab.general.moved(.down), .models)
        XCTAssertEqual(SettingsTab.models.moved(.down), .dictionary)
        XCTAssertEqual(SettingsTab.history.moved(.down), .history)
        XCTAssertEqual(SettingsTab.models.moved(.up), .general)
        XCTAssertEqual(SettingsTab.general.moved(.up), .general)
        XCTAssertEqual(SettingsTab.dictionary.moved(.left), .dictionary)
    }
}
