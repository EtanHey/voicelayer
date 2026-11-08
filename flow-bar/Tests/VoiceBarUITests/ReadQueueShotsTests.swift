import AppKit
import OffscreenTestSupport
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
                ("processing-teleprompter-plus2", 2, true, false, false),
                ("processing-compact-no-queue", 0, false, true, false),
                ("teleprompter-no-queue", 0, false, false, false),
                ("teleprompter-plus2", 2, true, false, false),
                ("teleprompter-last-item", 0, true, false, false),
                ("compact-plus1", 1, true, true, false),
                ("paused-plus1", 1, true, true, true),
                ("compact-plus10", 10, true, true, false),
                ("idle-after-f5-plus2", 2, true, false, false),
            ] {
                let filename = "queue1-\(name)-\(appearanceName).png"
                try shot(count: count, queued: queued, dismissed: dismissed, paused: paused,
                         idleAfterF5: name.hasPrefix("idle"), processing: name.hasPrefix("processing"),
                         appearance: appearance, to: directory.appendingPathComponent(filename))
                lines.append("- [\(filename)](\(filename))")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }

    private func shot(count: Int, queued: Bool, dismissed: Bool, paused: Bool, idleAfterF5: Bool, processing: Bool,
                      appearance: NSAppearance.Name, to url: URL) throws {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent(["type": "state", "state": "speaking", "request_id": "r-A", "playback_id": "p-A",
                           "generation": 1, "utteranceId": "read-A", "text": "A synthetic selection read aloud while more selections wait."])
        if processing { state.handleEvent(["type": "read_processing", "utterance_id": "read-A", "active": true]) }
        if queued { state.handleEvent(["type": "read_queue", "count": count, "current_request_id": "r-A"]) }
        if dismissed { state.dismissTeleprompter() }
        if idleAfterF5 {
            state.retainingReadQueueOnStop { state.stop() }
            state.mode = .idle
        }
        if paused {
            state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-A", "generation": 2,
                               "offset_ms": 900, "chunk_offset_ms": 900])
        }
        let resolved = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: state.mode,
            hasTeleprompterText: state.mode == .speaking && state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isPlaybackPaused: state.isPlaybackPaused,
            readQueueLeadingSlotCount: VoiceBarPresentation.playbackLeadingSlotCount(for: state),
            statusText: VoiceBarPresentation.liveStatusText(
                mode: state.mode, transcript: state.transcript, confirmationText: state.confirmationText,
                hotkeyPhase: .idle, hotkeyEnabled: true, errorMessage: nil,
                commandModeState: nil, activeClipMarker: nil
            ),
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
        if processing { VLOrderCompositorTestWindow(window) } else { window.orderBack(nil) }
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if processing {
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(captureWindowImage(windowNumber: window.windowNumber)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            return
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func captureWindowImage(windowNumber: Int) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let lookup = UnsafeMutableRawPointer(bitPattern: -2),
              let symbol = dlsym(lookup, "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        return capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(windowNumber),
                       CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution).rawValue)?.takeRetainedValue()
    }
}
