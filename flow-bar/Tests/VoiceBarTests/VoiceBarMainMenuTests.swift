import AppKit
import SwiftUI
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class VoiceBarMainMenuTests: XCTestCase {
    @MainActor
    private func key(_ character: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                         timestamp: 0, windowNumber: 0, context: nil, characters: character,
                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
    }

    @MainActor
    func testCommandCommaOpensOwnedSettingsWithoutCreatingScene() throws {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        let previousDelegate = application.delegate
        let previousMenu = application.mainMenu
        application.delegate = delegate
        application.mainMenu = VoiceBarMainMenu.make(appDelegate: delegate)
        defer {
            delegate.settingsWindowForTesting?.close()
            application.delegate = previousDelegate
            application.mainMenu = previousMenu
        }
        XCTAssertTrue(try XCTUnwrap(application.mainMenu?.performKeyEquivalent(with: key(","))))
        let window = try XCTUnwrap(delegate.settingsWindowForTesting)
        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(window.contentViewController as? NSHostingController<SettingsView>)
        XCTAssertFalse(application.windows.contains {
            $0.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings") == true
        })
        window.close()
        XCTAssertTrue(try XCTUnwrap(application.mainMenu?.performKeyEquivalent(with: key(","))))
        XCTAssertTrue(window.isVisible, "Command-comma must rebuild and reopen owned Settings")
    }
}
