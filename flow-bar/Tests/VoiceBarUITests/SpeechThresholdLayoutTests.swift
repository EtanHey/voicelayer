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
            // OCR must see the full unit on the draft row, rather than split fragments or an ellipsis.
            let unit = try XCTUnwrap(lines.first {
                $0.0.contains("characters") && abs($0.1.midY - draft.1.midY) * size.height < 8
            }, "Full characters unit missing from draft row: \(lines)")
            let apply = try XCTUnwrap(lines.first { $0.0.contains("Apply") }, "\(lines)")
            XCTAssertEqual(unit.1.midY * size.height, apply.1.midY * size.height, accuracy: 8)
            let number = try XCTUnwrap(lines.first {
                $0.0.contains("400") && abs($0.1.midY - draft.1.midY) * size.height < 8
            }, "Number field missing from draft row: \(lines)")
            XCTAssertEqual(number.1.midY * size.height, apply.1.midY * size.height, accuracy: 8)
        }
    }
}
