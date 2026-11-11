import AppKit
import SwiftUI
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// 2.2.61 shipped a Dictionary search that never received pastes (UI assessment lesson). This hosts the real
/// Settings › Dictionary offscreen, focuses its search field and drives both paths into it:
/// ⌘V (the Edit menu's nil-target `paste:` reaching the field editor) and VoiceBar's own paste (P1's local field
/// adapter). It uses a private pasteboard only; the general pasteboard is never read or written.
@MainActor
final class DictionarySearchPasteTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func focusedSearchEditor() throws -> NSTextView {
        let settings = SettingsView(
            hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {}, vocabularyRevision: { 0 }, initialTab: .dictionary
        )
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 720, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: settings)
        window.contentView?.layoutSubtreeIfNeeded()
        self.window = window
        let field = try XCTUnwrap(Self.textFields(in: try XCTUnwrap(window.contentView)).first {
            $0.isEditable && ($0.placeholderString ?? $0.placeholderAttributedString?.string) == "Search terms and variants"
        }, "the Dictionary search is a real editable text field")
        XCTAssertTrue(window.makeFirstResponder(field))
        return try XCTUnwrap(window.firstResponder as? NSTextView, "focus lands in the field editor")
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        let own: [NSTextField] = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap { textFields(in: $0) }
    }

    func testCommandVReachesTheDictionarySearch() throws {
        let menu = VoiceBarMainMenu.make(appDelegate: AppDelegate())
        let edit = try XCTUnwrap(menu.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let paste = try XCTUnwrap(edit.item(withTitle: "Paste"))
        XCTAssertEqual(paste.keyEquivalent, "v")
        XCTAssertEqual(paste.action, NSSelectorFromString("paste:"))
        XCTAssertNil(paste.target, "nil target: ⌘V goes to whatever field has focus")

        let editor = try focusedSearchEditor()
        var responder: NSResponder? = window?.firstResponder
        while let current = responder, !current.responds(to: NSSelectorFromString("paste:")) {
            responder = current.nextResponder
        }
        XCTAssertTrue(responder === editor, "the focused search is the first responder that takes paste:")

        // What `paste:` does, from a private board instead of the general one.
        let board = NSPasteboard(name: NSPasteboard.Name("voicebar-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("kubectl", forType: .string)
        XCTAssertTrue(editor.readSelection(from: board, type: .string))
        XCTAssertEqual(editor.string, "kubectl")
    }

    func testVoiceBarsOwnPasteReachesTheDictionarySearch() throws {
        let editor = try focusedSearchEditor()
        XCTAssertTrue(editor.isEditable)
        XCTAssertFalse(LocalDictationTarget.eligibility(for: editor).isSecure)
        var results: [DictationInsertionResult] = []
        XCTAssertTrue(LocalDictationTarget.insertion(for: editor)("SwiftUI", { results.append($0) }))
        XCTAssertEqual(editor.string, "SwiftUI")
        XCTAssertEqual(results, [.verified])
    }
}
