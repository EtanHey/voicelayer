@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// Etan's D2 (2026-09-25): the only writer of the macOS default input is the microphone-priority apply. No UI
/// action may call `selectInputDevice`.
@MainActor
final class MicrophoneWritePathTests: XCTestCase {
    /// Opening Settings calls `NSApp.activate`; a filtered run has no application yet unless the fixture makes
    /// one (A4 review r1: the tests trapped when run on their own).
    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
    }

    private func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        return try files.map { try ($0.lastPathComponent, String(contentsOf: $0, encoding: .utf8)) }
    }

    func testOnlyThePriorityApplyWritesTheDefaultInput() throws {
        var callSites: [String] = []
        for (name, text) in try sources() {
            for line in text.components(separatedBy: .newlines) where line.contains("selectInputDevice(") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("public static func selectInputDevice(") { continue }
                callSites.append("\(name): \(trimmed)")
            }
        }

        XCTAssertEqual(callSites, ["VoiceBarApp.swift: MicrophoneDeviceManager.selectInputDevice(id: deviceID)"])
        let app = try XCTUnwrap(try sources().first { $0.name == "VoiceBarApp.swift" }?.text)
        let apply = try XCTUnwrap(app.range(of: "MicrophonePriorityApplyCoordinator("))
        let write = try XCTUnwrap(app.range(of: "MicrophoneDeviceManager.selectInputDevice(id: deviceID)"))
        let applyEnd = try XCTUnwrap(app.range(
            of: "private var microphonePriorityTimer",
            range: apply.upperBound ..< app.endIndex
        ))
        XCTAssertTrue(apply.upperBound <= write.lowerBound && write.upperBound <= applyEnd.lowerBound,
                      "the single write lives inside the priority apply coordinator")
        XCTAssertFalse(app.contains("func selectMicrophone("), "the direct picker write path is gone")
    }

    func testChangeOpensSettingsOnGeneralFocusedOnMicrophonePriority() {
        let app = AppDelegate()
        defer { app.settingsWindowForTesting?.close() }

        app.openMicrophonePrioritySettings()

        XCTAssertEqual(app.settingsTabRequestForTesting?.tab, .general)
        XCTAssertEqual(app.settingsTabRequestForTesting?.focus, .microphonePriority)
    }

    func testTheContextMenuShowsThePriorityDefaultAndChangeOpensTheList() {
        let app = AppDelegate()
        defer { app.settingsWindowForTesting?.close() }
        app.configurePillContextMenuForTesting()
        let controller = app.pillContextMenuControllerForTesting

        XCTAssertEqual(controller.defaultMicrophoneNameProvider(), app.defaultMicrophoneName())
        controller.onChangeMicrophone()
        XCTAssertEqual(app.settingsTabRequestForTesting?.focus, .microphonePriority)
    }
}
