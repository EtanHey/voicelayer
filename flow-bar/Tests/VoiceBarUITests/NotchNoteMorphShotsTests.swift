import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// NOTCH2 visual receipts: the busy note entering and leaving the notch, captured from the production BarView
/// while the animation runs. The host is resized to the panel size the moment the layout changes, the way
/// `VoiceBarApp.commitNotchContentThenApplyPanelLayout` resizes the real panel, and everything outside that
/// window paints pink, so a frame where the shell meets or crosses the window edge shows. Opt-in (writes PNGs).
@MainActor
final class NotchNoteMorphShotsTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private static let frameTimes: [TimeInterval] = [0, 0.033, 0.066, 0.1, 0.15, 0.2, 0.25, 0.35, 0.5]

    func testWriteNoteMorphFilmstripsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_NOTCH2_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_NOTCH2_SHOTS_DIR to write the NOTCH2 note filmstrips")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mode in [VoiceMode.recording, .transcribing] {
            try filmstrip(mode: mode, to: directory.appendingPathComponent("note-\(mode.rawValue).png"))
        }
        for (suffix, time, duration) in [("", 22.0, 36.0), ("-hour", 1800.0, 3600.0)] {
          for growing in [true, false] {
            let bar = SettingsPlaybackScrubBar(
                position: { SettingsAudioPlaybackPosition(currentTime: time, duration: duration) },
                seek: { _ in }, accessibilityNoun: "agent speech", isPlaying: false, isGrowing: growing,
                allowsSeeking: true, isTeleprompter: true
            )
            .frame(width: 437, height: 40)
            .background(Color(white: 0.13))
            try write(bar, size: CGSize(width: 437, height: 40),
                      to: directory.appendingPathComponent("scrub\(suffix)-\(growing ? "growing" : "final").png"))
          }
        }
        try writePreparing(to: directory.appendingPathComponent("preparing.png"))
    }

    private func write(_ view: some View, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }

    private func writePreparing(to url: URL) throws {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "prep", "chunk_start_ms": 0, "preparing": true]])
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false)
        let size = VoiceBarPanelLayout.make(
            presentation: model.presentation,
            canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
        ).panelSize
        try write(BarView(state: state, commandRouter: NoopRouter(), onOpenSettings: {}, onOpenHistory: {},
                          presentationModel: model, includesPanelOutsets: true)
                      .frame(width: size.width, height: size.height, alignment: .topLeading)
                      .background(Color(white: 0.3)),
                  size: size, to: url)
    }

    private func filmstrip(mode: VoiceMode, to url: URL) throws {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.sendCommand = { _ in }
        state.mode = mode
        if mode == .transcribing { state.statusText = "Transcribing..." }
        let model = VoiceBarNotchPresentationModel()
        func refreshModel() {
            let resolved = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
                mode: state.mode,
                hasTeleprompterText: state.teleprompterText != nil,
                statusText: state.statusText,
                transientNote: state.selectionFeedbackNote
            ))
            model.updateOperationalEnvelope(
                hasTeleprompter: resolved.visualState == .teleprompter,
                isRecording: resolved.visualState == .recording,
                hasCompactStatus: resolved.visualState == .compactStatus,
                compactStatusLeadingWingWidth: resolved.visualState == .compactStatus ? resolved.geometry.leadingWingWidth : nil,
                compactStatusTrailingWingWidth: resolved.visualState == .compactStatus ? resolved.geometry.trailingWingWidth : nil,
                recordingLeadingWingWidth: resolved.visualState == .recording ? resolved.geometry.leadingWingWidth : nil,
                recordingTrailingWingWidth: resolved.visualState == .recording ? resolved.geometry.trailingWingWidth : nil,
                transientNoteWidth: resolved.transientNoteWidth
            )
        }
        func panelSize() -> CGSize {
            VoiceBarPanelLayout.make(
                presentation: model.presentation,
                canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
            ).panelSize
        }
        refreshModel()

        let host = NSHostingView(rootView: BarView(
            state: state, commandRouter: NoopRouter(), onOpenSettings: {}, onOpenHistory: {},
            presentationModel: model, includesPanelOutsets: true
        ))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: panelSize())
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.18, alpha: 1)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        // The app's order: commit SwiftUI's destination, then resize the panel.
        state.onPanelLayoutChange = {
            refreshModel()
            let size = panelSize()
            guard host.frame.size != size else { return }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        var frames: [NSBitmapImageRep] = []
        func capture() throws {
            let start = Date()
            for time in Self.frameTimes {
                let wait = time - Date().timeIntervalSince(start)
                if wait > 0 { RunLoop.main.run(until: Date().addingTimeInterval(wait)) }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                frames.append(bitmap)
            }
        }
        // Enter: a selection press while busy shows the note.
        state.speakSelection()
        XCTAssertNotNil(state.selectionFeedbackNote)
        try capture()
        // Leave: the note clears itself after two seconds.
        let deadline = Date().addingTimeInterval(4)
        while state.selectionFeedbackNote != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertNil(state.selectionFeedbackNote)
        try capture()

        let scale: CGFloat = 2
        let slotWidth = Int(frames.map(\.size.width).max()! * scale)
        let slotHeight = Int(frames.map(\.size.height).max()! * scale) + 8
        let columns = 2
        let rows = Self.frameTimes.count
        let strip = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: slotWidth * columns + 8, pixelsHigh: slotHeight * rows,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
        NSColor.systemPink.withAlphaComponent(0.6).setFill()
        NSRect(x: 0, y: 0, width: strip.pixelsWide, height: strip.pixelsHigh).fill()
        for (index, frame) in frames.enumerated() {
            let column = index / rows
            let row = index % rows
            let width = frame.size.width * scale
            let height = frame.size.height * scale
            // Top-aligned in its slot, like the real panel hanging from the screen top.
            let y = CGFloat(strip.pixelsHigh - row * slotHeight) - height
            frame.draw(in: NSRect(x: CGFloat(column * (slotWidth + 8)), y: y, width: width, height: height))
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(strip.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}
