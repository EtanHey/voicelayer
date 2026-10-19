import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// SETUI1 round 2 (Opus UI review #1): `sliderKnobWidth = NSSliderCell().knobThickness` initialised lazily inside
/// `body`; AppKit's animation group re-entered the SwiftUI graph update and SIGABRTed the first Speech render.
/// These render the Rate slider for real, so a crash in the body path fails the run.
@MainActor
final class SpeechSettingsRenderTests: XCTestCase {
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

    func testBareSpeechSettingsViewRendersTheRateSlider() throws {
        let controls = try XCTUnwrap(SpeechControlsState(controls: SpeechSettingsTests.controls(rate: "+0%")))
        let host = render(SpeechSettingsView(controls: controls, connected: true, busy: false, pending: [:],
                                             notice: nil, onChange: { _, _ in }, onPreview: { _ in }))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testSettingsOpenedOnSpeechRenders() throws {
        let controls = try XCTUnwrap(SpeechControlsState(controls: SpeechSettingsTests.controls(rate: "+0%")))
        let host = render(SettingsView(
            hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .disconnected }, onRefreshModelsStatus: {}, speechControls: { controls },
            speechConnected: { true }, speechBusyReason: { nil }, speechNotice: { nil },
            onChangeSpeech: { _, _ in }, onSelectSpeechEngine: { _, _, _ in }, onPreviewSpeech: { _ in },
            vocabularyRevision: { 0 },
            footerPresentation: { .resolve(isConnected: true, mode: .idle, captureLive: false,
                                          errorMessage: nil, remoteSTTConfigured: false, hasFreshHealth: true) },
            initialTab: .speech
        ))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// The knob width is a constant in the view; AppKit is asked only here, outside any view update.
    func testKnobWidthConstantMatchesAppKit() throws {
        XCTAssertEqual(NSSliderCell().knobThickness, SpeechSettingsView.sliderKnobWidth)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SpeechSettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("NSSliderCell"), "never touch AppKit slider cells from the view")
    }

    private func render(_ view: some View) -> NSView {
        let host = NSHostingView(rootView: view.frame(width: 780, height: 1000))
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 1000)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return host
    }
}
