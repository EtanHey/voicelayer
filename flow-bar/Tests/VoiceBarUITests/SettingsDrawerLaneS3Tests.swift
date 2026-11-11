import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// c7 lane S, PR 3 (Etan QA 2026-11-11, video 299.8 s "this is still ugly" on Dictionary and 303.8 s "that's still
/// slop UI" on Speech): the two panes in their CONNECTED states at the drawer's 420 pt. Fixture terms are generic
/// developer words, never anyone's personal dictionary.
@MainActor
final class SettingsDrawerLaneS3Tests: XCTestCase {
    static let busyReason = "Recording in progress"

    static func speechControls() -> SpeechControlsState? {
        func field(_ value: Any, source: String = "settings") -> [String: Any] {
            ["source": source, "raw": value, "effective": value]
        }
        func profile(engine: String, voice: String, rate: String, ms: Int, measured: String) -> [String: Any] {
            ["engine": field(engine), "voice": field(voice), "rate": field(rate), "last_first_audio_ms": ms,
             "last_first_audio": ["engine": measured, "origin": "speak", "fallback": false]]
        }
        return SpeechControlsState(controls: [
            "profiles": ["short": profile(engine: "edge", voice: "en-US-JennyNeural", rate: "+10%", ms: 640,
                                          measured: "edge-tts"),
                         "long": profile(engine: "clone", voice: "theo-c4s", rate: "+0%", ms: 1200,
                                         measured: "qwen3-tts")],
            "short_limit_chars": field(400),
            "clone_daemon": "up",
            "available_voices": [["engine": "edge", "voice": "en-US-JennyNeural"],
                                 ["engine": "edge", "voice": "en-US-GuyNeural"],
                                 ["engine": "clone", "voice": "theo-c4s"]],
        ])
    }

    static let personalTerms: [STTDictionaryEntry] = [
        STTDictionaryEntry(canonical: "Kubernetes", variants: ["cooper netties", "kuber nets"]),
        STTDictionaryEntry(canonical: "PostgreSQL", variants: ["post gress", "postgres sequel"]),
        STTDictionaryEntry(canonical: "TypeScript", variants: []),
        STTDictionaryEntry(canonical: "SwiftUI", variants: ["swift you eye"]),
        STTDictionaryEntry(canonical: "GraphQL", variants: ["graph queue el"]),
        STTDictionaryEntry(canonical: "Redis", variants: ["reddis"]),
        STTDictionaryEntry(canonical: "Terraform", variants: []),
        STTDictionaryEntry(canonical: "WebSocket", variants: ["web socket"]),
        STTDictionaryEntry(canonical: "Xcode", variants: ["ex code"]),
        STTDictionaryEntry(canonical: "nginx", variants: ["engine x", "engine ex"]),
        STTDictionaryEntry(canonical: "OAuth", variants: ["oh auth"]),
        STTDictionaryEntry(canonical: "Vite", variants: ["veet"]),
    ]
    static let includedTerms: [STTDictionaryEntry] = [
        STTDictionaryEntry(canonical: "GitHub", variants: ["git hub"]),
        STTDictionaryEntry(canonical: "JSON", variants: ["jason"]),
        STTDictionaryEntry(canonical: "npm", variants: []),
        STTDictionaryEntry(canonical: "macOS", variants: ["mac oh es"]),
    ]

    static func dictionaryPreview() -> STTVocabularyPreview {
        STTVocabularyPreview(
            updatedAt: "2026-11-11T10:00:00Z", entries: personalTerms,
            displayEntries: personalTerms.map { STTDictionaryDisplayEntry(source: "personal", entry: $0) }
                + includedTerms.map { STTDictionaryDisplayEntry(source: "bundled", entry: $0) }
        )
    }

    static func pane(_ tab: SettingsTab) -> SettingsView {
        let preview = dictionaryPreview()
        let controls = speechControls()
        return SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { SettingsDrawerLaneSSnapshotTests.modelsState() }, onRefreshModelsStatus: {},
            speechControls: { controls }, speechConnected: { true }, speechBusyReason: { busyReason },
            onChangeSpeech: { _, _ in }, onSelectSpeechEngine: { _, _, _ in }, onPreviewSpeech: { _ in },
            vocabularyPreview: { preview }, vocabularyRevision: { 0 },
            initialTab: tab, initialDictionaryPreview: preview
        )
    }

    static func drawer(_ tab: SettingsTab) -> some View {
        NotchSettingsDrawer(
            selectedTab: tab, appearance: .dark,
            context: NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in AnyView(pane(tab).notchDrawerPane(tab)) }),
            onSelectTab: { _ in }
        )
    }

    /// The drawer at its real height, the pane's scroll view moved down by `offset` points.
    static func renderScrolled(_ view: some View, offset: CGFloat, name: String) throws -> NSBitmapImageRep {
        try SettingsDrawerLaneSSnapshotTests.render(view, height: NotchSettingsDrawerPresentation.lowerSurfaceHeight,
                                                    name: name, scrollOffset: offset)
    }

    func testRenderLaneS3Scenarios() throws {
        _ = try SettingsDrawerLaneSSnapshotTests.render(Self.drawer(.speech), height: 1000, name: "s3-speech")
        _ = try SettingsDrawerLaneSSnapshotTests.render(Self.drawer(.dictionary), height: 900, name: "s3-dictionary")
        _ = try Self.renderScrolled(Self.drawer(.speech), offset: 150, name: "s3-speech-scrolled")
        _ = try Self.renderScrolled(Self.drawer(.dictionary), offset: 120, name: "s3-dictionary-scrolled")
        _ = try SettingsDrawerLaneSSnapshotTests.render(Self.drawer(.speech)
            .environment(\.settingsHoverPreview, SettingsHoverPreview(lockedReasons: true)), height: 1000,
            name: "s3-speech-hover")
        _ = try SettingsDrawerLaneSSnapshotTests.render(Self.drawer(.dictionary)
            .environment(\.settingsHoverPreview, SettingsHoverPreview(termRowID: "personal:Kubernetes")), height: 900,
            name: "s3-dictionary-hover")
    }

    /// The brightest difference from the backdrop on one pixel row (0...1), across the pane's width.
    static func rowContrast(_ bitmap: NSBitmapImageRep, atY y: CGFloat) -> CGFloat {
        let scale = CGFloat(bitmap.pixelsWide) / SettingsDrawerLaneSSnapshotTests.drawerWidth
        let row = Int(y * scale)
        guard let backdrop = bitmap.colorAt(x: 1, y: row) else { return 1 }
        var worst: CGFloat = 0
        for x in stride(from: Int(16 * scale), to: bitmap.pixelsWide - Int(16 * scale), by: 2) {
            guard let c = bitmap.colorAt(x: x, y: row) else { continue }
            worst = max(worst, abs(c.redComponent - backdrop.redComponent), abs(c.greenComponent - backdrop.greenComponent))
        }
        return worst
    }

    /// Etan's video (303.8 s): scrolling Speech cut the previous card's labels straight through under the tab bar.
    /// Sweep the real-height drawer through its scroll range: the first points under the tab bar never show content
    /// at more than a trace, so nothing is cut mid-line there. Fails on 87ded366 (hard edge).
    func testScrolledContentNeverCutsUnderTheTabBar() throws {
        let paneTop = NotchSettingsDrawerPresentation.topInset + NotchSettingsDrawerPresentation.tabBarHeight
        var worst: (offset: CGFloat, contrast: CGFloat) = (0, 0)
        for offset in stride(from: CGFloat(0), through: 420, by: 14) {
            let bitmap = try Self.renderScrolled(Self.drawer(.speech), offset: offset, name: "s3-sweep-scratch")
            for dy in [0.5, 1.5] as [CGFloat] {
                let contrast = Self.rowContrast(bitmap, atY: paneTop + dy)
                if contrast > worst.contrast { worst = (offset, contrast) }
            }
        }
        XCTAssertLessThan(worst.contrast, 0.12,
                          "[S3-scroll] content cut at the pane's top edge: contrast \(worst.contrast) at offset \(worst.offset)")
    }

    typealias Layout = SettingsDrawerLaneSLayoutTests

    /// Speech (303.8 s, "that's still slop UI"): no stray "0%" (the value reads "Normal"), no inline "Recording in
    /// progress" beside a disabled Preview, and each profile's metadata is one helper line ("Based on the last
    /// reported cutoff." no longer repeats under both headers). All three fail on 87ded366.
    func testSpeechProfilesReadCleanlyAtRest() throws {
        let lines = try Layout.paintedLines(Self.drawer(.speech), height: 1000)
        _ = try Layout.line(lines, containing: "long reads")
        XCTAssertFalse(lines.contains { $0.text == "0%" }, "[S3-speech] a stray 0% beside the slider: \(lines.map(\.text))")
        _ = try Layout.line(lines, containing: "normal")
        XCTAssertFalse(lines.contains { $0.text.contains("recording in progress") },
                       "[S3-speech] the busy reason is painted inline: \(lines.map(\.text))")
        XCTAssertFalse(lines.contains { $0.text.contains("based on the last reported cutoff") },
                       "[S3-speech] profile metadata repeats under each header: \(lines.map(\.text))")
    }

    /// Hovering the disabled Preview shows the busy reason beside it (the locked-switch pattern).
    func testHoveringADisabledPreviewSaysWhy() throws {
        let lines = try Layout.paintedLines(Self.drawer(.speech)
            .environment(\.settingsHoverPreview, SettingsHoverPreview(lockedReasons: true)), height: 1000)
        XCTAssertGreaterThanOrEqual(lines.filter { $0.text.contains("recording in progress") }.count, 2,
                                    "[S3-speech] each Preview's reason shows on hover")
    }

    /// Dictionary (299.8 s, "this is still ugly"): Add term sits on the search field's row, and a term and its misheard
    /// spellings share one line. Both fail on 87ded366 (Add term above the search; spellings on a second line).
    func testDictionaryToolbarIsOneRowAndTermsAreOneLine() throws {
        let lines = try Layout.paintedLines(Self.drawer(.dictionary), height: 900)
        let add = try Layout.line(lines, containing: "add term")
        let search = try Layout.line(lines, containing: "search terms")
        XCTAssertEqual(add.box.midY, search.box.midY, accuracy: 4, "[S3-dict] Add term and search share a row")
        let term = try Layout.line(lines, containing: "kubernetes")
        let spellings = try Layout.line(lines, containing: "cooper netties")
        XCTAssertEqual(spellings.box.midY, term.box.midY, accuracy: 4, "[S3-dict] term and spellings share a line")
    }
}
