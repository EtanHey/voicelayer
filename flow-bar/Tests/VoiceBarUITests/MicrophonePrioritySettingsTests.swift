@testable import VoiceBarUI
import XCTest

/// Etan's 2.2.24 review #5: "make default on click, or drag to reorder, instead of up/up/up arrows".
/// SwiftUI builds no drag session or AX tree offscreen, so the layout is pinned here and the ordering
/// logic is covered behaviourally in MicrophonePrioritySnapshotTests.
final class MicrophonePrioritySettingsTests: XCTestCase {
    func testArrowsAreReplacedByMakeDefaultAndDrag() throws {
        let section = try prioritySection()

        XCTAssertFalse(section.contains("chevron.up"))
        XCTAssertFalse(section.contains("chevron.down"))
        XCTAssertFalse(section.contains("Use the arrows"))
        XCTAssertTrue(section.contains("Button(\"Make default\")"))
        XCTAssertTrue(section.contains("makeMicrophoneDefault(at: index)"))
        XCTAssertTrue(section.contains(".draggable(uid)"))
        XCTAssertTrue(section.contains(".dropDestination(for: String.self)"))
        XCTAssertTrue(section.contains("Image(systemName: \"line.3.horizontal\")"))
    }

    func testFirstRowIsMarkedDefaultInsteadOfOfferingTheButton() throws {
        let section = try prioritySection()

        XCTAssertTrue(section.contains("if index == 0"))
        XCTAssertTrue(section.contains("Text(\"Default\")"))
    }

    func testReorderingStaysReachableWithoutAPointer() throws {
        let section = try prioritySection()

        XCTAssertTrue(section.contains(".accessibilityAction(named: \"Make default\")"))
        XCTAssertTrue(section.contains(".accessibilityAction(named: \"Move up\")"))
        XCTAssertTrue(section.contains(".accessibilityAction(named: \"Move down\")"))
    }

    func testEveryGestureWritesThroughTheSnapshotOrdering() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("microphoneSnapshot.makingDefaultUIDs(at: index)"))
        XCTAssertTrue(source.contains("microphoneSnapshot.movingVisibleUIDs("))
    }

    // MARK: - Helpers

    private func prioritySection() throws -> String {
        let source = try settingsViewSource()
        return try XCTUnwrap(
            source.components(separatedBy: "private var microphonePrioritySection: some View {").dropFirst().first?
                .components(separatedBy: "private func refreshMicrophoneSnapshot()").first
        )
    }

    private func settingsViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
