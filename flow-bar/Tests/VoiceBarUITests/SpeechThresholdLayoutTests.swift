import AppKit
import OffscreenTestSupport
import SwiftUI
import Vision
@testable import VoiceBarUI
import XCTest

@MainActor
final class SpeechThresholdLayoutTests: XCTestCase {
    func testThresholdControlsStayOnOneLineAtMinimumSettingsWidth() throws {
        // The Settings window opens at its minimum content size (780 × 620).
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let controls = try XCTUnwrap(SpeechControlsState(controls: SpeechSettingsTests.thresholdControls()))
            let view = SettingsView(
                hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
                modelsStatus: { .disconnected }, onRefreshModelsStatus: {}, speechControls: { controls },
                speechConnected: { true }, onChangeSpeech: { _, _ in }, vocabularyRevision: { 0 },
                initialTab: .speech
            )
            let size = CGSize(width: 780, height: 620)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            VLOrderTestWindow(window)
            defer { window.orderOut(nil); window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["VOICEBAR_SPEECH_SHOTS_DIR"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("threshold-\(appearance.rawValue).png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
            let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return (text, observation.boundingBox)
            }
            let draft = try XCTUnwrap(lines.first { $0.0.contains("Draft") }, "\(lines)")
            // The candidate title, purpose and reporting caveat remain visible beside the controls.
            let summary = try XCTUnwrap(lines.first { $0.0.contains("Chooses the short or long") }, "\(lines)")
            let text = lines.map(\.0).joined(separator: " ")
            XCTAssertTrue(text.contains("Last reported cutoff: 400 characters"), text)
            XCTAssertTrue(text.contains("for the next speech."), text)
            XCTAssertTrue(text.contains("Profile descriptions and Revert use the last reported cutoff"), text)
            let apply = try XCTUnwrap(lines.first { $0.0 == "Apply" }, "\(lines)")
            let revert = try XCTUnwrap(lines.first { $0.0 == "Revert" }, "\(lines)")
            let number = try XCTUnwrap(lines.first { $0.0 == "400" }, "Number field missing: \(lines)")
            XCTAssertGreaterThan(draft.1.midY, number.1.midY, "Draft labels the field above it")
            XCTAssertLessThan(summary.1.maxX, number.1.minX, "The summary leaves the controls their own column")
            XCTAssertEqual(number.1.midY * size.height, apply.1.midY * size.height, accuracy: 8)
            XCTAssertEqual(revert.1.midY * size.height, apply.1.midY * size.height, accuracy: 8)
        }
    }
}
