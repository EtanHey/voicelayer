import CryptoKit
import XCTest
@testable import VoiceBarUI

/// Every (control × phase) cell of the contract against formal/control-availability.
/// Step 1 pins the Swift oracle to TLC's own table; step 2 checks the contract against the oracle.
final class ControlAvailabilityModelTableTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testOracleReproducesTLCTableExactly() throws {
        let manifestURL = Self.repo.appendingPathComponent("docs/control-availability/model-table.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let table = ModelOracle.canonicalTable()
        let digest = SHA256.hash(data: Data(table.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ModelOracle.seeds.count, manifest["seeds"] as? Int)
        if digest != manifest["tableSha256"] as? String {
            let out = Self.repo.appendingPathComponent(".build.noindex/control-availability-table/swift-oracle.txt")
            try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? table.write(to: out, atomically: true, encoding: .utf8)
            XCTFail("Swift oracle drifted from TLC; diff \(out.path) with model-table.py --dump")
        }
    }

    func testContractMatchesModelInEveryCell() {
        var checked = 0, proposalCells = 0
        for f in ControlCells.coreFacts + ControlCells.presentationFacts {
            for control in ControlCells.coreControls { checked += check(control, f, &proposalCells) }
        }
        for f in ControlCells.itemFacts {
            for control in ControlCells.itemControls { checked += check(control, f, &proposalCells) }
        }
        XCTAssertGreaterThan(checked, 300_000)
        // Proposals are allowed to differ only where CONFORMANCE marks them; the count pins the surface.
        XCTAssertGreaterThan(proposalCells, 0)
        print("control-availability table: \(checked) cells checked, \(proposalCells) proposal-relaxed")
    }

    private func check(_ control: VoiceControl, _ f: ControlFacts, _ proposals: inout Int) -> Int {
        var withPending = [f]
        if let op = control.pendingOperation, [.update, .clone, .recognizerMutation].contains(op) {
            var p = f; p.pending.insert(op); withPending.append(p)
        }
        for facts in withPending {
            guard let expected = ModelExpectation(control, facts) else { continue }
            if expected.relaxed { proposals += 1 }
            let actual = VoiceControlAvailability.evaluate(control, facts, handlerInstalled: true)
            // Plain comparisons; XCTFail only on a mismatch (XCTAssert per cell is too slow in debug builds).
            var problems: [String] = []
            if actual.isVisible != expected.visible { problems.append("visible \(actual.isVisible) model \(expected.visible)") }
            if expected.visible {
                if control == .readSelectionKey { // Always delivered: it reads or explains.
                    if !actual.isEnabled { problems.append("selection key not delivered") }
                    if actual.reason != expected.reason { problems.append("reason \(actual.reason ?? "nil") model \(expected.reason ?? "nil")") }
                } else {
                    if actual.isEnabled != (expected.reason == nil) {
                        problems.append("enabled \(actual.isEnabled) model reason \(expected.reason ?? "nil")")
                    } else if !actual.isEnabled, actual.reason != expected.reason {
                        problems.append("reason \(actual.reason ?? "nil") model \(expected.reason ?? "nil")")
                    }
                    // EnabledMeansAccepted against the model's independent local + owner guards.
                    if actual.isEnabled, !expected.handlerAccepts { problems.append("EnabledMeansAccepted") }
                }
            }
            if !problems.isEmpty { XCTFail("\(control) @ \(facts): \(problems.joined(separator: "; "))") }
        }
        return withPending.count
    }
}

/// Maps contract facts to the model record and computes the model's expectation for one control.
struct ModelExpectation {
    let visible: Bool
    let reason: String?
    let handlerAccepts: Bool
    let relaxed: Bool

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    init?(_ control: VoiceControl, _ f: ControlFacts) {
        var x = ModelState()
        x.connected = f.isConnected
        x.capable = f.connection != .connected(canQueueRecording: false)
        x.gate = f.gate.admitsNewVoice ? "open" : "closed"
        switch f.capture {
        case .none: x.phase = "none"
        case .reservedOpening: x.phase = "opening"
        case .capturing: x.phase = "open"
        case .paused: x.phase = "paused"
        case .draining(let queued): x.phase = "draining"; x.queued = queued
        case .askCapturing: x.phase = "open"; x.agentAsk = true
        }
        x.older = f.processing.contains(.transcription) || f.processing.contains(.askAnswer)
        x.agentAsk = x.agentAsk || f.processing.contains(.askAnswer)
        x.historyBusy = f.processing.contains(.historyRetranscription)
        switch f.playback {
        case .none: x.playback = "none"
        case .preparing: x.playback = "preparing"
        case .playing: x.playback = "playing"
        case .paused: x.playback = "paused"
        case .readback: x.playback = "readback"
        case .askSpeaking: x.playback = "playing"; x.agentAsk = true
        }
        x.hidden = f.presentation.hidden
        x.modal = f.presentation.modal
        x.drawer = ["none", "history", "settings"][DrawerState.allCases.firstIndex(of: f.presentation.drawer)!]
        x.reported = f.voiceError ? "error" : "derived"
        x.gesture = f.physicalGesture
        x.transition = f.pending.contains(.recognizerMutation)
        if let op = control.pendingOperation, op == .update || op == .clone { x.pending = f.pending.contains(op) }

        let name: String
        var guardName: String? = nil // a control whose rules come from another model control
        switch control {
        case .record: name = "RecordF5"
        case .stopRecording: name = "Stop"
        case .cancel: name = "Cancel"
        case .pairedRelease: name = "F5Release"
        case .pausePlayback: name = "PausePlayback"
        case .resumePlayback: name = "ResumePlayback"
        case .replay: name = "Replay"
        case .seek: name = "Seek"
        case .previousRead(let available): name = "Previous"; x.previous = available
        case .nextRead(let queued): name = "NextRead"; x.next = queued
        case .readClipboard: name = "ReadClipboard"
        case .readSelectionKey: name = "ReadSelectionKey"
        case .preview(let profile): name = profile == .short ? "PreviewShort" : "PreviewLong"
        case .historyPlay(let audio): name = "HistoryPlay"; x.audio = audio
        case .retranscribe(let surface, let audio):
            name = ["drawer": "ArchiveDrawer", "window": "ArchiveWindow", "latest": "ArchiveLatest"][surface.rawValue]!
            x.audio = audio
        case .historyCopy: name = "HistoryCopy"
        case .historyNavigate: name = "HistoryNavigate"
        case .hide: name = "Hide"
        case .show: name = "Show"
        case .openHistory: name = "OpenHistory"
        case .openSettings: name = "OpenSettings"
        case .closeDrawer: name = "CloseDrawer"
        case .drawerTab(let tab): name = ModelOracle.tabs[SettingsTab.allCases.firstIndex(of: tab)!]
        case .checkUpdates: name = "CheckUpdates"
        case .microphone(let edit, let eligible):
            name = ModelOracle.microphones[MicrophoneEdit.allCases.firstIndex(of: edit)!]; x.micEligible = eligible
        case .restartListener: name = "RestartListener"
        case .update: name = "Update"
        case .quit: name = "Quit"
        case .recognizer(let action, let row):
            x.choice = ["same", "other", "retry"][RecognizerRow.Selection.allCases.firstIndex(of: row.selection)!]
            x.assets = row.assetsPresent; x.resident = row.resident; x.downloading = row.downloading
            switch action {
            case .select: name = "SelectRecognizer"
            case .loadAndSelect: name = "LoadRecognizer"; guardName = "SelectRecognizer"
            case .load: name = "LoadRecognizer"
            case .unload: name = "UnloadRecognizer"
            case .download: name = "DownloadRecognizer"
            case .cancelDownload: name = "CancelDownload"
            case .requestDelete: name = "RequestDelete"
            case .confirmDelete: name = "ConfirmDelete"
            }
        case .clone(let action, let engine):
            name = ["start": "CloneStart", "restart": "CloneRestart", "stop": "CloneStop"][action.rawValue]!
            x.clone = ["stopped", "running", "transition"][CloneEngineFacts.Lifecycle.allCases.firstIndex(of: engine.lifecycle)!]
            x.foreign = engine.foreignOwner
        default: return nil // Swift-only controls are checked by direct property tests.
        }
        let rules = guardName ?? name
        let r = Self.relax(rules, x)
        relaxed = r != x && !ModelOracle.uiReason(rules, x).isEmpty && ModelOracle.uiReason(rules, r).isEmpty

        if ModelOracle.emergencySet.contains(name) {
            // The contract keeps emergency controls visible and explains why they are disabled.
            visible = true
        } else {
            visible = ModelOracle.visible(name, x)
        }
        if name == "ReadSelectionKey" {
            reason = ModelOracle.selectionCanRead(x) ? nil
                : x.connected && x.gate == "open" && x.agentAsk ? VoiceControlAvailability.answeringQuestion
                : ModelOracle.selectionReason(x)
            handlerAccepts = true
            return
        }
        var text = ModelOracle.uiReason(rules, r)
        // Lead ruling 3: an agent Ask's refusal names the Ask.
        if ModelOracle.mediaSet.contains(name), x.agentAsk, text == "Finish capture or transcription before reading" {
            text = VoiceControlAvailability.answeringQuestion
        }
        reason = text.isEmpty ? nil : text
        handlerAccepts = ModelOracle.visible(name, x) && ModelOracle.localGuard(rules, r) && ModelOracle.daemonGuard(rules, r)
            || ModelOracle.emergencySet.contains(name) && ModelOracle.unfinished(x)
    }

    /// CONFORMANCE.md proposals the contract deliberately leaves to the lead. Each relaxation is exact.
    static func relax(_ name: String, _ x: ModelState) -> ModelState {
        var r = x
        func dropProcessing() {
            if ["none", "transcribing"].contains(r.phase) { r.phase = "none"; r.older = false; r.historyBusy = false }
        }
        switch name {
        case "ResumePlayback", "Previous", "NextRead", "Replay", "Seek": dropProcessing() // transcription block
        case "Update", "Quit": r.gate = "open" // closed-gate Update / Quit disable
        case "DownloadRecognizer", "ConfirmDelete": // download / delete provisioning lock
            r.phase = "none"; r.older = false; r.queued = false; r.historyBusy = false
        case "CloneStart": r.playback = "none"; if ModelOracle.capturing(r) { r.phase = "none" } // Start capture + speech lock
        case "CloneRestart", "CloneStop": r.playback = "none" // speech lock
        default: break
        }
        return r
    }
}

/// The finite cell sets: every phase value of every fact axis, crossed per family.
enum ControlCells {
    static let connections: [ControlConnection] = [.disconnected, .connected(canQueueRecording: true),
                                                   .connected(canQueueRecording: false)]
    static let processings: [ProcessingWork] = (0..<8).map { ProcessingWork(rawValue: $0) }
    static let shown = PresentationFacts(hidden: false, drawer: .settings, modal: false)

    static func facts(_ connection: ControlConnection = .connected(canQueueRecording: true),
                      _ gate: ControlVoiceGate = .open, _ capture: CapturePhase = .none,
                      _ processing: ProcessingWork = [], _ playback: PlaybackPhase = .none,
                      _ presentation: PresentationFacts = shown, voiceError: Bool = false,
                      gesture: Bool = false, pending: Set<PendingOperation> = []) -> ControlFacts {
        ControlFacts(connection: connection, gate: gate, capture: capture, processing: processing, playback: playback,
                     presentation: presentation, voiceError: voiceError, physicalGesture: gesture,
                     settingsService: .ready, pending: pending)
    }

    /// Every connection × gate × capture × processing × playback cell, plus the error/gesture axes over every
    /// capture × playback cell (they only feed Update, Archives and RestartListener).
    static let coreFacts: [ControlFacts] = connections.flatMap { cn in ControlVoiceGate.allCases.flatMap { g in
        CapturePhase.allCases.flatMap { c in processings.flatMap { p in PlaybackPhase.allCases.map { b in
            facts(cn, g, c, p, b)
        } } }
    } } + CapturePhase.allCases.flatMap { c in PlaybackPhase.allCases.flatMap { b in
        [(true, false), (false, true), (true, true)].flatMap { e, gesture in
            [ProcessingWork(), .transcription].map { facts(.connected(canQueueRecording: true), .open, c, $0, b,
                                                            voiceError: e, gesture: gesture) }
        }
    } }

    static let presentations: [PresentationFacts] = [false, true].flatMap { h in DrawerState.allCases.flatMap { d in
        [false, true].map { PresentationFacts(hidden: h, drawer: d, modal: $0) } } }

    static let presentationFacts: [ControlFacts] = presentations.flatMap { pr in CapturePhase.allCases.flatMap { c in
        [ProcessingWork(), .transcription, .askAnswer].flatMap { p in PlaybackPhase.allCases.map { b in
            facts(.connected(canQueueRecording: true), .open, c, p, b, pr)
        } }
    } }

    static let itemFacts: [ControlFacts] = connections.flatMap { cn in [ControlVoiceGate.open, .committed].flatMap { g in
        CapturePhase.allCases.flatMap { c in [ProcessingWork(), .transcription, .historyRetranscription].flatMap { p in
            [PlaybackPhase.none, .playing, .readback].flatMap { b in
                [Set<PendingOperation>(), [.recognizerMutation]].map { facts(cn, g, c, p, b, pending: $0) }
            }
        } }
    } }

    static let coreControls: [VoiceControl] = {
        var out: [VoiceControl] = [.record, .stopRecording, .cancel, .pairedRelease, .pausePlayback, .resumePlayback,
            .replay, .seek, .readClipboard, .readSelectionKey, .preview(.short), .preview(.long), .historyCopy,
            .historyNavigate, .hide, .show, .openHistory, .openSettings, .closeDrawer, .checkUpdates,
            .restartListener, .update, .quit]
        for b in [false, true] {
            out += [.previousRead(available: b), .nextRead(queued: b), .historyPlay(audio: b)]
            out += ArchiveSurface.allCases.map { .retranscribe($0, audio: b) }
            out += MicrophoneEdit.allCases.map { .microphone($0, eligible: b) }
        }
        out += SettingsTab.allCases.map { .drawerTab($0) }
        return out
    }()

    static let rows: [RecognizerRow] = RecognizerRow.Selection.allCases.flatMap { s in [false, true].flatMap { a in
        [false, true].flatMap { r in [false, true].map {
            RecognizerRow(selection: s, assetsPresent: a, resident: r, downloading: $0) } } } }

    static let itemControls: [VoiceControl] =
        RecognizerAction.allCases.flatMap { action in rows.map { .recognizer(action, $0) } } +
        CloneAction.allCases.flatMap { action in CloneEngineFacts.Lifecycle.allCases.flatMap { l in
            [false, true].map { .clone(action, CloneEngineFacts(lifecycle: l, foreignOwner: $0)) } } }

    /// Controls the model does not name; checked by the direct property tests.
    static let contractOnlyControls: [VoiceControl] = {
        var out: [VoiceControl] = [.recordingHold, .recordingPause, .stopSpeaking, .speedChip, .historyPaste,
            .historyReveal, .copyLastTranscript, .pasteLastTranscript, .dismissTeleprompter, .showTeleprompter,
            .dismissError, .chooseMicrophone, .checkShortcut, .permissionFix, .dictionaryEdit(readOnly: false),
            .dictionaryEdit(readOnly: true), .dictionaryCommit]
        out += SettingsTab.allCases.map { .windowTab($0) }
        out += ProcessingKey.allCases.flatMap { [.processingToggle($0, lockedBy: nil),
                                                 .processingToggle($0, lockedBy: $0.environmentVariable)] }
        out += SpeechSettingKey.allCases.map { .speechSetting($0) }
        return out
    }()

    static let allControls = coreControls + itemControls + contractOnlyControls
}
