import AppKit
import SwiftUI
import XCTest
@testable import VoiceBarUI

/// Synthetic native rendering only; no resident app, sockets or model runtime.
@MainActor
final class RecognizerManagementShotsTests: XCTestCase {
    func testWriteManagementShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_RECOGNIZER_SHOTS"] else { throw XCTSkip("Set VOICEBAR_RECOGNIZER_SHOTS") }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [720, 390] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let payload = RecognizerBindingTests.event(parakeetAvailable: nil, assetsPresent: false)["recognizer_status"] as! [String: Any]
                let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: payload)))
                let view = ModelsSettingsView(state: .disconnected, recognizerState: state, onSelectRecognizer: { _ in }, onManageRecognizer: { _, _ in })
                let host = NSHostingView(rootView: view.frame(width: CGFloat(width), height: 310))
                host.appearance = NSAppearance(named: appearance); host.frame = NSRect(x: 0, y: 0, width: width, height: 310)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = host.appearance; window.backgroundColor = .windowBackgroundColor; window.contentView = host
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(width)-\(name).png"))
                window.contentView = nil
            }
        }
    }
}
