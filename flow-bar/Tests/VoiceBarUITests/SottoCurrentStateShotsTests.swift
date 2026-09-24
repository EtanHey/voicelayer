import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Production views in an offscreen AppKit host. Fixtures are deliberately synthetic.
@MainActor
final class SottoCurrentStateShotsTests: XCTestCase {
    private var syntheticRecordingPath: String?
    private var syntheticHistoryPage: SettingsHistoryPage?
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
        let recordingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sotto-shots-\(ProcessInfo.processInfo.processIdentifier)")
        let recordingDirectory = recordingRoot
            .appendingPathComponent("2025-09-23/2025-09-23T04-20-00-000Z-fixture")
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordingRoot) }
        try Data("{\"created_at\":\"2025-09-23T04:20:00.000Z\",\"provenance\":{\"whisper_model_path\":\"/fixture/ggml-whisper-model.bin\",\"performance_effort\":\"balanced\"}}"
            .utf8)
            .write(to: recordingDirectory.appendingPathComponent("metadata.json"))
        try "This is a synthetic dictation for screenshot review."
            .write(to: recordingDirectory.appendingPathComponent("voicelayer-transcript.txt"),
                   atomically: true, encoding: .utf8)
        try Data([0]).write(to: recordingDirectory.appendingPathComponent("audio.wav"))
        syntheticRecordingPath = recordingDirectory.appendingPathComponent("audio.wav").path
        syntheticHistoryPage = SettingsHistoryArchive.loadPage(from: recordingRoot)
        var lines = [
            "# Current source-state screenshots",
            "",
            "All content below uses synthetic fixtures. PNGs are rendered by production SwiftUI views inside offscreen AppKit windows at 2×. Record the generating checkout SHA in the lane report.",
            "",
            "| File | Surface and state |",
            "|---|---|",
        ]
        func shot(_ name: String, _ description: String, _ view: some View, size: CGSize,
                  appearance: NSAppearance.Name = .darkAqua) throws {
            if name.hasPrefix("popover-") {
                try renderPopover(view, size: size, to: directory.appendingPathComponent(name))
            } else {
                try render(view, size: size, to: directory.appendingPathComponent(name),
                           settingsWindow: name.hasPrefix("settings-"), appearance: appearance)
            }
            lines.append("| [\(name)](\(name)) | \(description) |")
        }

        for (name, mode, transcript) in [
            ("idle", VoiceMode.idle, ""),
            ("recording", .recording, ""),
            ("transcribing", .transcribing, ""),
            ("agent-speaking", .speaking, ""),
            ("no-transcript-yet", .idle, ""),
            ("remote-stt-configured", .idle, ""),
            ("unknown-locality", .idle, ""),
            ("numbered-list", .idle,
             "Three things.\n1. Fix the popover and its focus ring.\n2. Ship it with a clean preview.\n3. Tell Etan."),
            (
                "long-transcript",
                .idle,
                "A synthetic paragraph about a sample recording.\nIt continues on a second line.\nThe third line is also synthetic."
            ),
        ] {
            let remote: Bool? = switch name {
            case "remote-stt-configured": true
            case "unknown-locality": nil
            default: false
            }
            let footer = VoiceBarFooterPresentation.resolve(
                isConnected: true, mode: mode, captureLive: mode == .recording,
                errorMessage: nil, remoteSTTConfigured: remote, hasFreshHealth: true
            )
            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let suffix = appearance == "light" ? "" : "-dark"
                try shot("popover-\(name)\(suffix).png", "Menu bar popover: \(name), \(appearance)",
                         MenuBarPopoverView(
                             footer: footer, hotkeyHint: "Hold F5 to dictate",
                             microphoneName: "Built-in Microphone", transcript: transcript
                         ).environment(\.colorScheme, scheme),
                         size: CGSize(width: 300, height: transcript.isEmpty ? 240 : 320))
            }
        }

        let router = NoopRouter()
        for (name, mode, hover) in [
            ("idle", VoiceMode.idle, false),
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
                state: state, commandRouter: router, onOpenSettings: {}, includesPanelOutsets: true
            ), size: CGSize(width: 600, height: 180))
        }

        let panelState = syntheticState()
        panelState.recentTranscriptionEntries = [
            RecentTranscriptionEntry(text: "A synthetic recent transcription."),
            RecentTranscriptionEntry(text: "Another short sample with no personal content."),
        ]
        let panel = BarView(state: panelState, commandRouter: router, onOpenSettings: {})
        try shot("notch-recent.png", "Notch panel: Recent Transcriptions", panel.historyPopover,
                 size: CGSize(width: 348, height: 274))

        let menu = PillContextMenuController()
        menu.transcriptProvider = { "A synthetic recent transcription." }
        menu.recentTranscriptionsProvider = { ["A synthetic recent transcription.", "Another sample."] }
        menu.transcriptionVocabularyTermsProvider = { ["SwiftUI", "whisper.cpp"] }
        // Mixed on purpose: the aggregate and the Teams/Zoom loopbacks must not reach the Microphone submenu.
        menu.availableDevicesProvider = { [
            MicrophoneDevice(id: "fixture-aggregate", name: "CADefaultDeviceAggregate-1234-0",
                             uid: "CADefaultDeviceAggregate-1234-0", isVirtualOrAggregateTransport: true),
            MicrophoneDevice(id: "fixture-mic", name: "Fixture Microphone", uid: "fixture-mic",
                             isVirtualOrAggregateTransport: false),
            MicrophoneDevice(id: "fixture-teams", name: "Microsoft Teams Audio", uid: "fixture-teams",
                             isVirtualOrAggregateTransport: true),
            MicrophoneDevice(id: "fixture-usb", name: "Fixture USB Microphone", uid: "fixture-usb",
                             isVirtualOrAggregateTransport: false),
            MicrophoneDevice(id: "fixture-zoom", name: "ZoomAudioDevice", uid: "fixture-zoom",
                             isVirtualOrAggregateTransport: true),
        ] }
        menu.selectedDeviceIDProvider = { "fixture-mic" }
        try menuShots(
            menu.makeMenu(),
            prefix: "menu",
            description: "Right-click menu",
            directory: directory,
            lines: &lines
        )

        // #141 round 2: the device in use is a hidden one; the submenu still says so, checked and disabled.
        menu.selectedDeviceIDProvider = { "fixture-teams" }
        try menuShots(
            menu.makeMicrophoneSubmenu(),
            prefix: "menu-microphone-hidden-in-use",
            description: "Right-click → Microphone while a hidden device is in use",
            directory: directory,
            lines: &lines
        )
        menu.selectedDeviceIDProvider = { "fixture-mic" }

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
                     settings(tab: tab, vocabulary: tab == .dictionary ? populated : empty,
                              historyDetail: tab != .history),
                     size: CGSize(width: 780, height: 620))
            try shot("settings-\(tab.title.lowercased())-light.png", "Settings: \(tab.title), light",
                     settings(tab: tab, vocabulary: tab == .dictionary ? populated : empty,
                              historyDetail: tab != .history),
                     size: CGSize(width: 780, height: 620), appearance: .aqua)
        }
        try shot("settings-resized.png", "Settings: General at 960×740 pt",
                 settings(tab: .general, vocabulary: empty),
                 size: CGSize(width: 960, height: 740))
        try shot("settings-resized-light.png", "Settings: General at 960×740 pt, light",
                 settings(tab: .general, vocabulary: empty),
                 size: CGSize(width: 960, height: 740), appearance: .aqua)
        for (suffix, appearance) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
            try shot("settings-models-sidebar-focused\(suffix).png",
                     "Settings: sidebar has keyboard focus (native selection highlight under the row)",
                     settings(tab: .models, vocabulary: empty),
                     size: CGSize(width: 780, height: 620), appearance: appearance)
        }
        try shot("settings-general-agent-speaking.png", "Settings General: sidebar footer while an agent speaks",
                 settings(tab: .general, vocabulary: empty, footerMode: .speaking),
                 size: CGSize(width: 780, height: 620))
        try shot("settings-general-agent-speaking-light.png",
                 "Settings General: sidebar footer while an agent speaks, light",
                 settings(tab: .general, vocabulary: empty, footerMode: .speaking),
                 size: CGSize(width: 780, height: 620), appearance: .aqua)
        let threeMics: [MicrophonePriorityRow] = [
            .init(uid: "fixture-rx", deviceID: "1", label: "Wireless Mic Rx", isConnected: true),
            .init(uid: "fixture-built-in", deviceID: "2", label: "MacBook Pro Microphone", isConnected: true),
            .init(uid: "fixture-airpods", deviceID: nil, label: "AirPods", isConnected: false),
            .init(uid: "CADefaultDeviceAggregate-fixture", deviceID: "9", label: "Virtual Audio", isConnected: true),
        ]
        for (suffix, appearance) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
            try shot("settings-general-mic-priority\(suffix).png",
                     "Settings General: microphone priority (Default badge, Make default, drag handles)",
                     settings(tab: .general, vocabulary: empty, micRows: threeMics),
                     size: CGSize(width: 780, height: 1000), appearance: appearance)
        }
        try shot("settings-general-advanced.png", "Settings General: Advanced F5 helper expanded",
                 settings(tab: .general, vocabulary: empty, advanced: true),
                 size: CGSize(width: 960, height: 740))
        for (suffix, appearance) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
            try shot("settings-general-advanced-installed\(suffix).png",
                     "Settings General: Advanced expanded, F5 key helper installed (Reinstall, plain copy)",
                     settings(tab: .general, vocabulary: empty, advanced: true, remapActive: true),
                     size: CGSize(width: 960, height: 1180), appearance: appearance)
            try shot("settings-general-permission-missing\(suffix).png",
                     "Settings General: Input Monitoring missing (Open shown only on the missing row)",
                     settings(tab: .general, vocabulary: empty, missingPermissions: [.inputMonitoring]),
                     size: CGSize(width: 780, height: 620), appearance: appearance)
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
        for (suffix, appearance) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
            try shot("settings-models-unavailable\(suffix).png", "Settings Models: VoiceLayer not connected",
                     settings(tab: .models, vocabulary: empty, modelState: .unavailable),
                     size: CGSize(width: 780, height: 620), appearance: appearance)
        }
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
            "## Popover geometry",
            "",
            "Popover shots use a 300 pt canvas, the popover's own width (276 pt column + 12 pt padding each side), so every PNG shows even left and right margins. `MenuBarPopoverLayoutTests` pins the geometry, not this index:",
            "",
            "- Rows are one 10 pt `VStack` rhythm. The status word sits left and \"Hold F5 to dictate\" right, on one row.",
            "- The mic picker is a bordered row with no fill and no selected or highlight state.",
            "- The transcript text and the copy button share a vertical midline (midY equal ± 1 pt).",
            "- Open Settings… and Quit VoiceBar sit side by side in one row, equal width.",
            "- `.focusEffectDisabled()` is set on the root, so no focus ring draws when the popover opens. The real MenuBarExtra open is still a P10 live check.",
            "",
            "## Limits",
            "",
            "The right-click menu images are drawn from the production `NSMenu` model because AppKit cannot snapshot a tracking menu in an offscreen window. The idle-hover pill shot is omitted because an offscreen state flag does not produce a real pointer hover. Hover and pressed optics need a live pointer event and are not proven here. These are source-state artifacts, not installed-app screenshots.",
        ])
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("index.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    func testWritePillButtonShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_P05_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_P05_SHOTS_DIR to write pill button artifacts")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let router = NoopRouter()
        var lines = ["# P05 pill buttons", "", "Synthetic, offscreen 2× production-view renders.", ""]
        for (appearanceName, appearance, scheme, isDark) in [
            ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark, true),
            ("light", NSAppearance.Name.aqua, ColorScheme.light, false),
        ] {
            for (name, mode, hover) in [
                // Idle with the notch expanded: the launcher (Mic · History · Settings). A collapsed,
                // resting idle draws only the hardware notch, so offscreen it renders blank. The
                // per-button hover circle needs a live pointer and is shot separately below.
                ("idle", VoiceMode.idle, false),
                ("recording", .recording, false),
                ("transcribing", .transcribing, false),
                ("error", .error, false),
                // voice_speak with the teleprompter hidden: waveform · eye · Stop on the pre-P05 optics.
                ("speaking-dismissed", .speaking, false),
                ("disconnected", .disconnected, false),
            ] {
                let state = syntheticState()
                state.mode = mode
                state.isHovering = hover
                if mode == .recording { state.recordingMode = "vad" }
                if mode == .error { state.errorMessage = "Synthetic error" }
                if mode == .speaking {
                    state.statusText = "A synthetic spoken reply."
                    state.dismissTeleprompter()
                }
                if mode == .disconnected { state.isConnected = false }
                let filename = "pill-\(name)-\(appearanceName).png"
                try render(
                    BarView(state: state, commandRouter: router, onOpenSettings: {}, includesPanelOutsets: true)
                        .environment(\.colorScheme, scheme),
                    size: CGSize(width: 600, height: 180),
                    to: directory.appendingPathComponent(filename),
                    appearance: appearance
                )
                lines.append("- [\(filename)](\(filename)): \(name), \(appearanceName)")
            }
            for (name, icon, destructive) in [
                ("mic", "mic.fill", false),
                ("history", "clock.arrow.circlepath", false),
                ("settings", "gearshape", false),
                ("stop", "stop.fill", true),
                ("cancel", "xmark", false),
                ("lock", "lock.fill", false),
            ] {
                for visualState in ["hover", "pressed"] {
                    let button = VoiceBarPillControlButton(
                        icon: icon,
                        optics: VoiceBarNotchControlOptics.resolve(for: icon),
                        foreground: isDark ? .white : .black,
                        halo: .clear,
                        isSelected: false,
                        isDestructive: destructive,
                        accessibilityLabel: name,
                        accessibilityHint: "",
                        previewHovered: visualState == "hover",
                        previewPressed: visualState == "pressed",
                        action: {}
                    )
                    let filename = "control-\(name)-\(visualState)-\(appearanceName).png"
                    try render(
                        button.frame(width: 100, height: 88)
                            .background(isDark ? Color.black : Color.white)
                            .environment(\.colorScheme, scheme),
                        size: CGSize(width: 100, height: 88),
                        to: directory.appendingPathComponent(filename),
                        appearance: appearance
                    )
                    lines.append("- [\(filename)](\(filename)): \(name) \(visualState), \(appearanceName)")
                }
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("index.md"), atomically: true, encoding: .utf8
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
            "polish_controls": [
                "model_polish": ["source": "default", "raw": NSNull(), "effective": "on"],
                "outro_gate": ["source": "default", "raw": NSNull(), "effective": true],
                "smart_chunks": ["source": "default", "raw": NSNull(), "effective": false],
                "smart_boundaries": ["source": "default", "raw": NSNull(), "effective": false],
            ],
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
        advanced: Bool = false,
        remapActive: Bool = false,
        missingPermissions: [HotkeyPermission] = [],
        micRows: [MicrophonePriorityRow]? = nil,
        historyDetail: Bool = true,
        modelState: ModelsSettingsState = .loading,
        footerMode: VoiceMode = .idle
    ) -> SettingsView {
        let historyFixture = historyDetail
            ? syntheticHistoryPage ?? SettingsHistoryPage(groups: [], loadedEntryCount: 0, hasMore: false)
            : SettingsHistoryPage(groups: [], loadedEntryCount: 0, hasMore: false)
        let emptyAskFixture = SettingsAskHistoryPage(groups: [], loadedEntryCount: 0, hasMore: false)
        let recordingPath = syntheticRecordingPath
        return SettingsView(hotkeyEnabled: true, missingPermissions: missingPermissions,
                            availableDevices: { [MicrophoneDevice(id: "fixture-mic", name: "Fixture Microphone")] },
                            selectedDeviceID: { "fixture-mic" }, onSelectDevice: { _ in },
                            prioritySnapshot: {
                                if let micRows {
                                    return MicrophonePrioritySnapshot(
                                        rows: micRows, nextDeviceName: micRows.first?.label
                                    )
                                }
                                return MicrophonePrioritySnapshot(rows: [
                                    .init(
                                        uid: "fixture-mic",
                                        deviceID: "fixture-mic",
                                        label: "Fixture Microphone",
                                        isConnected: true
                                    ),
                                    .init(
                                        uid: "CADefaultDeviceAggregate-fixture",
                                        deviceID: "fixture-virtual",
                                        label: "Virtual Audio",
                                        isConnected: true
                                    ),
                                ], nextDeviceName: "Fixture Microphone")
                            },
                            modelsStatus: { modelState }, onRefreshModelsStatus: {},
                            onSelectResidency: { _ in },
                            vocabularyPreview: { vocabulary }, vocabularyRevision: { 0 },
                            isHotkeyRemapActive: { remapActive },
                            lastDictationEntry: {
                                RecentTranscriptionEntry(text: "Synthetic dictation for visual review.",
                                                         recordingPath: recordingPath)
                            },
                            historyPage: { _ in historyFixture }, initialHistoryPage: historyFixture,
                            askHistoryPage: { _ in emptyAskFixture }, initialAskHistoryPage: emptyAskFixture,
                            footerPresentation: {
                                .resolve(isConnected: true, mode: footerMode, captureLive: false,
                                         errorMessage: nil, remoteSTTConfigured: false, hasFreshHealth: true)
                            },
                            initialTab: tab, initialDictionarySearch: search,
                            initialAdvancedExpanded: advanced)
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

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.firstTable(in: $0) }.first
    }

    private func render(_ view: some View, size: CGSize, to url: URL,
                        settingsWindow: Bool = false, appearance: NSAppearance.Name = .darkAqua) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: settingsWindow ? [.titled, .resizable] : .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        if settingsWindow { window.makeKeyAndOrderFront(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if url.lastPathComponent.contains("sidebar-focused"), let table = firstTable(in: host) {
            window.makeFirstResponder(table)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
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
        if settingsWindow { window.orderOut(nil) }
        window.contentView = nil
    }

    private func renderPopover(_ view: some View, size: CGSize, to url: URL) throws {
        let isDark = url.lastPathComponent.hasSuffix("-dark.png")
        let background = Color(.sRGB, white: isDark ? 0.12 : 1, opacity: 1)
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height,
                                                         alignment: .topLeading).background(background))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SottoCurrentStateShots", code: 3)
        }
        try png.write(to: url, options: .atomic)
    }
}
