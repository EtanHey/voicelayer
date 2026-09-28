import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Lane C2–C4 visual receipts: filmstrips of the notch morphing, captured from the production BarView in an
/// offscreen window while the animation runs. Opt-in (writes PNGs); fixtures are synthetic.
@MainActor
final class NotchMorphFrameShotsTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    private static let frameTimes: [TimeInterval] = [0, 0.033, 0.066, 0.1, 0.15, 0.25, 0.45]

    func testWriteMorphFilmstripsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_MORPH_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_MORPH_SHOTS_DIR to write notch morph filmstrips")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = [
            "# Notch morph filmstrips",
            "",
            "Rows are frames at \(Self.frameTimes.map { "\(Int($0 * 1000)) ms" }.joined(separator: ", ")) "
                + "after the change. Synthetic state, offscreen production BarView at 2×.",
            "",
        ]
        for (appearanceName, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for morph in ["mic-to-recording", "cancel-to-launcher", "history-open", "teleprompter-open"] {
                let filename = "morph-\(morph)-\(appearanceName).png"
                try filmstrip(morph, appearance: appearance, to: directory.appendingPathComponent(filename))
                lines.append("- [\(filename)](\(filename))")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("index.md"), atomically: true, encoding: .utf8
        )
    }

    private func filmstrip(_ morph: String, appearance: NSAppearance.Name, to url: URL) throws {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true
        state.recentTranscriptionEntries = [
            RecentTranscriptionEntry(
                text: "A synthetic recent transcription.",
                createdAt: Date().addingTimeInterval(-120)
            ),
            RecentTranscriptionEntry(
                text: "Another short synthetic sample.",
                createdAt: Date().addingTimeInterval(-7200)
            ),
        ]
        let model = VoiceBarNotchPresentationModel()
        let startsRecording = morph == "cancel-to-launcher"
        if startsRecording {
            state.mode = .recording
            state.recordingMode = "vad"
        }
        if morph == "teleprompter-open" {
            state.mode = .speaking
        }
        model.updateOperationalEnvelope(
            hasTeleprompter: false, isRecording: startsRecording, hasCompactStatus: morph == "teleprompter-open"
        )
        model.setHovered(morph != "teleprompter-open")

        let historyCanvas = VoiceBarNotchMorphCanvasLayout.resolve(
            for: VoiceBarNotchPresentation.resolve(
                hasTeleprompter: false, isRecording: false, hasCompactStatus: false, hasHistoryPanel: true,
                isHovered: true, isKeyboardFocused: false
            )
        ).canvasGeometry
        let tall = morph == "history-open" || morph == "teleprompter-open"
        let size = CGSize(width: historyCanvas.totalWidth + 24, height: tall ? historyCanvas.totalHeight + 17 : 44)
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        switch morph {
        case "mic-to-recording":
            state.mode = .recording
            state.recordingMode = "vad"
            model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: true, hasCompactStatus: false)
        case "cancel-to-launcher":
            state.mode = .idle
            model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: false, hasCompactStatus: false)
        case "history-open":
            model.setHistoryPanelOpen(true)
        default:
            state.handleEvent([
                "type": "state", "state": "speaking",
                "text": "A synthetic agent reply shown in the teleprompter while the notch opens.",
            ])
            model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false)
        }
        let start = Date()
        var frames: [NSBitmapImageRep] = []
        for time in Self.frameTimes {
            let wait = time - Date().timeIntervalSince(start)
            if wait > 0 { RunLoop.main.run(until: Date().addingTimeInterval(wait)) }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            frames.append(bitmap)
        }

        let scale: CGFloat = 2
        let frameWidth = Int(size.width * scale)
        let frameHeight = Int(size.height * scale)
        let strip = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: frameWidth, pixelsHigh: (frameHeight + 4) * frames.count,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
        NSColor.systemPink.withAlphaComponent(0.6).setFill()
        NSRect(x: 0, y: 0, width: strip.pixelsWide, height: strip.pixelsHigh).fill()
        for (index, frame) in frames.enumerated() {
            let y = strip.pixelsHigh - (index + 1) * (frameHeight + 4) + 4
            frame.draw(in: NSRect(x: 0, y: y, width: frameWidth, height: frameHeight))
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(strip.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}
