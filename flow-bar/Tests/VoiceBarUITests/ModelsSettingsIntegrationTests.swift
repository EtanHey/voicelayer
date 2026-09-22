import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class ModelsSettingsIntegrationTests: XCTestCase {
    func testProductionModelsViewRendersFreshPolishStatusAndClearsItOnDisconnect() throws {
        let voiceState = VoiceState()
        voiceState.setConnectionStatus(true)
        var health = Self.availableHealth
        health["polish_controls"] = [
            "model_polish": ["source": "environment", "raw": "shadow", "effective": "shadow"],
            "outro_gate": ["source": "default", "raw": NSNull(), "effective": true],
            "smart_chunks": ["source": "default", "raw": NSNull(), "effective": false],
            "smart_boundaries": ["source": "default", "raw": NSNull(), "effective": false],
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

    func testProductionSettingsTracksLiveModelsStateAndRoutesEffortSelection() throws {
        let voiceState = VoiceState()
        voiceState.setConnectionStatus(true)
        voiceState.handleEvent(Self.availableHealth)
        var selectedEffort: VoiceBarPerformanceEffort?

        let host = NSHostingView(rootView: makeSettingsView(
            voiceState: voiceState,
            onSelectEffort: { selectedEffort = $0 }
        ))
        host.frame = NSRect(origin: .zero, size: Self.productionHostSize)
        settle(host)

        XCTAssertEqual(voiceState.modelsSettingsState.configuredModelName, "large-v3-turbo")
        XCTAssertEqual(voiceState.modelsSettingsState.residency, .loaded)
        let availablePixels = try renderedPixels(host)
        XCTAssertFalse(availablePixels.isEmpty)

        let picker = try XCTUnwrap(descendants(of: NSSegmentedControl.self, in: host).first)
        XCTAssertTrue(picker.isEnabled)
        let fastIndex = try XCTUnwrap(
            (0 ..< picker.segmentCount).first { picker.label(forSegment: $0) == "Fast" }
        )
        picker.selectedSegment = fastIndex
        _ = picker.sendAction(picker.action, to: picker.target)
        settle(host)
        XCTAssertEqual(selectedEffort, .fast)

        voiceState.mode = .recording
        settle(host)
        XCTAssertFalse(picker.isEnabled)

        voiceState.mode = .transcribing
        settle(host)
        XCTAssertFalse(picker.isEnabled)

        voiceState.mode = .idle
        settle(host)
        XCTAssertEqual(voiceState.modelsSettingsState.availability, .loading)
        XCTAssertNil(voiceState.modelsSettingsState.configuredModelName)
        XCTAssertFalse(picker.isEnabled)
        let loadingPixels = try renderedPixels(host)
        XCTAssertNotEqual(loadingPixels, availablePixels)

        voiceState.handleEvent(Self.availableHealth)
        settle(host)
        XCTAssertEqual(voiceState.modelsSettingsState.configuredModelName, "large-v3-turbo")
        XCTAssertTrue(picker.isEnabled)
        let refreshedPixels = try renderedPixels(host)
        XCTAssertNotEqual(refreshedPixels, loadingPixels)

        voiceState.mode = .recording
        settle(host)
        XCTAssertFalse(picker.isEnabled)

        voiceState.setConnectionStatus(false)
        settle(host)
        XCTAssertEqual(voiceState.modelsSettingsState.availability, .unavailable)
        XCTAssertNil(voiceState.modelsSettingsState.configuredModelName)
        XCTAssertFalse(picker.isEnabled)
        XCTAssertNotEqual(try renderedPixels(host), refreshedPixels)

        voiceState.setConnectionStatus(true)
        settle(host)
        XCTAssertEqual(voiceState.modelsSettingsState.availability, .loading)
        XCTAssertNil(voiceState.modelsSettingsState.configuredModelName)
        XCTAssertFalse(picker.isEnabled)

        voiceState.handleEvent(Self.availableHealth)
        settle(host)
        XCTAssertEqual(voiceState.modelsSettingsState.configuredModelName, "large-v3-turbo")
        XCTAssertTrue(picker.isEnabled)
    }

    func testProductionModelsFormUsesTheRemaining780By620HostHeight() throws {
        let voiceState = VoiceState()
        voiceState.setConnectionStatus(true)
        voiceState.handleEvent(Self.availableHealth)
        let host = NSHostingView(rootView: makeSettingsView(voiceState: voiceState))
        host.frame = NSRect(origin: .zero, size: Self.productionHostSize)
        settle(host)

        let picker = try XCTUnwrap(descendants(of: NSSegmentedControl.self, in: host).first)
        let formScrollView = try XCTUnwrap(firstAncestor(of: NSScrollView.self, from: picker))

        XCTAssertGreaterThanOrEqual(formScrollView.frame.height, 500)
        XCTAssertLessThanOrEqual(formScrollView.frame.maxY, host.bounds.maxY)
        XCTAssertGreaterThanOrEqual(formScrollView.frame.minY, host.bounds.minY)
    }

    private func makeSettingsView(
        voiceState: VoiceState,
        onSelectEffort: @escaping (VoiceBarPerformanceEffort) -> Void = { _ in }
    ) -> SettingsView {
        SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            onSelectDevice: { _ in },
            performanceEffort: { .accurate },
            performanceEffortNotice: { nil },
            onSelectPerformanceEffort: onSelectEffort,
            modelsStatus: { voiceState.modelsSettingsState },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            initialTab: .models
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

    private func firstAncestor<ViewType: NSView>(of type: ViewType.Type, from view: NSView) -> ViewType? {
        var ancestor = view.superview
        while let current = ancestor {
            if let match = current as? ViewType {
                return match
            }
            ancestor = current.superview
        }
        return nil
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
