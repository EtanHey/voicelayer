import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// UXP-1: Settings read "Included terms (0)" with a chevron that opened nothing. Until the daemon's bundled rows
/// arrive the count is unknown, not zero, and opening the Dictionary asks for them again if they are missing.
/// Rows are synthetic; the real bundled list lives in TS and is never copied into Swift.
@MainActor
final class DictionaryIncludedSnapshotTests: XCTestCase {
    private let bundledRow = STTDictionaryDisplayEntry(
        source: "bundled", entry: STTDictionaryEntry(canonical: "Synthterm", variants: ["synth term"])
    )
    private let personalRow = STTDictionaryDisplayEntry(
        source: "personal", entry: STTDictionaryEntry(canonical: "Mine", variants: [])
    )

    private func makeState() -> VoiceState {
        VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { ["Mine"] },
            transcriptionVocabularyAliasLoader: { [] }
        )
    }

    // MARK: - Header

    func testBeforeTheBundledRowsArriveTheHeaderSaysLoadingNotZero() {
        let index = STTDictionaryDisplayIndex(preview: STTVocabularyPreview(
            updatedAt: nil, promptTerms: ["Mine"], aliases: []
        ))

        let header = SettingsView.includedTermsHeader(index: index, matches: nil, loaded: true)

        XCTAssertEqual(header, .init(title: "Included terms", isLoading: true, showsChevron: false))
    }

    func testBeforeTheFirstFileLoadTheHeaderSaysLoading() {
        let index = STTDictionaryDisplayIndex(entries: [bundledRow])

        let header = SettingsView.includedTermsHeader(index: index, matches: nil, loaded: false)

        XCTAssertEqual(header, .init(title: "Included terms", isLoading: true, showsChevron: false))
    }

    func testATrulyEmptyBundledListHasNoChevron() {
        let index = STTDictionaryDisplayIndex(preview: STTVocabularyPreview(
            updatedAt: nil, entries: [], displayEntries: [personalRow]
        ))

        let header = SettingsView.includedTermsHeader(index: index, matches: nil, loaded: true)

        XCTAssertEqual(header, .init(title: "Included terms (0)", isLoading: false, showsChevron: false))
    }

    func testArrivedBundledRowsShowTheirCountAndAChevron() {
        let index = STTDictionaryDisplayIndex(preview: STTVocabularyPreview(
            updatedAt: nil, entries: [], displayEntries: [bundledRow, personalRow]
        ))

        XCTAssertEqual(
            SettingsView.includedTermsHeader(index: index, matches: nil, loaded: true),
            .init(title: "Included terms (1)", isLoading: false, showsChevron: true)
        )
        XCTAssertEqual(
            SettingsView.includedTermsHeader(index: index, matches: 0, loaded: true),
            .init(title: "Included terms (0 of 1)", isLoading: false, showsChevron: true)
        )
    }

    func testAPersonalEditKeepsKnowingTheBundledRowsArrived() {
        let index = STTDictionaryDisplayIndex(entries: [bundledRow], bundledRowsKnown: true)
        let pending = STTDictionaryDisplayIndex(entries: [], bundledRowsKnown: false)

        XCTAssertTrue(index.bundledRowsKnown)
        XCTAssertFalse(pending.bundledRowsKnown)
    }

    // MARK: - Re-request

    func testTheSnapshotIsRequestedAgainOnlyWhileTheBundledRowsAreMissing() {
        let state = makeState()
        var sent: [String] = []
        state.sendCommand = { if let cmd = $0["cmd"] as? String { sent.append(cmd) } }
        state.setConnectionStatus(true)
        sent.removeAll()

        state.requestVocabularySnapshotIfMissing()
        XCTAssertEqual(sent, ["vocab_list"], "missing rows must be asked for again")

        state.handleEvent([
            "type": "vocab_list",
            "entries": [["canonical": "Mine", "variants": []]],
            "display_entries": [
                ["row_id": "bundled:Synthterm", "source": "bundled", "canonical": "Synthterm", "variants": []],
                ["row_id": "personal:Mine", "source": "personal", "canonical": "Mine", "variants": []],
            ],
        ])
        sent.removeAll()

        state.requestVocabularySnapshotIfMissing()
        XCTAssertEqual(sent, [], "rows already here: no extra daemon round-trip")
    }

    func testOpeningTheDictionaryTabAsksForTheSnapshot() async {
        var requests = 0
        let hosting = NSHostingController(rootView: SettingsView(
            hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            onRequestVocabularySnapshot: { requests += 1 },
            initialTab: .dictionary
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.contentView?.layoutSubtreeIfNeeded()

        let asked = await settle { requests > 0 }
        XCTAssertTrue(asked, "the Dictionary tab never asked for the missing snapshot")
        window.contentViewController = nil
    }
}
