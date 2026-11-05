import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.3 U2 visual receipt (opt-in): one frame per wing state of the 3-wings mock (idle at rest, idle launcher,
/// History open, recording, transcribing, setup error, reading aloud with the teleprompter collapsed and open),
/// light and dark, rendered from the real BarView with the app's width mapping. Synthetic content only.
@MainActor
final class WingsU2ShotsTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private static let states = [
        "idle-rest", "idle", "history", "recording", "transcribing", "setup-error", "reading-aloud",
        "reading-aloud-teleprompter",
    ]

    func testWriteWingShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_U2_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_U2_SHOTS_DIR to write the 2.3 U2 wing shots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var widths: [String: CGFloat] = [:]
        for name in Self.states {
            let (state, model, historyOpen) = makeState(name)
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
            let size = CGSize(width: canvas.totalWidth + 24, height: canvas.totalHeight + 17)
            widths[name] = model.presentation.geometry.topWidth
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                var bar = BarView(state: state, commandRouter: NoopRouter(), onOpenSettings: {}, onOpenHistory: {},
                                  presentationModel: model, includesPanelOutsets: true)
                if historyOpen { bar = bar.presentingHistoryForShots() }
                try render(bar.environment(\.visualRenderTime, 1.25), size: size, appearance: appearance,
                           to: directory.appendingPathComponent("u2-\(name)-\(scheme).png"))
            }
        }
        let receipt = Self.states.map { name in
            "\(name)\ttop row \(String(format: "%.1f", widths[name] ?? 0)) pt"
        }.joined(separator: "\n")
        try (receipt + "\n").write(to: directory.appendingPathComponent("u2-widths.tsv"), atomically: true,
                                   encoding: .utf8)
    }

    private func makeState(_ name: String) -> (VoiceState, VoiceBarNotchPresentationModel, Bool) {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: false
        )
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        state.recentTranscriptionEntries = [
            RecentTranscriptionEntry(text: "A synthetic recent transcription.",
                                     createdAt: Date().addingTimeInterval(-120)),
            RecentTranscriptionEntry(text: "Another short sample with no personal content.",
                                     createdAt: Date().addingTimeInterval(-7200)),
        ]
        let hovered = name != "idle-rest"
        switch name {
        case "recording":
            state.handleEvent(["type": "state", "state": "recording"])
            state.recordingMode = "ptt"
            state.handleEvent(["type": "audio_level", "rms": 0.4])
        case "transcribing":
            state.handleEvent(["type": "state", "state": "transcribing"])
        case "setup-error":
            state.setSetupMissingPermissions([.accessibility])
        case "reading-aloud", "reading-aloud-teleprompter":
            state.handleEvent([
                "type": "state", "state": "speaking",
                "text": "A synthetic agent reply read aloud while the notch shows the time and Stop.",
            ])
            if name == "reading-aloud" { state.dismissTeleprompter() }
        default:
            break
        }
        state.isHovering = hovered
        let resolved = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: state.mode,
            showsRecordingHold: state.mode == .recording && state.recordingMode == "vad",
            hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isTeleprompterReadback: state.isTeleprompterReadback,
            isPlaybackPaused: state.isPlaybackPaused,
            statusText: VoiceBarPresentation.liveStatusText(
                mode: state.mode, transcript: state.transcript, confirmationText: state.confirmationText,
                hotkeyPhase: .idle, hotkeyEnabled: true, errorMessage: nil,
                commandModeState: nil, activeClipMarker: nil
            ),
            isHovered: hovered,
            isCollapsed: false
        ))
        let model = VoiceBarNotchPresentationModel()
        let isStatus = resolved.visualState == .compactStatus
        let isRecording = resolved.visualState == .recording
        let isTeleprompter = resolved.visualState == .teleprompter
        model.updateOperationalEnvelope(
            hasTeleprompter: isTeleprompter, isRecording: isRecording, hasCompactStatus: isStatus,
            compactStatusLeadingWingWidth: isStatus ? resolved.geometry.leadingWingWidth : nil,
            compactStatusTrailingWingWidth: isStatus ? resolved.geometry.trailingWingWidth : nil,
            recordingLeadingWingWidth: isRecording ? resolved.geometry.leadingWingWidth : nil,
            recordingTrailingWingWidth: isRecording ? resolved.geometry.trailingWingWidth : nil,
            teleprompterLeadingWingWidth: isTeleprompter ? resolved.geometry.leadingWingWidth : nil,
            virtualNotchIdleCoreHeight: name == "idle-rest" ? VoiceBarNotchContract.topHeight : nil
        )
        model.setHovered(hovered)
        let historyOpen = name == "history"
        model.setHistoryPanelOpen(historyOpen)
        return (state, model, historyOpen)
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8)) // let the shell settle after its morph
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw NSError(domain: "WingsU2Shots", code: 1) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WingsU2Shots", code: 2)
        }
        try data.write(to: url, options: .atomic)
        window.contentView = nil
    }
}
