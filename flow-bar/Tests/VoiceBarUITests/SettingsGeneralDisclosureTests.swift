import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Etan's 2.2.24 review #4: "All permissions granted" hid the rows behind a caret-only
/// DisclosureGroup, the annoyance BrainBar fixed in brainlayer #889 (the whole row is the
/// button) and #920 (Settings rows are flat, with no disclosure at all).
@MainActor
final class SettingsGeneralDisclosureTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for window in windows {
                window.isReleasedWhenClosed = false
                window.orderOut(nil)
                window.close()
            }
            windows.removeAll()
        }
        super.tearDown()
    }

    func testPermissionsAreAlwaysFlatRowsWithNoDisclosure() throws {
        let source = try settingsViewSource()
        let section = try XCTUnwrap(
            source.components(separatedBy: "Section(\"Permissions\") {").dropFirst().first?
                .components(separatedBy: "visibilitySection").first
        )

        XCTAssertFalse(source.contains("All permissions granted"))
        XCTAssertFalse(source.contains("isPermissionsExpanded"))
        XCTAssertFalse(section.contains("DisclosureGroup"))
        XCTAssertFalse(section.contains("if allPermissionsGranted"))
        XCTAssertTrue(section.contains("permissionRows"))
    }

    func testGrantedPermissionRowsDropTheOpenButton() throws {
        let source = try settingsViewSource()
        let row = try XCTUnwrap(
            source.components(separatedBy: "private func permissionRow(").dropFirst().first?
                .components(separatedBy: "private var permissionRows").first
        )

        XCTAssertTrue(row.contains("if !isGranted"))
        XCTAssertTrue(row.contains("Button(\"Open\")"))
    }

    func testAdvancedIsAFullRowDisclosure() throws {
        let source = try settingsViewSource()

        XCTAssertFalse(source.contains("DisclosureGroup"))
        XCTAssertTrue(source.contains("SettingsDisclosureRow(\"Advanced\", isExpanded: $isAdvancedExpanded)"))
    }

    func testAdvancedCopyIsPlain() throws {
        let source = try settingsViewSource()

        XCTAssertFalse(VoiceBarHotkeyContract.remapPlainSummary.contains("com.voicelayer"))
        XCTAssertFalse(VoiceBarHotkeyContract.remapPlainSummary.contains("launch agent"))
        XCTAssertFalse(VoiceBarHotkeyContract.remapPlainSummary.contains("F18"))
        // The technical chain stays available, as a tooltip only.
        XCTAssertFalse(source.contains("Text(VoiceBarHotkeyContract.remapExplanation)"))
        XCTAssertTrue(source.contains(".help(VoiceBarHotkeyContract.remapExplanation)"))
        XCTAssertTrue(source.contains("Text(VoiceBarHotkeyContract.remapPlainSummary)"))
        // "Installed" beside "Set up" contradicted itself.
        XCTAssertTrue(source.contains("isHotkeyRemapActive() ? \"Reinstall\" : \"Set up\""))
    }

    func testDisclosureRowTogglesFromAClickAnywhereOnTheRow() {
        var expanded = false
        let binding = Binding(get: { expanded }, set: { expanded = $0 })
        let host = host(SettingsDisclosureRow("Advanced", isExpanded: binding) { Text("Body") })

        // Far from the caret: the right end of the row, then the title text.
        click(host, at: NSPoint(x: host.bounds.maxX - 8, y: host.bounds.midY))
        XCTAssertTrue(expanded, "a click at the row's right end must expand it")
        click(host, at: NSPoint(x: 60, y: host.bounds.midY))
        XCTAssertFalse(expanded, "a click on the title must collapse it")
    }

    func testDisclosureRowReportsItsStateToAccessibility() throws {
        let source = try String(
            contentsOf: sourceRoot().appendingPathComponent("SettingsDisclosureRow.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".accessibilityValue(isExpanded ? \"Expanded\" : \"Collapsed\")"))
        XCTAssertTrue(source.contains(".contentShape(Rectangle())"))
        XCTAssertFalse(source.contains(".focusable()"))
    }

    // MARK: - Helpers

    private func host(_ view: some View) -> NSView {
        let host = NSHostingView(rootView: view.frame(width: 400, alignment: .topLeading))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 28)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        window.orderBack(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func click(_ host: NSView, at point: NSPoint) {
        guard let window = host.window else { return XCTFail("host has no window") }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { return XCTFail("could not build \(type)") }
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI")
    }

    private func settingsViewSource() throws -> String {
        try String(contentsOf: sourceRoot().appendingPathComponent("SettingsView.swift"), encoding: .utf8)
    }
}
