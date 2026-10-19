import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class ModelsSettingsIntegrationTests: XCTestCase {
    func testResidencyControlFollowsFreshHealthAndBusyState() throws {
        let voiceState = VoiceState()
        voiceState.setConnectionStatus(true)
        voiceState.handleEvent(Self.availableHealth)
        let host = NSHostingView(rootView: makeSettingsView(
            voiceState: voiceState,
            onSelectResidency: { _ in }
        ))
        host.frame = NSRect(origin: .zero, size: Self.productionHostSize)
        settle(host)
        let availablePixels = try renderedPixels(host)

        voiceState.mode = .recording
        settle(host)
        XCTAssertNotEqual(try renderedPixels(host), availablePixels)

        voiceState.setConnectionStatus(false)
        settle(host)
        XCTAssertEqual(voiceState.modelsSettingsState.availability, .disconnected)
        XCTAssertNotEqual(try renderedPixels(host), availablePixels)
    }

    func testProductionModelsViewRendersFreshPolishStatusAndClearsItOnDisconnect() throws {
        let voiceState = VoiceState()
        voiceState.setConnectionStatus(true)
        var health = Self.availableHealth
        health["polish_controls"] = [
            "model_polish": ["source": "environment", "raw": "shadow", "effective": "shadow"],
            "outro_gate": ["source": "default", "raw": NSNull(), "effective": true],
            "smart_chunks": ["source": "default", "raw": NSNull(), "effective": false],
        ]
        voiceState.handleEvent(health)
        let host = NSHostingView(rootView: makeSettingsView(voiceState: voiceState))
        host.frame = NSRect(origin: .zero, size: Self.productionHostSize)
        settle(host)
        XCTAssertEqual(voiceState.modelsSettingsState.polishControls?.modelPolish.effective.displayName, "Preview only")
        let availablePixels = try renderedPixels(host)

        voiceState.setConnectionStatus(false)
        settle(host)
        XCTAssertNil(voiceState.modelsSettingsState.polishControls)
        XCTAssertNotEqual(try renderedPixels(host), availablePixels)
    }

    func testEffortPickerIsAbsentAcrossHealthAndSessionTransitionsWithoutChangingSavedEffort() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedFile = directory.appendingPathComponent("whisper-performance.json")
        for effort in VoiceBarPerformanceEffort.allCases {
            let original = Data("{ \"effort\": \"\(effort.rawValue)\" }\n".utf8)
            try original.write(to: savedFile)
            let voiceState = VoiceState()
            voiceState.setConnectionStatus(true)
            voiceState.handleEvent(Self.availableHealth)
            var writes: [VoiceBarPerformanceEffort] = []
            let host = NSHostingView(rootView: makeSettingsView(
                voiceState: voiceState,
                effort: effort,
                onSelectEffort: { selected in
                    writes.append(selected)
                    try? Data(selected.rawValue.utf8).write(to: savedFile)
                }
            ))
            host.frame = NSRect(origin: .zero, size: Self.productionHostSize)
            for mode in [VoiceMode.idle, .recording, .transcribing, .idle] {
                voiceState.mode = mode
                settle(host)
                XCTAssertTrue(descendants(of: NSSegmentedControl.self, in: host).isEmpty)
            }
            voiceState.setConnectionStatus(false)
            settle(host)
            XCTAssertEqual(voiceState.modelsSettingsState.availability, .disconnected)
            voiceState.setConnectionStatus(true)
            settle(host)
            voiceState.handleEvent(Self.availableHealth)
            settle(host)
            XCTAssertTrue(descendants(of: NSSegmentedControl.self, in: host).isEmpty)
            XCTAssertTrue(writes.isEmpty)
            XCTAssertEqual(try Data(contentsOf: savedFile), original)
            XCTAssertEqual(voiceState.modelsSettingsState.configuredEffort, .accurate)
        }
    }

    func testProductionModelsFormUsesTheRemaining780By620HostHeight() throws {
        let voiceState = VoiceState()
        voiceState.setConnectionStatus(true)
        voiceState.handleEvent(Self.availableHealth)
        let host = NSHostingView(rootView: makeSettingsView(voiceState: voiceState))
        host.frame = NSRect(origin: .zero, size: Self.productionHostSize)
        settle(host)

        let formScrollView = try XCTUnwrap(descendants(of: NSScrollView.self, in: host).first { $0.frame.height >= 500 })

        XCTAssertGreaterThanOrEqual(formScrollView.frame.height, 500)
        XCTAssertLessThanOrEqual(formScrollView.frame.maxY, host.bounds.maxY)
        XCTAssertGreaterThanOrEqual(formScrollView.frame.minY, host.bounds.minY)
    }

    private func makeSettingsView(
        voiceState: VoiceState,
        effort: VoiceBarPerformanceEffort = .accurate,
        onSelectEffort: @escaping (VoiceBarPerformanceEffort) -> Void = { _ in },
        onSelectResidency: ((VoiceModelResidency) -> Void)? = nil
    ) -> SettingsView {
        SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            performanceEffort: { effort },
            performanceEffortNotice: { nil },
            onSelectPerformanceEffort: onSelectEffort,
            modelsStatus: { voiceState.modelsSettingsState },
            onRefreshModelsStatus: {},
            onSelectResidency: onSelectResidency,
            vocabularyRevision: { 0 },
            initialTab: .transcription
        )
    }

    private func settle(_ host: NSHostingView<SettingsView>) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants<ViewType: NSView>(of type: ViewType.Type, in root: NSView) -> [ViewType] {
        root.subviews.flatMap { child -> [ViewType] in
            let match = child as? ViewType
            return (match.map { [$0] } ?? []) + descendants(of: type, in: child)
        }
    }

    private func renderedPixels(_ host: NSHostingView<SettingsView>) throws -> Data {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.bitmapData).withMemoryRebound(
            to: UInt8.self,
            capacity: bitmap.bytesPerRow * bitmap.pixelsHigh
        ) {
            Data(bytes: $0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
    }

    private static let availableHealth: [String: Any] = [
        "type": "health",
        "recording_state": "idle",
        "model_status": [
            "configured_model": [
                "name": "large-v3-turbo",
                "size_bytes": 1_617_000_000,
                "installed": true,
            ],
            "residency": "loaded",
            "active_model": "large-v3-turbo",
            "configured_effort": "accurate",
            "active_effort": "accurate",
        ],
    ]

    private static let productionHostSize = NSSize(width: 780, height: 620)
}
