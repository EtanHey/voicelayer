import AppKit
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

    func testWritesImageRendererArtifactsForAllPrimaryVoiceModes() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("phase1")
            .appendingPathComponent("visual-qa")
            .appendingPathComponent("after")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        for mode in [VoiceMode.idle, .recording, .transcribing, .speaking, .error] {
            let state = snapshotState(for: mode)
            let layout = VoiceBarPanelLayout.make(
                mode: state.mode,
                isCollapsed: state.isCollapsed,
                previewText: nil,
                statusText: VoiceBarPresentation.liveStatusText(
                    mode: state.mode,
                    transcript: state.transcript,
                    confirmationText: state.confirmationText,
                    hotkeyPhase: state.hotkeyPhase,
                    hotkeyEnabled: state.hotkeyEnabled,
                    errorMessage: state.errorMessage,
                    transcribingStatusText: state.transcribingStatusText,
                    commandModeState: state.commandModeState,
                    activeClipMarker: state.activeClipMarker
                ),
                queueItemCount: state.queueItems.count,
                padding: Theme.panelPadding
            )
            let view = BarView(state: state, commandRouter: SnapshotCommandRouter())
                .frame(width: layout.panelSize.width, height: layout.panelSize.height)

            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(layout.panelSize)
            renderer.scale = 2

            guard let cgImage = renderer.cgImage else {
                XCTFail("ImageRenderer did not produce a CGImage for \(mode.rawValue)")
                continue
            }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                XCTFail("Could not encode PNG for \(mode.rawValue)")
                continue
            }

            let outputURL = outputDirectory.appendingPathComponent("\(mode.rawValue).png")
            try data.write(to: outputURL, options: .atomic)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertGreaterThan(
                try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0,
                0
            )
        }
    }

    func testWritesPronunciationDisplayTeleprompterArtifact() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("phase1")
            .appendingPathComponent("visual-qa")
            .appendingPathComponent("after")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let state = VoiceState()
        state.mode = .speaking
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        state.statusText = "Etan runs supabase cmuxlayer golems and BrainLayer on version 2.1"
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
            mode: state.mode,
            isCollapsed: state.isCollapsed,
            previewText: nil,
            statusText: state.statusText,
            padding: Theme.panelPadding
        )
        let view = BarView(state: state, commandRouter: SnapshotCommandRouter())
            .frame(width: layout.panelSize.width, height: layout.panelSize.height)

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
            state.audioLevel = 0.45
        case .transcribing:
            state.transcript = "Draft transcript"
        case .speaking:
            state.statusText = "Speaking this sample line"
            state.wordBoundaries = [(0, 400, "Speaking"), (450, 300, "this"), (800, 400, "sample"), (1250, 300, "line")]
        case .error:
            state.errorMessage = "Try again"
        case .disconnected:
            break
        }

        return state
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
