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
        let previousWindowsMenu = application.windowsMenu
        application.delegate = delegate
        VoiceBarMainMenu.install(appDelegate: delegate)
        defer {
            delegate.settingsWindowForTesting?.close()
            application.delegate = previousDelegate
            application.mainMenu = previousMenu
            application.windowsMenu = previousWindowsMenu
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

    @MainActor
    func testStandardEditingAndWindowShortcutsRemainAvailable() throws {
        let application = NSApplication.shared
        let previousWindowsMenu = application.windowsMenu
        let previousMenu = application.mainMenu
        defer {
            application.mainMenu = previousMenu
            application.windowsMenu = previousWindowsMenu
        }
        let delegate = AppDelegate()
        VoiceBarMainMenu.install(appDelegate: delegate)
        let menu = try XCTUnwrap(application.mainMenu)
        let edit = try XCTUnwrap(menu.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let window = try XCTUnwrap(menu.item(withTitle: "Window")?.submenu)
        XCTAssertTrue(application.windowsMenu === window)
        for (parent, title, action, key, modifiers) in [
            (edit, "Undo", "undo:", "z", NSEvent.ModifierFlags.command),
            (edit, "Redo", "redo:", "z", [.command, .shift]),
            (window, "Close", "performClose:", "w", .command),
            (window, "Minimize", "performMiniaturize:", "m", .command),
        ] {
            let item = try XCTUnwrap(parent.item(withTitle: title))
            XCTAssertEqual(item.action, NSSelectorFromString(action))
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers)
            XCTAssertNil(item.target, "Shortcut must follow the active window or field editor")
        }
    }
}
