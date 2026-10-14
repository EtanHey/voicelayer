import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// The sidebar draws its own white-on-accent selection (P07 R5), so it must still behave like the native
/// `List(selection:)` it replaced: ↑/↓ move between tabs and the selected row is reported as selected.
@MainActor
final class SettingsSidebarAccessibilityTests: XCTestCase {
    private final class SelectionBox {
        var tab: SettingsTab = .general
    }

    func testArrowKeysMoveTheSidebarSelectionAndTheRowReportsSelected() throws {
        let box = SelectionBox()
        let footer = VoiceBarFooterPresentation.resolve(
            isConnected: true, mode: .idle, captureLive: false,
            errorMessage: nil, remoteSTTConfigured: false, hasFreshHealth: true
        )
        let host = NSHostingView(rootView: SettingsNavigationShell(
            selection: Binding(get: { box.tab }, set: { box.tab = $0 }), footer: footer
        ) { Text("detail") }.frame(width: 780, height: 620))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        settle()
        let table = try XCTUnwrap(firstTable(in: host), "the sidebar must be a native table-backed List")
        XCTAssertTrue(window.makeFirstResponder(table))

        for expected in [SettingsTab.transcription, .dictionary, .speech, .history, .history] {
            try window.sendEvent(arrow(down: true, window: window))
            settle()
            XCTAssertEqual(box.tab, expected, "↓ must move the sidebar selection")
        }
        try window.sendEvent(arrow(down: false, window: window))
        settle()
        XCTAssertEqual(box.tab, .speech, "↑ must move the sidebar selection back")

        let speechRow = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .speech))
        XCTAssertEqual(table.selectedRow, speechRow)
        XCTAssertEqual(table.accessibilitySelectedRows()?.count, 1, "VoiceOver reads the selected row from here")
        XCTAssertEqual(table.rowView(atRow: speechRow, makeIfNecessary: false)?.isSelected, true)
        XCTAssertEqual(
            table.selectionHighlightStyle, .none,
            "the row's own white-on-accent pill is the only highlight; the native one would double it"
        )
    }

    func testStatusFooterIsAnAccessibleButtonOpeningGeneral() throws {
        let box = SelectionBox()
        box.tab = .history
        let footer = VoiceBarFooterPresentation.resolve(
            isConnected: true, mode: .idle, captureLive: false,
            errorMessage: nil, remoteSTTConfigured: false, hasFreshHealth: true
        )
        let host = NSHostingView(rootView: SettingsNavigationShell(
            selection: Binding(get: { box.tab }, set: { box.tab = $0 }), footer: footer
        ) { Text("detail") }.frame(width: 780, height: 620))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        settle()

        // SwiftUI's virtual AX descendants are absent for offscreen XCTest hosts. Exercise the
        // real button via mouse events, and pin its explicit accessible name in the shell contract.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SettingsNavigationShell.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Button {"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Open General settings\")"))
        XCTAssertFalse(source.contains(".animation("))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 86, y: 30), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
        settle()
        XCTAssertEqual(box.tab, .general)
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }

    private func arrow(down: Bool, window: NSWindow) throws -> NSEvent {
        let character = down ? "\u{F701}" : "\u{F700}"
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: down ? 125 : 126
        ))
    }
}
