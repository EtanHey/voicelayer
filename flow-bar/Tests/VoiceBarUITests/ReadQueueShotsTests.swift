import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// QUEUE1 visual receipt (opt-in, writes PNGs): the pill's pause/play, Next and "+N" count from the production
/// BarView in an offscreen window, light and dark. Synthetic text only.
@MainActor
final class ReadQueueShotsTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    func testWriteReadQueueShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_QUEUE1_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_QUEUE1_SHOTS_DIR to write the QUEUE1 pill shots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = ["# QUEUE1 pill shots", "", "Synthetic state, offscreen production BarView at 2×.", ""]
        for (appearanceName, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for (name, count, queued, dismissed, paused) in [
                ("teleprompter-no-queue", 0, false, false, false),
                ("teleprompter-plus2", 2, true, false, false),
                ("teleprompter-last-item", 0, true, false, false),
                ("compact-plus1", 1, true, true, false),
                ("paused-plus1", 1, true, true, true),
                ("compact-plus10", 10, true, true, false),
            ] {
                let filename = "queue1-\(name)-\(appearanceName).png"
                try shot(count: count, queued: queued, dismissed: dismissed, paused: paused,
                         appearance: appearance, to: directory.appendingPathComponent(filename))
                lines.append("- [\(filename)](\(filename))")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }

    private func shot(count: Int, queued: Bool, dismissed: Bool, paused: Bool,
                      appearance: NSAppearance.Name, to url: URL) throws {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent(["type": "state", "state": "speaking", "request_id": "r-A", "playback_id": "p-A",
                           "generation": 1, "text": "A synthetic selection read aloud while more selections wait."])
        if queued { state.handleEvent(["type": "read_queue", "count": count, "current_request_id": "r-A"]) }
        if dismissed { state.dismissTeleprompter() }
        if paused {
            state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-A", "generation": 2,
                               "offset_ms": 900, "chunk_offset_ms": 900])
        }
        let resolved = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: state.mode,
            hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isPlaybackPaused: state.isPlaybackPaused,
            readQueueLeadingSlotCount: VoiceBarPresentation.readQueueControl(for: state)?.leadingSlotCount ?? 1,
            isCollapsed: false
        ))
        let isTeleprompter = resolved.visualState == .teleprompter
        let isStatus = resolved.visualState == .compactStatus
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(
            hasTeleprompter: isTeleprompter, isRecording: false, hasCompactStatus: isStatus,
            compactStatusLeadingWingWidth: isStatus ? resolved.geometry.leadingWingWidth : nil,
            compactStatusTrailingWingWidth: isStatus ? resolved.geometry.trailingWingWidth : nil,
            teleprompterLeadingWingWidth: isTeleprompter ? resolved.geometry.leadingWingWidth : nil
        )
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: resolved).canvasGeometry
        let size = CGSize(width: canvas.totalWidth + 24,
                          height: isTeleprompter ? canvas.totalHeight + 17 : VoiceBarNotchContract.topHeight + 17)
        let host = NSHostingView(rootView: BarView(
            state: state, commandRouter: NoopRouter(), onOpenSettings: {}, onOpenHistory: {},
            presentationModel: model, includesPanelOutsets: true
        ).frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .aqua ? .white : NSColor(white: 0.18, alpha: 1)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
