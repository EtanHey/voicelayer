import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// UXP-2 visual receipt (opt-in): the notch shell at rest (the flat-display virtual core), on hover, and with
/// History open, light and dark. Synthetic History rows only.
@MainActor
final class NotchShellShotsTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    func testWriteNotchShellShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_UXP2_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_UXP2_SHOTS_DIR to write the UXP-2 notch shell shots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
            RecentTranscriptionEntry(
                text: "A synthetic recent transcription.",
                createdAt: Date().addingTimeInterval(-120)
            ),
            RecentTranscriptionEntry(text: "Another short sample with no personal content.",
                                     createdAt: Date().addingTimeInterval(-7200)),
        ]
        let router = NoopRouter()

        for (stateName, hovered, historyOpen) in [
            ("rest", false, false),
            ("hover", true, false),
            ("history", true, true),
        ] {
            let model = VoiceBarNotchPresentationModel()
            model.updateOperationalEnvelope(
                hasTeleprompter: false, isRecording: false, hasCompactStatus: false,
                virtualNotchIdleCoreHeight: hovered ? nil : VoiceBarNotchContract.topHeight
            )
            state.isHovering = hovered // BarView pushes this into the model
            model.setHovered(hovered)
            model.setHistoryPanelOpen(historyOpen)
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
            let size = CGSize(width: canvas.totalWidth + 24, height: canvas.totalHeight + 17)
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                var bar = BarView(state: state, commandRouter: router, onOpenSettings: {}, onOpenHistory: {},
                                  presentationModel: model, includesPanelOutsets: true)
                if historyOpen { bar = bar.presentingHistoryForShots() }
                try render(bar, size: size, appearance: appearance,
                           to: directory.appendingPathComponent("notch-\(stateName)-\(scheme).png"))
            }
        }
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
        ) else { throw NSError(domain: "NotchShellShots", code: 1) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "NotchShellShots", code: 2)
        }
        try data.write(to: url, options: .atomic)
        window.contentView = nil
    }
}
