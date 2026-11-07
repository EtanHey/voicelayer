import XCTest
@testable import VoiceBarUI

/// Settings › Transcription recognizer rows (2.2.61 ledger S3–S6 and the stale fallback line).
@MainActor
final class RecognizerRowsTests: XCTestCase {
    private func state(selected: RecognizerPickerEngine = .parakeet, parakeet: RecognizerPickerResidency = .loaded,
                       whisper: RecognizerPickerResidency = .unloaded, parakeetPresent: Bool = true,
                       whisperPresent: Bool = true, parakeetBytes: Int = 2_509_000_000,
                       downloads: [RecognizerPickerEngine: RecognizerDownloadProgress] = [:],
                       idle: Double? = 600) -> RecognizerPickerState {
        RecognizerPickerState(selected: selected, effective: selected, parakeet: parakeet, whisper: whisper,
                              parakeetAvailable: true, parakeetAssetsPresent: parakeetPresent,
                              whisperAssetsPresent: whisperPresent,
                              diskBytes: [.parakeet: parakeetBytes, .whisper: whisperPresent ? 1_620_000_000 : 0],
                              downloads: downloads, idleUnloadSeconds: idle)
    }

    // MARK: S3 icons: download when off disk, trash when on disk

    func testOffDiskShowsDownloadNamedSetUpForParakeet() {
        let s = state(selected: .whisper, parakeet: .unloaded, whisper: .loaded, parakeetPresent: false, parakeetBytes: 0)
        XCTAssertEqual(s.assetActions(for: .parakeet), [.download])
        XCTAssertEqual(RecognizerPickerView.assetLabel(.parakeet, .download), "Set up Parakeet TDT 0.6B v3")
        XCTAssertEqual(RecognizerPickerView.assetLabel(.whisper, .download), "Download Whisper large-v3-turbo")
    }

    func testOnDiskShowsTrashOnBothRows() {
        let s = state()
        XCTAssertEqual(s.assetActions(for: .parakeet), [.delete])
        XCTAssertEqual(s.assetActions(for: .whisper), [.delete])
    }

    /// CodeRabbit #672: an empty named Parakeet file has 0 bytes; the daemon's "delete first" refusal proves it exists.
    func testEmptyNamedParakeetFileStillOffersDelete() {
        let refused = RecognizerDownloadProgress(state: "error", received: 0, total: 0, error: "assets-exist-delete-first")
        let s = state(selected: .whisper, parakeet: .unloaded, whisper: .loaded, parakeetPresent: false,
                      parakeetBytes: 0, downloads: [.parakeet: refused])
        XCTAssertEqual(s.assetActions(for: .parakeet), [.download, .delete])
        XCTAssertTrue(s.canManage(.parakeet, action: .delete))
        XCTAssertEqual(RecognizerPickerView.deleteMessage(s, .parakeet),
                       "Remove its incomplete model files from disk? You can download it again later.")
    }

    func testDeleteConfirmationShowsSizeAndUnloadsAResidentModelFirst() {
        let s = state()
        let size = ByteCountFormatter.string(fromByteCount: 2_509_000_000, countStyle: .file)
        XCTAssertEqual(RecognizerPickerView.deleteMessage(s, .parakeet),
                       "Unload it and remove \(size) from disk? You can download it again later.")
        XCTAssertNil(s.deleteBlockReason(for: .parakeet), "a loaded model is unloaded, not refused")
        XCTAssertTrue(RecognizerPickerView.deleteMessage(s, .whisper).hasPrefix("Remove "))
    }

    /// "Why does delete not work here?" — the trash explains instead of sitting greyed out.
    func testDeletingTheOnlyInstalledRecognizerExplainsWhy() {
        let s = state(selected: .whisper, parakeet: .unloaded, whisper: .loaded, parakeetPresent: false, parakeetBytes: 0)
        XCTAssertEqual(s.deleteBlockReason(for: .whisper),
                       "Keep at least one downloaded recognizer. Download Parakeet before deleting Whisper.")
    }

    // MARK: S3 Load/Unload on both rows; choosing loads it

    func testBothRowsOfferResidencyAndLoadOnTheOtherRowSelectsIt() throws {
        let s = state(selected: .whisper, parakeet: .unloaded, whisper: .loaded)
        XCTAssertEqual(s.residencyAction(for: .whisper), .unload)
        XCTAssertEqual(s.residencyAction(for: .parakeet), .load)
        XCTAssertTrue(s.canManage(.whisper, action: .unload))
        XCTAssertTrue(s.canManage(.parakeet, action: .load))

        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true)
        var event = RecognizerBindingTests.event(1, desired: "whisper", effective: "whisper", parakeet: "sleeping")
        var payload = event["recognizer_status"] as! [String: Any]
        var engines = payload["engines"] as! [String: Any]
        var p = engines["parakeet"] as! [String: Any]; p["disk_bytes"] = 2_509_000_000
        engines["parakeet"] = p; payload["engines"] = engines; event["recognizer_status"] = payload
        voice.handleEvent(event); sent.removeAll()
        voice.manageRecognizer(.parakeet, action: .load)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["cmd"] as? String, "set_recognizer", "Load on the other row selects it")
        XCTAssertEqual(sent.first?["recognizer"] as? String, "parakeet")
    }

    func testSelectedRowExplainsAutoLoadInOneLine() {
        let s = state()
        XCTAssertEqual(s.autoLoadLine(for: .parakeet), "Loads automatically when selected; unloads after 10 min idle.")
        XCTAssertNil(s.autoLoadLine(for: .whisper))
        XCTAssertEqual(state(idle: 90).autoLoadLine(for: .parakeet), "Loads automatically when selected; unloads after 90 s idle.")
    }

    // MARK: S4 a download owns only its engine

    func testParakeetDownloadLeavesWhisperFullyUsable() {
        let active = RecognizerDownloadProgress(state: "downloading", received: 10, total: 100, error: nil)
        let s = state(selected: .whisper, parakeet: .unloaded, whisper: .loaded, parakeetPresent: false,
                      parakeetBytes: 0, downloads: [.parakeet: active])
        XCTAssertFalse(s.isSelectionDisabled)
        XCTAssertTrue(s.canManage(.whisper, action: .unload))
        XCTAssertFalse(s.canManage(.parakeet, action: .download))
        XCTAssertTrue(s.canManage(.parakeet, action: .cancelDownload))
    }

    func testSendingADownloadDoesNotLockThePicker() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true)
        voice.handleEvent(RecognizerBindingTests.event(1, parakeetAvailable: nil, assetsPresent: false)); sent.removeAll()
        voice.manageRecognizer(.parakeet, action: .download)
        XCTAssertEqual(sent.last?["cmd"] as? String, "download_recognizer")
        XCTAssertFalse(voice.recognizerPickerState.isSelectionDisabled)
        XCTAssertNil(voice.recognizerPickerState.disabledReason)
    }

    // MARK: S5 / S6

    func testRowSubtitleIsStatusAndSize() {
        let s = state()
        let size = ByteCountFormatter.string(fromByteCount: 2_509_000_000, countStyle: .file)
        XCTAssertEqual(RecognizerPickerView.subtitle(s, .parakeet), "Ready · \(size)")
        XCTAssertTrue(RecognizerPickerView.subtitle(s, .whisper).hasPrefix("Sleeping · "))
        let fresh = state(selected: .whisper, parakeet: .unloaded, whisper: .loaded, parakeetPresent: false, parakeetBytes: 0)
        XCTAssertEqual(RecognizerPickerView.subtitle(fresh, .parakeet), "Not set up")
        XCTAssertTrue(fresh.canSelect(.whisper) == false, "Whisper is already selected")
        XCTAssertTrue(state(selected: .parakeet).canSelect(.whisper), "Whisper stays selectable")
    }

    // MARK: Stale fallback line

    /// The fallback line follows the latest snapshot: a later Parakeet success
    /// clears it, including when the daemon restarted and its revision counter went back to zero.
    func testFallbackLineClearsAfterALaterParakeetSuccess() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true)
        voice.handleEvent(RecognizerBindingTests.event(40, desired: "parakeet", effective: "whisper",
                                                       parakeet: "sleeping", whisper: "ready", fallback: "parakeet-empty"))
        XCTAssertEqual(voice.recognizerPickerState.explanation, "Whisper transcribed your last recording instead of Parakeet.")
        voice.handleEvent(RecognizerBindingTests.event(41, desired: "parakeet", effective: "parakeet",
                                                       parakeet: "ready", whisper: "sleeping"))
        XCTAssertNil(voice.recognizerPickerState.explanation)
    }

    func testDaemonRestartUnderALiveConnectionDoesNotFreezeTheFallbackLine() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true)
        voice.handleEvent(RecognizerBindingTests.event(40, desired: "parakeet", effective: "whisper",
                                                       parakeet: "sleeping", whisper: "ready", fallback: "parakeet-empty"))
        XCTAssertNotNil(voice.recognizerPickerState.explanation)
        // A new daemon process starts counting again. Its unsolicited broadcast alone is not trusted…
        voice.handleEvent(RecognizerBindingTests.event(3, desired: "parakeet", effective: "parakeet",
                                                       parakeet: "ready", whisper: "sleeping"))
        XCTAssertEqual(voice.recognizerSnapshot?.revision, 40)
        // …but the first answer to the newest read is, and re-bases the revision.
        voice.refreshRecognizerStatus()
        var read = RecognizerBindingTests.event(4, desired: "parakeet", effective: "parakeet", parakeet: "ready", whisper: "sleeping")
        read["id"] = try XCTUnwrap(sent.last?["id"])
        voice.handleEvent(read)
        XCTAssertEqual(voice.recognizerSnapshot?.revision, 4)
        XCTAssertNil(voice.recognizerPickerState.explanation)
        // A duplicate of that answer with an even lower revision cannot re-base again.
        var duplicate = RecognizerBindingTests.event(2, desired: "parakeet", effective: "whisper", fallback: "parakeet-empty")
        duplicate["id"] = read["id"]
        voice.handleEvent(duplicate)
        XCTAssertEqual(voice.recognizerSnapshot?.revision, 4)
    }
}
