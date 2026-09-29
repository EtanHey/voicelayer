import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// UXP-3 visual receipt (opt-in): the shared Copy button idle and ticked, the notch History row with the new Paste
/// glyph, the popover, the Last-dictation card and the History toolbar, light and dark. Synthetic content only.
@MainActor
final class IconButtonsShotsTests: XCTestCase {
    func testWriteIconButtonShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_UXP3_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_UXP3_SHOTS_DIR to write the UXP-3 shots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ticked = CopyFeedback()
        ticked
            .copied(succeeded: true, byPointer: true, at: Date().addingTimeInterval(60)) // stays ticked while rendering
        let entry = RecentTranscriptionEntry(
            text: "A short synthetic dictation for the Last dictation card.",
            dictationReceipt: DictationReceipt(audioDurationMilliseconds: 6200, processingDurationMilliseconds: 800),
            createdAt: Date().addingTimeInterval(-120)
        )

        for (scheme, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let colorScheme: ColorScheme = scheme == "light" ? .light : .dark
            let appearance = NSAppearance(named: appearanceName)
            try render(
                HStack(spacing: 24) {
                    CopyFeedbackButton("Copy", feedback: .constant(CopyFeedback())) { true }
                    CopyFeedbackButton("Copy", feedback: .constant(ticked)) { true }
                }
                .padding(12).environment(\.colorScheme, colorScheme),
                appearance: appearance, size: CGSize(width: 110, height: 48),
                to: directory.appendingPathComponent("copy-button-idle-ticked-\(scheme).png")
            )
            try render(
                NotchHistoryPanel(
                    entries: [
                        entry,
                        RecentTranscriptionEntry(text: "Another synthetic row.", recordingPath: "/synthetic/b.wav",
                                                 createdAt: Date().addingTimeInterval(-7200)),
                    ],
                    activeRetranscriptionPath: nil,
                    palette: VoiceBarNotchContrastPalette.resolve(for: scheme == "light" ? .light : .dark),
                    onCopy: { _ in true }, onPaste: { _ in }, onRetranscribe: { _ in }, onOpenHistory: {},
                    forcedHoverIndex: 1
                )
                .padding(14)
                .background(scheme == "light" ? Color.white : Color(white: 0.09)),
                appearance: appearance, size: CGSize(width: 332, height: 220),
                to: directory.appendingPathComponent("notch-history-rows-\(scheme).png")
            )
            try render(
                MenuBarPopoverView(
                    footer: VoiceBarFooterPresentation.resolve(
                        isConnected: true, mode: .idle, captureLive: false, errorMessage: nil,
                        remoteSTTConfigured: false, hasFreshHealth: true
                    ),
                    hotkeyHint: "Hold F5 to dictate", defaultMicrophoneName: "Synthetic Microphone",
                    transcript: "A synthetic last transcript.", onCopy: { true }
                ).environment(\.colorScheme, colorScheme),
                appearance: appearance, size: CGSize(width: 300, height: 240),
                to: directory.appendingPathComponent("popover-\(scheme).png")
            )
            try render(
                Form {
                    Section("Last dictation") {
                        DictationCard(entry: entry, insertionStatus: .pasted, onCopy: { _ in true })
                    }
                }
                .formStyle(.grouped).environment(\.colorScheme, colorScheme),
                appearance: appearance, size: CGSize(width: 560, height: 190),
                to: directory.appendingPathComponent("last-dictation-\(scheme).png")
            )
            try render(
                SettingsView(
                    hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
                    modelsStatus: { .loading }, onRefreshModelsStatus: {}, vocabularyRevision: { 0 },
                    historyPage: { _ in SettingsHistoryPage(groups: [], hasMore: false) },
                    initialTab: .history
                ).environment(\.colorScheme, colorScheme),
                appearance: appearance, size: CGSize(width: 780, height: 300),
                to: directory.appendingPathComponent("settings-history-toolbar-\(scheme).png")
            )
        }
    }

    private func render(_ view: some View, appearance: NSAppearance?, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw NSError(domain: "IconButtonsShots", code: 1) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconButtonsShots", code: 2)
        }
        try data.write(to: url, options: .atomic)
        window.contentView = nil
    }
}
