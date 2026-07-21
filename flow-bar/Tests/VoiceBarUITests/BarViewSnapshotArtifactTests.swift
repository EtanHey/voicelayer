import AppKit
import Darwin
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class BarViewSnapshotArtifactTests: XCTestCase {
    final class SnapshotCommandRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    func testWritesOffscreenAppKitArtifactsForAllPrimaryVoiceModes() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = artifactOutputDirectory()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        for mode in [VoiceMode.idle, .recording, .transcribing, .speaking, .error] {
            let state = snapshotState(for: mode)
            let outputURL = outputDirectory.appendingPathComponent("\(mode.rawValue).png")
            try writeOffscreenWindowPNG(state: state, to: outputURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertGreaterThan(
                try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0,
                0
            )
        }
    }

    func testWritesPronunciationDisplayTeleprompterArtifact() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = artifactOutputDirectory()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let state = VoiceState()
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        state.handleEvent(
            [
                "type": "state",
                "state": "speaking",
                "text": "Etan runs supabase cmuxlayer golems and BrainLayer on version 2.1",
            ],
            playbackAmplitude: PlaybackAmplitudeEnvelope(
                source: .decodedRMS,
                sampleIntervalMilliseconds: 50,
                samples: Array(repeating: 0.55, count: 200)
            )
        )
        state.wordBoundaries = [
            (0, 220, "Etan"),
            (240, 180, "runs"),
            (440, 300, "supabase"),
            (760, 280, "cmuxlayer"),
            (1060, 240, "golems"),
            (1320, 140, "and"),
            (1480, 320, "BrainLayer"),
            (1820, 120, "on"),
            (1960, 200, "version"),
            (2180, 180, "2.1"),
        ]

        let layout = VoiceBarPanelLayout.make(
            presentation: notchPresentation(for: state)
        )
        let view = BarView(state: state, commandRouter: SnapshotCommandRouter())
            .frame(
                width: layout.visibleContentRect.width,
                height: layout.visibleContentRect.height
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 17)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: layout.panelSize)
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Could not create bitmap for long speaking teleprompter")
            return
        }
        bitmap.size = layout.panelSize
        host.cacheDisplay(in: host.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode long speaking teleprompter PNG")
            return
        }

        let outputURL = outputDirectory.appendingPathComponent("speaking-pronunciation-display.png")
        try data.write(to: outputURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0, 0)
    }

    private func snapshotState(for mode: VoiceMode) -> VoiceState {
        let state = VoiceState()
        state.mode = mode
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false

        switch mode {
        case .idle:
            state.transcript = ""
        case .recording:
            state.recordingMode = "vad"
            state.handleEvent(["type": "audio_level", "rms": 0.75])
        case .transcribing:
            state.transcript = "Draft transcript"
        case .speaking:
            state.handleEvent(
                [
                    "type": "state",
                    "state": "speaking",
                    "text": "Speaking this sample line",
                ],
                playbackAmplitude: PlaybackAmplitudeEnvelope(
                    source: .decodedRMS,
                    sampleIntervalMilliseconds: 50,
                    samples: Array(repeating: 0.55, count: 200)
                )
            )
            state.wordBoundaries = [
                (0, 400, "Speaking"),
                (450, 300, "this"),
                (800, 400, "sample"),
                (1250, 300, "line"),
            ]
        case .error:
            state.errorMessage = "Try again"
        case .disconnected:
            break
        }

        return state
    }

    private func notchPresentation(for state: VoiceState) -> VoiceBarNotchPresentation {
        VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: state.mode,
                showsRecordingHold: state.mode == .recording && state.recordingMode == "vad",
                hasTeleprompterText: state.teleprompterText != nil,
                isTeleprompterDismissed: state.isTeleprompterDismissed,
                isTeleprompterReadback: state.isTeleprompterReadback,
                confirmationText: state.confirmationText,
                commandModeState: state.commandModeState,
                activeClipMarker: state.activeClipMarker,
                queueDepth: state.queueDepth,
                keepsPasteFlowEnvelope: state.keepsPasteFlowEnvelope,
                hotkeyPhase: state.hotkeyPhase,
                isHovered: state.isHovering,
                isKeyboardFocused: false
            )
        )
    }

    private func writeOffscreenWindowPNG(state: VoiceState, to outputURL: URL) throws {
        let presentation = notchPresentation(for: state)
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation)
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation,
            canvasGeometry: canvas.canvasGeometry
        )
        let host = NSHostingView(
            rootView: BarView(
                state: state,
                commandRouter: SnapshotCommandRouter(),
                includesPanelOutsets: true
            )
        )
        host.frame = CGRect(origin: .zero, size: layout.panelSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        guard let cgImage = captureWindowImage(windowNumber: window.windowNumber) else {
            throw NSError(domain: "BarViewSnapshotArtifactTests", code: 1)
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BarViewSnapshotArtifactTests", code: 2)
        }
        try data.write(to: outputURL, options: .atomic)
    }

    private func captureWindowImage(windowNumber: Int) -> CGImage? {
        typealias CaptureFunction = @convention(c) (
            CGRect,
            UInt32,
            UInt32,
            UInt32
        ) -> Unmanaged<CGImage>?
        guard let defaultLookup = UnsafeMutableRawPointer(bitPattern: -2),
              let symbol = dlsym(defaultLookup, "CGWindowListCreateImage") else {
            return nil
        }
        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution)
        return capture(
            CGRect.null,
            CGWindowListOption.optionIncludingWindow.rawValue,
            UInt32(windowNumber),
            options.rawValue
        )?.takeRetainedValue()
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func artifactOutputDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["VOICEBAR_VISUAL_ARTIFACT_OUTPUT"],
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("phase1")
            .appendingPathComponent("visual-qa")
            .appendingPathComponent("after")
    }
}
