import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U3a before/after: the whole Settings window on General and Transcription at its 780 pt minimum, light + dark.
/// Uses only SettingsView API that predates U3a, so the same file renders the base commit for the "before" frames.
@MainActor
final class SettingsU3aBeforeAfterShotsTests: XCTestCase {
    func testWriteBeforeAfterFramesWhenRequested() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["VOICEBAR_U3A_BEFORE_AFTER"] else {
            throw XCTSkip("Set VOICEBAR_U3A_BEFORE_AFTER (and VOICEBAR_U3A_LABEL) to write the frames")
        }
        let label = env["VOICEBAR_U3A_LABEL"] ?? "after"
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let models = ModelsSettingsState(healthEvent: [
            "type": "health", "recording_state": "idle",
            "model_status": [
                "residency": "loaded", "configured_effort": "accurate",
                "configured_model": ["name": "large-v3-turbo", "size_mb": 1600, "installed": true],
            ],
            "polish_controls": [
                "model_polish": ["source": "default", "raw": NSNull(), "effective": "on"],
                "outro_gate": ["source": "default", "raw": NSNull(), "effective": true],
                "smart_chunks": ["source": "default", "raw": NSNull(), "effective": false],
            ],
        ])
        let recognizer = RecognizerPickerState(
            selected: .parakeet, effective: .parakeet, parakeet: .loaded, whisper: .unloaded,
            parakeetAvailable: true, parakeetAssetsPresent: true, whisperAssetsPresent: true,
            diskBytes: [.parakeet: 2_509_000_000, .whisper: 1_620_000_000], idleUnloadSeconds: 300,
            unloadWhenIdle: RecognizerUnloadWhenIdle(effective: false))
        let mics = MicrophonePrioritySnapshot(rows: [
            MicrophonePriorityRow(uid: "dji", deviceID: "1", label: "DJI Mic 2", isConnected: true),
            MicrophonePriorityRow(uid: "mbp", deviceID: "2", label: "MacBook Pro Microphone", isConnected: true),
            MicrophonePriorityRow(uid: "air", deviceID: nil, label: "AirPods Pro", isConnected: false),
        ], nextDeviceName: "DJI Mic 2", nextDeviceUID: "dji")
        for broken in [false, true] {
            for tab in [SettingsTab.general, .transcription] where !(broken && tab == .transcription) {
                for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let view = SettingsView(
                        hotkeyEnabled: true, missingPermissions: broken ? [.accessibility] : [],
                        availableDevices: { [] }, selectedDeviceID: { nil }, prioritySnapshot: { mics },
                        modelsStatus: { models }, onRefreshModelsStatus: {},
                        recognizerStatus: { recognizer }, onSelectRecognizer: { _ in },
                        onManageRecognizer: { _, _ in }, onSetUnloadWhenIdle: { _ in },
                        vocabularyRevision: { 0 }, isHotkeyRemapActive: { true },
                        initialTab: tab
                    )
                    let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                    let size = CGSize(width: 780, height: 1000)
                    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                    host.appearance = appearance
                    host.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered,
                                          defer: false)
                    window.appearance = appearance
                    window.contentView = host
                    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    window.orderOut(nil); window.contentView = nil
                    let state = broken ? "-broken" : ""
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                        to: directory.appendingPathComponent("\(label)-\(tab.title.lowercased())\(state)-\(name).png"))
                }
            }
        }
    }
}
