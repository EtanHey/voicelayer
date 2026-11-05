import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U3a: Settings › Transcription to the 2.3 spec (S2–S6, K-ui, Etan's note #2), one guard per behaviour, plus the
/// V12 row-clipping guard at 720 and 390 pt and light + dark frames.
@MainActor
final class SettingsTranscriptionPaneTests: XCTestCase {
    private static func setting(_ effective: Any) -> [String: Any] { ["source": "default", "raw": NSNull(), "effective": effective] }
    private static let health: [String: Any] = [
        "type": "health", "recording_state": "idle",
        "model_status": ["residency": "loaded", "configured_effort": "accurate",
                         "configured_model": ["name": "large-v3-turbo", "size_mb": 1600, "installed": true]],
        "polish_controls": ["model_polish": setting("on"), "outro_gate": setting(true), "smart_chunks": setting(false)],
    ]
    private static var controls: PolishControlsState { PolishControlsState(healthEvent: health)! }

    private static let sizes: [RecognizerPickerEngine: Int] = [.parakeet: 2_509_000_000, .whisper: 1_620_000_000]

    private func state(selected: RecognizerPickerEngine = .parakeet, parakeet: RecognizerPickerResidency = .loaded,
                       whisper: RecognizerPickerResidency = .unloaded, whisperPresent: Bool = true,
                       downloads: [RecognizerPickerEngine: RecognizerDownloadProgress] = [:]) -> RecognizerPickerState {
        RecognizerPickerState(selected: selected, effective: selected, parakeet: parakeet, whisper: whisper,
                              parakeetAvailable: true, parakeetAssetsPresent: true, whisperAssetsPresent: whisperPresent,
                              diskBytes: whisperPresent ? Self.sizes : [.parakeet: Self.sizes[.parakeet]!],
                              downloads: downloads, idleUnloadSeconds: 300,
                              unloadWhenIdle: RecognizerUnloadWhenIdle(effective: false))
    }

    func testRowsNameTheRecognizerSayWhatItIsGoodForAndRecommendParakeet() {
        XCTAssertEqual(RecognizerPickerView.rowTitle(.parakeet), "Parakeet")
        XCTAssertEqual(RecognizerPickerView.rowTitle(.whisper), "Whisper large-v3-turbo")
        XCTAssertEqual(RecognizerPickerView.blurb(.parakeet), "Fastest on this Mac. English.")
        XCTAssertEqual(RecognizerPickerView.blurb(.whisper), "Slower. Handles Hebrew and mixed languages.")
    }

    func testStatusSaysLoadedOrOnDiskWithTheModelsOwnSize() {
        let loaded = state()
        XCTAssertEqual(RecognizerPickerView.subtitle(loaded, .parakeet), "Loaded · 2.51 GB")
        XCTAssertEqual(RecognizerPickerView.subtitle(loaded, .whisper), "On disk · 1.62 GB")
        XCTAssertEqual(RecognizerPickerView.subtitle(state(whisperPresent: false), .whisper), "Not downloaded")
    }

    /// Row 3 (lead 00:32Z) kept: a selected engine that is asleep loads on the next dictation, and says so.
    func testTheSelectedEngineAsleepSaysItLoadsWhenYouDictate() {
        XCTAssertEqual(RecognizerPickerView.subtitle(state(parakeet: .unloaded), .parakeet),
                       "On disk (loads when you dictate) · 2.51 GB")
    }

    /// S4: a download shows its percentage on its own row; the loaded recognizer stays usable.
    func testADownloadShowsItsPercentageAndNeverBlocksTheOtherRecognizer() {
        let progress = RecognizerDownloadProgress(state: "downloading", received: 340, total: 1000, error: nil)
        let downloading = state(whisperPresent: false, downloads: [.whisper: progress])
        XCTAssertEqual(RecognizerPickerView.subtitle(downloading, .whisper), "Downloading 34 %")
        XCTAssertTrue(downloading.canManage(.parakeet, action: .unload))
        XCTAssertFalse(downloading.isSelectionDisabled)
    }

    func testDeleteAsksInlineWithTheSpaceItFrees() {
        XCTAssertEqual(RecognizerPickerView.deleteMessage(state(), .whisper),
                       "Delete Whisper large-v3-turbo from this Mac? This frees 1.62 GB. You can download it again later.")
        let source = (try? String(contentsOf: Self.source("RecognizerPickerView.swift"), encoding: .utf8)) ?? ""
        XCTAssertFalse(source.contains(".alert("), "delete never asks in an alert")
    }

    /// S3: the recognizer in use can't be deleted, and the trash says why instead of sitting greyed out.
    func testTheRecognizerInUseCannotBeDeleted() {
        let whisperSelected = state(selected: .whisper, parakeet: .unloaded, whisper: .unloaded)
        XCTAssertFalse(whisperSelected.canManage(.whisper, action: .delete))
        XCTAssertEqual(whisperSelected.deleteBlockReason(for: .whisper),
                       "Whisper is the recognizer in use. Choose Parakeet before deleting it.")
        XCTAssertTrue(whisperSelected.canManage(.parakeet, action: .delete))
    }

    func testUnloadWhenIdleExplainsTheTradeWithoutInventingANumber() throws {
        let row = try XCTUnwrap(ModelsSettingsView.unloadWhenIdleRow(for: state()))
        XCTAssertEqual(row.title, "Unload when idle")
        XCTAssertFalse(row.isOn)
        XCTAssertEqual(row.line, "Frees about 2.5 GB of memory after 5 min without dictation. "
                       + "The next dictation loads Parakeet again, which adds a few seconds.")
    }

    func testProcessingRowsSayWhatEachDoesToYourWords() {
        let rows = ModelsSettingsView.processingRows(for: Self.controls, recognizer: state(selected: .whisper))
        XCTAssertEqual(rows.map(\.key.title), ["Model polish", "Remove made-up closing phrases", "Smart chunks"])
        XCTAssertEqual(rows[0].line, "Fixes punctuation and capitals. If polish would add or drop a word, VoiceBar keeps the raw text instead.",
                       "polish states its fidelity guard (stt-polish.ts CHANGED_LEXICAL_CONTENT)")
        XCTAssertNil(rows[2].lockedReason)
        XCTAssertTrue(rows[2].experimental)
    }

    /// Etan's note #2: smart chunks are Whisper-only, so with Parakeet the row is disabled with this tooltip.
    func testSmartChunksAreUnavailableWithParakeet() {
        let rows = ModelsSettingsView.processingRows(for: Self.controls, recognizer: state(selected: .parakeet))
        XCTAssertEqual(rows[2].lockedReason, "Unavailable with Parakeet")
        let source = (try? String(contentsOf: Self.source("ModelsSettingsView.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(source.contains(".modifier(OptionalHelp(text: row.lockedReason))"))
    }

    func testTheLastDictationNoteNamesTheTimeAndTheWriter() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        let at = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T14:30:00Z"))
        XCTAssertEqual(SettingsLastDictationNote(at: at, engine: .parakeet).text(calendar: calendar),
                       "Your last dictation, at 14:30, was transcribed by Parakeet.")
    }

    func testRecognizerDetailsSeparateTheChosenFromTheRunningModel() {
        let facts = ModelsSettingsView.detailFacts(state: .disconnected, recognizer: state(selected: .whisper,
                                                                                          parakeet: .unloaded, whisper: .unloaded))
        XCTAssertEqual(facts.map(\.label), ["Chosen", "Running now"])
        XCTAssertEqual(facts.map(\.value), ["Whisper large-v3-turbo", "Nothing loaded"])
    }

    func testTranscriptionRowsNeverClipBeforeTheSecondLine() {
        let picker = state()
        let rows = ModelsSettingsView.processingRows(for: Self.controls, recognizer: picker)
        let unload = ModelsSettingsView.unloadWhenIdleRow(for: picker)!
        SettingsRowClippingGuard.check(rows.map {
            SettingsRowCase(title: $0.key.title, description: $0.rowDescription,
                            controls: $0.experimental
                                ? AnyView(HStack { SettingsPill(text: "Experimental"); SettingsRowCase.toggle })
                                : SettingsRowCase.toggle)
        } + [
            SettingsRowCase(title: unload.title, description: unload.captionLines.joined(separator: " "),
                            controls: SettingsRowCase.toggle),
            SettingsRowCase(title: "Language", description: "Auto detects English and Hebrew per recording.",
                            controls: AnyView(Picker("", selection: .constant("Auto")) { Text("Auto").tag("Auto") }
                                .labelsHidden().fixedSize())),
        ])
    }

    /// Review R1 #737: the guard runs on the ACTUAL recognizer view (both rows, their real controls), installed and
    /// mid-download, at 720 and 390 pt, against the rendered pixels.
    func testTheRealRecognizerRowsNeverClipBeforeTheSecondLine() {
        let progress = RecognizerDownloadProgress(state: "downloading", received: 340, total: 1000, error: nil)
        for (name, picker) in [("installed", state()), ("asleep", state(parakeet: .unloaded)),
                               ("downloading", state(whisperPresent: false, downloads: [.whisper: progress]))] {
            SettingsRowClippingGuard.check("recognizer \(name)") { _ in
                RecognizerPickerView(state: picker, onSelect: { _ in }, onManage: { _, _ in })
            }
        }
    }

    /// Review R1 #737: trash Whisper while Parakeet is selected, select Whisper, then confirm. The open confirmation
    /// is withdrawn, and confirming against the new state sends nothing.
    func testAStaleDeleteConfirmationSendsNothing() {
        let asked = RecognizerDeleteConfirmation(engine: .whisper, state: state())
        XCTAssertEqual(asked.outcome(in: state()), .send(.delete))
        let whisperChosen = state(selected: .whisper, parakeet: .unloaded, whisper: .loaded)
        XCTAssertTrue(asked.isStale(in: whisperChosen))
        guard case .blocked = asked.outcome(in: whisperChosen) else { return XCTFail("a stale confirmation sent a command") }
        let reloaded = state(parakeet: .loaded, whisper: .loaded)
        XCTAssertTrue(asked.isStale(in: reloaded), "a residency change withdraws it too")
        let source = (try? String(contentsOf: Self.source("RecognizerPickerView.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(source.contains("switch confirmation.outcome(in: state)"), "Delete re-checks before sending")
        XCTAssertTrue(source.contains("confirmation.isStale(in: current) { deleting = nil }"))
    }

    func testWriteTranscriptionFramesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_U3A_SHOTS"] else {
            throw XCTSkip("Set VOICEBAR_U3A_SHOTS to write the Transcription frames")
        }
        let progress = RecognizerDownloadProgress(state: "downloading", received: 340, total: 1000, error: nil)
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        for (name, picker) in [("parakeet", state()), ("downloading", state(whisperPresent: false,
                                                                             downloads: [.whisper: progress]))] {
            try SettingsRowClippingGuard.writeFrames({
                ModelsSettingsView(state: ModelsSettingsState(healthEvent: Self.health), onToggleProcessing: { _, _ in },
                                   recognizerState: picker, onSelectRecognizer: { _ in },
                                   onManageRecognizer: { _, _ in }, onSetUnloadWhenIdle: { _ in },
                                   language: SettingsChoiceInput(options: ["Auto", "English", "Hebrew"],
                                                                 selected: { "Auto" }, select: { _ in }),
                                   lastDictationNote: SettingsLastDictationNote(at: at, engine: .parakeet))
            }, prefix: "transcription-\(name)", height: 760, to: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private static func source(_ file: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/\(file)")
    }
}
