import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest
@MainActor final class NotchDictionaryR2Tests: XCTestCase {
    func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/" + name + ".swift"))
    }
    func testDictionaryMenuHidesOnlyItsIndicator() throws {
        let settings = try source("SettingsView")
        let menu = try XCTUnwrap(settings.components(separatedBy: "// Only the selected row contributes action stops.").last)
        let row = menu.components(separatedBy: ".help(isEditable")[0]
        XCTAssertTrue(row.contains("Menu {"))
        XCTAssertTrue(row.contains(#"Image(systemName: "ellipsis")"#))
        XCTAssertTrue(row.contains(".menuIndicator(.hidden)"))
        XCTAssertTrue(row.contains(".focusable(isSelected, interactions: .edit)"))
    }
}
