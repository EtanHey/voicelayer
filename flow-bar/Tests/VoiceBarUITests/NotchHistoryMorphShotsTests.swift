import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.3 lane U4 visual receipt (opt-in): History morph B frozen at each state, light and dark. Closed launcher, the
/// first frames (rows still blurred and small), halfway, the open spring's overshoot, open, a hovered row with its
/// actions, the scroll indicator mid-scroll, and the panel extended by its handle to 10 and 12 rows (V6).
/// Synthetic rows only.
@MainActor
final class NotchHistoryMorphShotsTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private static let rows = [
        "The garden panel opens beside the fountain whenever the gardener returns to inspect the lantern catalogue.",
        "A short synthetic row.",
        "The lantern catalogue needs a partial plan for the baskets and the flower beds.",
        "The garden fountain springs quickly whenever the wooden handle is released.",
        "The imaginary gardener inspected every lantern beside the fountain before checking the garden layout.",
        "Another synthetic dictation that runs long enough to be cut off with an ellipsis at the end.",
        "The imaginary gardener can finish painting the lanterns before the spring fair.",
        "Nothing new yet.",
        "One, two, three, four.",
        "The copper lantern rests beside the quiet garden.",
        "What's the update?",
        "One, two, three.",
    ]

    func testWriteHistoryMorphShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_U4_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_U4_SHOTS_DIR to write the 2.3 lane U4 History shots")
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
        state.isHovering = true
        let durations = [120_000, 2000, 101_000, 37000, 315_000, 430_000, 47000, 2000, 5000, 6000, 4000, 3000]
        let ages: [TimeInterval] = [10, 120, 240, 300, 420, 840, 1260, 1380, 1860, 1980, 2280, 2460]
        state.recentTranscriptionEntries = Self.rows.indices.map { index in
            RecentTranscriptionEntry(
                text: Self.rows[index],
                recordingPath: "/synthetic/\(index).wav",
                dictationReceipt: DictationReceipt(
                    audioDurationMilliseconds: durations[index], processingDurationMilliseconds: 500
                ),
                createdAt: Date().addingTimeInterval(-ages[index])
            )
        }
        let router = NoopRouter()

        let cases: [(String, (BarView) -> BarView, Bool)] = [
            ("1-closed-launcher", { $0 }, false),
            ("2-opening-p015", { $0.freezingHistoryMorph(at: 0.15) }, true),
            ("3-midway-p050", { $0.freezingHistoryMorph(at: 0.5) }, true),
            ("4-rows-arriving-p080", { $0.freezingHistoryMorph(at: 0.8) }, true),
            ("5-overshoot-p104", { $0.freezingHistoryMorph(at: 1.04) }, true),
            ("6-open", { $0.presentingHistoryForShots() }, true),
            ("7-row-hover-actions", { $0.presentingHistoryForShots().forcingHistoryHover(2) }, true),
            ("8-scroll-indicator", {
                $0.presentingHistoryForShots().forcingHistoryScrollIndicator(offset: 4 * NotchHistoryMorph.rowHeight)
            }, true),
            ("9-extended-10-rows", { $0.presentingHistoryForShots().extendingHistory(rows: 10) }, true),
            ("10-extended-12-rows", { $0.presentingHistoryForShots().extendingHistory(rows: 12) }, true),
        ]
        for (name, configure, historyOpen) in cases {
            let model = VoiceBarNotchPresentationModel()
            model.setHovered(true)
            model.setHistoryPanelOpen(historyOpen)
            if name.hasPrefix("9-") { model.setHistoryRows(10) }
            if name.hasPrefix("10-") { model.setHistoryRows(12) }
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
            let size = CGSize(width: canvas.totalWidth + 24, height: canvas.totalHeight + 17)
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let bar = configure(BarView(
                    state: state, commandRouter: router, onOpenSettings: {}, onOpenHistory: {},
                    presentationModel: model, includesPanelOutsets: true
                ))
                try render(bar, size: size, appearance: appearance,
                           to: directory.appendingPathComponent("history-\(name)-\(scheme).png"))
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw NSError(domain: "NotchHistoryMorphShots", code: 1) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "NotchHistoryMorphShots", code: 2)
        }
        try data.write(to: url, options: .atomic)
        window.contentView = nil
    }
}
