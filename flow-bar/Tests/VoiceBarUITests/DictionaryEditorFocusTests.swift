import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// #968 CodeRabbit: in the drawer the Add/Edit editor covers the list with opacity, without disabling it. Opening the
/// editor while the search field has focus must take focus off that hidden field, or typed keys land in it.
@MainActor
final class DictionaryEditorFocusTests: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    func testOpeningTheEditorFromSearchLeavesTheHiddenSearchField() throws {
        let size = CGSize(width: SettingsDrawerLaneSSnapshotTests.drawerWidth,
                          height: NotchSettingsDrawerPresentation.lowerSurfaceHeight)
        let host = NSHostingView(rootView: DictionaryNotchTrackDShotsTests.drawer(.dark, sheet: nil)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        let window = KeyWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        window.makeKey()
        host.layoutSubtreeIfNeeded()
        wait { !self.editableFields(in: host).isEmpty }

        let fields = editableFields(in: host)
        XCTAssertEqual(fields.count, 1, "only the search field is editable before the editor opens")
        let search = try XCTUnwrap(fields.first)
        XCTAssertTrue(window.makeFirstResponder(search))
        drain(0.3)
        XCTAssertTrue(owns(search, window.firstResponder), "the search field has focus to start with")

        // Add term is the trailing capsule on the toolbar row under the tab bar (about x 368, 73 pt from the top in
        // the drawer's rendered shot); try a few points around it until a click opens the editor. Each click goes in
        // through the window, the way a pointer click does.
        var opened = false
        scan: for dy in [73.0, 69, 77] {
            for x in [368.0, 380, 356, 392] {
                click(NSPoint(x: x, y: size.height - dy), in: window)
                if editableFields(in: host).count > 1 { opened = true; break scan }
            }
        }
        XCTAssertTrue(opened, "a click on Add term opened the editor")
        wait { self.editableFields(in: host).count > 1 }
        XCTAssertGreaterThan(editableFields(in: host).count, 1, "the editor opened")
        drain(0.3)

        XCTAssertFalse(owns(search, window.firstResponder),
                       "the hidden search field keeps focus under the open editor: \(String(describing: window.firstResponder))")
    }

    /// The field itself, or the window's field editor while it edits that field.
    private func owns(_ field: NSTextField, _ responder: NSResponder?) -> Bool {
        if responder === field { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, editor.delegate === field { return true }
        return false
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        // Enabled too: since go-1126 vl-swipe every Settings pane stays laid out beside the one shown, and the ones a
        // tab or more away are disabled, so their fields take no focus or keys.
        if let field = view as? NSTextField, field.isEditable, field.isEnabled, !field.isHiddenOrHasHiddenAncestor {
            found.append(field)
        }
        for subview in view.subviews { found += editableFields(in: subview) }
        return found
    }

    private func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { return XCTFail("could not build \(type)") }
            window.sendEvent(event)
        }
        drain(0.08)
    }

    private func drain(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func wait(_ condition: () -> Bool, seconds: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { drain() }
    }
}
