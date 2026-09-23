import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Production views in an offscreen AppKit host. Fixtures are deliberately synthetic.
@MainActor
final class SottoCurrentStateShotsTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    func testWriteCurrentStateShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_SHOTS_DIR to write local visual artifacts")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = [
            "# Origin/main current state",
            "",
            "Base: `b0180a3`. All content below uses synthetic fixtures. PNGs are rendered by production SwiftUI views inside offscreen AppKit windows at 2×.",
            "",
            "| File | Surface and state |",
            "|---|---|",
        ]
        func shot(_ name: String, _ description: String, _ view: some View, size: CGSize) throws {
            try render(view, size: size, to: directory.appendingPathComponent(name))
            lines.append("| [\(name)](\(name)) | \(description) |")
        }

        for (name, mode, transcript) in [
            ("idle", VoiceMode.idle, ""),
            ("recording", .recording, ""),
            ("transcribing", .transcribing, ""),
            ("no-transcript-yet", .idle, ""),
            (
                "long-transcript",
                .idle,
                "A synthetic paragraph about a sample recording.\nIt continues on a second line.\nThe third line is also synthetic."
            ),
        ] {
            let footer = VoiceBarFooterPresentation.resolve(
                isConnected: true, mode: mode, captureLive: mode == .recording,
                errorMessage: nil, remoteSTTConfigured: false, hasFreshHealth: true
            )
            try shot("popover-\(name).png", "Menu bar popover: \(name)", MenuBarPopoverView(
                footer: footer, hotkeyHint: "Hold F5 to dictate",
                microphoneName: "Built-in Microphone", transcript: transcript
            ).environment(\.colorScheme, .light).background(Color.white),
            size: CGSize(width: 334, height: transcript.isEmpty ? 194 : 270))
        }

        let router = NoopRouter()
        for (name, mode, hover) in [
            ("idle", VoiceMode.idle, false),
            ("idle-hover", .idle, true),
            ("recording", .recording, false),
            ("transcribing", .transcribing, false),
            ("error", .error, false),
        ] {
            let state = syntheticState()
            state.mode = mode
            state.isHovering = hover
            if mode == .recording { state.recordingMode = "vad" }
            if mode == .error { state.errorMessage = "Synthetic error" }
            try shot("pill-\(name).png", "Pill: \(name)", BarView(
                state: state, commandRouter: router, includesPanelOutsets: true
            ), size: CGSize(width: 420, height: 180))
        }

        let panelState = syntheticState()
        panelState.recentTranscriptionEntries = [
            RecentTranscriptionEntry(text: "A synthetic recent transcription."),
            RecentTranscriptionEntry(text: "Another short sample with no personal content."),
        ]
        panelState.transcriptionVocabularyTerms = ["SwiftUI", "whisper.cpp"]
        let panel = BarView(state: panelState, commandRouter: router)
        try shot("notch-recent.png", "Notch panel: Recent Transcriptions", panel.historyPopover,
                 size: CGSize(width: 348, height: 274))
        try shot("notch-vocabulary.png", "Notch panel: Transcription Vocabulary", panel.vocabularyPopover,
                 size: CGSize(width: 348, height: 314))

        let menu = PillContextMenuController()
        menu.transcriptProvider = { "A synthetic recent transcription." }
        menu.recentTranscriptionsProvider = { ["A synthetic recent transcription.", "Another sample."] }
        menu.transcriptionVocabularyTermsProvider = { ["SwiftUI", "whisper.cpp"] }
        menu.availableDevicesProvider = { [MicrophoneDevice(id: "fixture-mic", name: "Fixture Microphone")] }
        menu.selectedDeviceIDProvider = { "fixture-mic" }
        try menuShots(
            menu.makeMenu(),
            prefix: "menu",
            description: "Right-click menu",
            directory: directory,
            lines: &lines
        )

        let empty = STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: [])
        let populated = STTVocabularyPreview(
            updatedAt: "2026-09-23T00:00:00Z",
            promptTerms: ["SwiftUI", "whisper.cpp"],
            aliases: [
                STTVocabularyAliasPreview(from: "swift you eye", to: "SwiftUI"),
            ]
        )
        for tab in SettingsTab.allCases {
            try shot("settings-\(tab.title.lowercased()).png", "Settings: \(tab.title)",
                     settings(tab: tab, vocabulary: tab == .dictionary ? populated : empty),
                     size: CGSize(width: 780, height: 620))
        }
        try shot(
            "settings-dictionary-empty.png",
            "Settings Dictionary: empty",
            settings(tab: .dictionary, vocabulary: empty),
            size: CGSize(width: 780, height: 620)
        )
        try shot(
            "settings-dictionary-search.png",
            "Settings Dictionary: searching synthetic term",
            settings(tab: .dictionary, vocabulary: populated, search: "Swift"),
            size: CGSize(width: 780, height: 620)
        )
        for (name, residency, recordingState, queueDepth) in [
            ("idle", "not_loaded", "idle", 0),
            ("loaded", "loaded", "idle", 0),
            ("busy", "loaded", "idle", 1),
            ("recording", "loaded", "recording", 0),
        ] {
            try shot("settings-models-\(name).png", "Settings Models: \(name)",
                     settings(
                         tab: .models,
                         vocabulary: empty,
                         modelState: modelState(
                             residency: residency,
                             recordingState: recordingState,
                             queueDepth: queueDepth
                         )
                     ),
                     size: CGSize(width: 780, height: 620))
        }
        try shot("settings-history-detail.png", "Settings History: synthetic list and selected detail",
                 settings(tab: .history, vocabulary: empty), size: CGSize(width: 780, height: 620))
        lines.append(contentsOf: [
            "",
            "## Popover geometry for the design spec",
            "",
            "Measurements are points, read from the 2× light-appearance PNGs; button and text bounds are approximate visible-pixel bounds. Source spacing is exact.",
            "",
            "- Main column spacing: **10 pt** (`VStack`). Footer status lines: **5 pt**. Mic and transcript cards: **9 pt** internal padding; transcript text and copy button: **8 pt** horizontal spacing, top aligned.",
            "- Long transcript visible text block midpoint: about **148 pt** from the popover top; copy glyph midpoint: about **139 pt**. The text block center is about **9 pt lower** because the HStack is top aligned.",
            "- Idle footer visible button frames `(x, y, width, height)`: Settings about **(12, 131, 121, 24) pt**; Quit about **(12, 165, 107, 24) pt**. Long-transcript frames: about **(12, 198, 121, 24) pt** and **(12, 232, 107, 24) pt**.",
            "- The mic row has a quaternary fill on every rendering. Its view has no selected/highlight state, so closing and rebuilding this view preserves the same fill. Actual MenuBarExtra focus ring and first responder require a live menu-open probe and are **not established** by an offscreen NSWindow.",
            "",
            "## Limits",
            "",
            "The right-click menu images are drawn from the production `NSMenu` model because AppKit cannot snapshot a tracking menu in an offscreen window. The idle and idle-hover pill PNGs are pixel-identical in this host; hover and pressed optics need a live pointer event and are not proven here. These are source-state artifacts, not installed-app screenshots.",
        ])
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("index.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func syntheticState() -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
                               keepsExpandedInDevState: false)
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        return state
    }

    private func modelState(residency: String, recordingState: String, queueDepth: Int) -> ModelsSettingsState {
        ModelsSettingsState(healthEvent: [
            "type": "health", "recording_state": recordingState, "queue_depth": queueDepth,
            "model_status": [
                "configured_model": ["name": "fixture-whisper-model", "size_bytes": 1_000_000, "installed": true],
                "residency": residency,
                "active_model": residency == "loaded" ? "fixture-whisper-model" : NSNull(),
                "configured_effort": "accurate",
                "active_effort": "accurate",
            ],
        ])
    }

    private func settings(
        tab: SettingsTab,
        vocabulary: STTVocabularyPreview,
        search: String = "",
        modelState: ModelsSettingsState = .loading
    ) -> SettingsView {
        let date = Date(timeIntervalSince1970: 1_758_590_400)
        let entry = SettingsHistoryEntry(
            id: "fixture-recording",
            dayKey: "2025-09-23",
            recordingID: "fixture-recording",
            createdAt: date,
            transcript: "This is a synthetic dictation for screenshot review.",
            audioPath: URL(fileURLWithPath: "/tmp/voicelayer-sotto-synthetic.wav")
        )
        let group = SettingsHistoryDayGroup(dayKey: "2025-09-23", date: date, entries: [entry])
        let historyFixture = SettingsHistoryPage(groups: [group], loadedEntryCount: 1, hasMore: false)
        let emptyAskFixture = SettingsAskHistoryPage(groups: [], loadedEntryCount: 0, hasMore: false)
        return SettingsView(hotkeyEnabled: true, missingPermissions: [],
                            availableDevices: { [MicrophoneDevice(id: "fixture-mic", name: "Fixture Microphone")] },
                            selectedDeviceID: { "fixture-mic" }, onSelectDevice: { _ in },
                            modelsStatus: { modelState }, onRefreshModelsStatus: {},
                            vocabularyPreview: { vocabulary }, vocabularyRevision: { 0 },
                            historyPage: { _ in historyFixture }, initialHistoryPage: historyFixture,
                            askHistoryPage: { _ in emptyAskFixture }, initialAskHistoryPage: emptyAskFixture,
                            initialTab: tab, initialDictionarySearch: search)
    }

    private func menuShots(
        _ menu: NSMenu,
        prefix: String,
        description: String,
        directory: URL,
        lines: inout [String]
    ) throws {
        let rows = menu.items.filter { !$0.isSeparatorItem }
        let name = "\(prefix).png"
        let view = VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.title).foregroundStyle(item.isEnabled ? .primary : .secondary)
                    Spacer()
                    if item.submenu != nil { Image(systemName: "chevron.right") }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 25)
            }
        }
        .padding(8)
        .background(.regularMaterial)
        try render(
            view,
            size: CGSize(width: 300, height: CGFloat(rows.count * 30 + 16)),
            to: directory.appendingPathComponent(name)
        )
        lines.append("| [\(name)](\(name)) | \(description) (production NSMenu model) |")
        for (index, item) in rows.enumerated() where item.submenu != nil {
            try menuShots(
                item.submenu!,
                prefix: "\(prefix)-submenu-\(index)",
                description: "\(description) → \(item.title)",
                directory: directory,
                lines: &lines
            )
        }
    }

    private func render(_ view: some View, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "SottoCurrentStateShots", code: 1)
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SottoCurrentStateShots", code: 2)
        }
        try data.write(to: url, options: .atomic)
        window.contentView = nil
    }
}
