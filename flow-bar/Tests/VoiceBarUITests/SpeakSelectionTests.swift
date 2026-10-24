@testable import VoiceBarUI
import XCTest

final class SpeakSelectionTests: XCTestCase {
    @MainActor
    func testReadClipboardIsExplicitAndDispatchesExactPlainTextOnce() throws {
        let state = VoiceState()
        state.isConnected = true
        var reads = 0
        var commands: [[String: Any]] = []
        let text = "  שלום 👩🏽‍💻 e\u{301}\r\n\tend…\n"
        state.sendCommand = { commands.append($0) }
        state.clipboardTextReadHandler = { current, done in
            XCTAssertTrue(current()); reads += 1; done(.completed(text)); done(.completed("duplicate"))
        }
        state.selectionTextCaptureHandler = { $0(.completed(nil)) }
        let settings = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] },
            selectedDeviceID: { nil }, modelsStatus: { .disconnected }, onRefreshModelsStatus: {},
            onReadClipboard: { state.readClipboard() }, vocabularyRevision: { 0 })
        _ = settings.body
        state.speakSelection()
        XCTAssertEqual(reads, 0, "Settings construction/body and empty selection never read clipboard")
        XCTAssertTrue(commands.isEmpty)
        try XCTUnwrap(settings.onReadClipboard)()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual((commands.first?["text"] as? String).map { Array($0.utf8) }, Array(text.utf8))
        XCTAssertEqual(commands.first?["format"] as? String, "plain")
        XCTAssertEqual(commands.first?["source"] as? String, "clipboard")
        XCTAssertEqual(commands.first?["queue"] as? Bool, true)
        XCTAssertNotNil(commands.first?["id"] as? String)
    }

    func testOrdinarySelectionNeverFallsBackToExplicitClipboard() {
        let state = VoiceState()
        state.clipboardTextReadHandler = { _, _ in XCTFail("selection cannot read arbitrary clipboard") }
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        for result in [SelectionCaptureResult.completed(nil), .captureFailed, .clipboardChanged, .secureField] {
            state.selectionTextCaptureHandler = { $0(result) }
            state.speakSelection()
            XCTAssertTrue(commands.isEmpty)
        }
        state.selectionTextCaptureHandler = { $0(.completed("native selection")) }
        state.speakSelection()
        XCTAssertEqual(commands.last?["source"] as? String, "selection")
        XCTAssertEqual(commands.last?["format"] as? String, "markdown")
        XCTAssertNil(commands.last?["queue"])
    }

    func testReadClipboardBusyAndDisconnectedNeverRead() {
        for (mode, phase, connected) in [(VoiceMode.recording, HotkeyPhase.idle, true),
            (.transcribing, .idle, true), (.idle, .pressing, true), (.idle, .holding, true),
            (.idle, .awaitingSecondTap, true), (.disconnected, .idle, true), (.idle, .idle, false)] {
            let state = VoiceState()
            state.mode = mode; state.hotkeyPhase = phase; state.isConnected = connected
            state.sendCommand = { _ in XCTFail("no dispatch") }
            state.clipboardTextReadHandler = { _, _ in XCTFail("no clipboard access") }
            state.readClipboard()
        }
        let noTransport = VoiceState()
        noTransport.isConnected = true
        noTransport.clipboardTextReadHandler = { _, _ in XCTFail("no transport must not read") }
        noTransport.readClipboard()
    }

    func testReadClipboardFailuresDoNotStopOrQueueExistingPlayback() {
        for result in [SelectionCaptureResult.completed(nil), .completed(""), .secureField, .clipboardChanged, .captureFailed] {
            let state = speakingState()
            state.sendCommand = { _ in XCTFail("failed clipboard read must send no request, including Stop") }
            state.clipboardTextReadHandler = { _, done in done(result) }
            state.readClipboard()
            XCTAssertNotNil(state.confirmationText)
            XCTAssertEqual(state.mode, .speaking)
        }
    }

    func testReadClipboardCancellationAndNewSessionRejectLateAndDuplicateResults() throws {
        for interrupt in ["stop", "cancel", "f5", "recording", "disconnect"] {
            let state = VoiceState()
            state.isConnected = true
            var current: (() -> Bool)?, done: ((SelectionCaptureResult) -> Void)?
            var commands: [String] = []
            state.sendCommand = { commands.append($0["cmd"] as! String) }
            state.clipboardTextReadHandler = { current = $0; done = $1 }
            state.readClipboard()
            XCTAssertTrue(try XCTUnwrap(current)())
            switch interrupt {
            case "stop": state.stop()
            case "cancel": state.cancel()
            case "f5": state.hotkeyPhase = .pressing; state.hotkeyPhase = .idle
            case "recording": state.mode = .recording; state.mode = .idle
            default: state.setConnectionStatus(false); state.setConnectionStatus(true)
            }
            XCTAssertFalse(try XCTUnwrap(current)(), interrupt)
            let stale = try XCTUnwrap(done)
            stale(.completed("stale"))
            XCTAssertFalse(commands.contains("speak_text"), interrupt)
            state.mode = .idle
            state.clipboardTextReadHandler = { _, callback in done = callback }
            state.readClipboard()
            stale(.completed("duplicate stale result"))
            done?(.completed("fresh"))
            XCTAssertEqual(commands.filter { $0 == "speak_text" }.count, 1, interrupt)
        }
    }

    func testReadClipboardKeepsWhitespaceAndSelectionQueueNextStopContract() throws {
        let state = VoiceState()
        state.isConnected = true
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { _ in XCTFail("explicit action must never capture selection") }
        state.clipboardTextReadHandler = { _, done in done(.completed(" \n\t")) }
        state.readClipboard()
        XCTAssertEqual(commands.first?["text"] as? String, " \n\t")
        let first = try XCTUnwrap(commands.first?["id"] as? String)
        state.handleEvent(["type": "state", "state": "speaking", "request_id": first, "text": " \n\t",
            "long_read": ["id": "clipboard-read", "preparing": false]])
        state.clipboardTextReadHandler = { _, done in done(.completed("different")) }
        state.readClipboard()
        XCTAssertEqual(commands.last?["queue"] as? Bool, true)
        state.handleEvent(["type": "read_queue", "count": 1, "current_request_id": first])
        state.skipToNextRead()
        XCTAssertEqual(commands.last?["cmd"] as? String, "read_next")
        state.stop()
        XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
        XCTAssertEqual(state.readQueueCount, 0)
        XCTAssertNil(commands.last?["retain_read_queue"])
        state.readClipboard()
        state.readClipboard()
        XCTAssertEqual(commands.suffix(2).compactMap { $0["cmd"] as? String }, ["speak_text", "stop"])
    }

    func testBusyRequestEndsWithItsSessionAndCannotReappearInANewSession() {
        for (mode, phase) in [(VoiceMode.recording, HotkeyPhase.idle), (.transcribing, .idle),
                              (.idle, .pressing), (.idle, .holding), (.idle, .awaitingSecondTap)] {
            for endMode in [VoiceMode.idle, .speaking, .disconnected, .error] {
                let state = VoiceState()
                state.mode = mode
                state.hotkeyPhase = phase
                state.transcript = "Keep every synthetic word שלום 👩‍💻"
                state.sendCommand = { _ in XCTFail("UI cleanup must send no command") }
                state.selectionTextCaptureHandler = { _ in XCTFail("UI cleanup must not capture") }
                state.speakSelection()
                XCTAssertTrue(state.showsSelectionBusyNote)
                state.hotkeyPhase = .idle
                state.mode = endMode
                XCTAssertFalse(state.showsSelectionBusyNote, "Session ended: \(mode)/\(phase) → \(endMode)")
                state.mode = .idle
                state.hotkeyPhase = .pressing
                XCTAssertNil(VoiceBarPresentation.selectionBusyNote(isRequested: state.showsSelectionBusyNote,
                    mode: state.mode, hotkeyPhase: state.hotkeyPhase), "No new Option+F5 request")
                state.hotkeyPhase = .idle
                state.mode = .recording
                XCTAssertFalse(state.showsSelectionBusyNote, "A new recording must not inherit the request")
                XCTAssertEqual(state.transcript, "Keep every synthetic word שלום 👩‍💻")
            }
        }
    }

    @MainActor
    func testAnEndedSessionTimerCannotClearANewBusyRequest() async throws {
        let state = VoiceState()
        state.mode = .recording
        state.sendCommand = { _ in XCTFail("UI timers must send no command") }
        state.selectionTextCaptureHandler = { _ in XCTFail("UI timers must not capture") }
        state.speakSelection()
        try await Task.sleep(for: .milliseconds(1100))
        state.mode = .idle
        XCTAssertFalse(state.showsSelectionBusyNote)
        state.mode = .recording
        state.speakSelection()
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertTrue(state.showsSelectionBusyNote, "Old timer must not clear the new request")
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(state.showsSelectionBusyNote)
        XCTAssertEqual(state.mode, .recording)
    }

    func testCaptureFailuresHaveSpecificFeedbackAndNeverSpeak() {
        let state = VoiceState()
        state.sendCommand = { _ in XCTFail("capture failure must not speak") }
        for (result, message) in [(SelectionCaptureResult.secureField, "Can't read a secure field"),
                                  (.captureFailed, "Couldn't read the selection, try again"),
                                  (.clipboardRestoreFailed, "Couldn't restore the clipboard"),
                                  (.copyTimedOut, "Timed out\nReselect"),
                                  (.copyEmpty, "No text\nReselect"),
                                  (.copyFailed, "Can't copy\nCheck A11y"),
                                  (.clipboardChanged, "Clipboard\nReselect")] {
            state.selectionTextCaptureHandler = { $0(result) }
            state.speakSelection()
            XCTAssertEqual(state.confirmationText, message)
        }
    }

    func testDiagnosticsContainOnlyMetadataAndForwardTheFullSelectionOnce() {
        let state = VoiceState()
        let text = "PRIVATE_SELECTION שלום👩🏽‍💻\n\n  tail…  "
        var events: [(String, [String: String])] = []
        var commands: [[String: Any]] = []
        state.diagnosticLogger = { events.append(($0, $1)) }
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed(text).observed(axRead: .empty, path: .copy)) }
        state.speakSelection()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["text"] as? String, text)
        XCTAssertEqual(commands.first?["source"] as? String, "selection")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, "selection_capture")
        let details = events.first?.1 ?? [:]
        XCTAssertEqual(Set(details.keys), Set(["outcome", "ax_read", "path", "host_structure", "appKeyWindowTitle",
            "utf16_count", "line_breaks", "tabs", "object_replacements", "list_marker_lines", "pipe_lines",
            "copy_attempted", "copy_resolution"]))
        XCTAssertEqual(details["appKeyWindowTitle"], "not_recorded")
        XCTAssertFalse(details.values.contains { $0.contains("PRIVATE_SELECTION") || $0.contains("שלום") })
    }

    func testSecondPressCancelsPendingCaptureAndAFreshPressCanCaptureAgain() {
        let state = VoiceState()
        var completion: ((SelectionCaptureResult) -> Void)?
        var captures = 0
        var commands = 0
        state.sendCommand = { _ in commands += 1 }
        state.selectionTextCaptureHandler = { captures += 1; completion = $0 }
        state.speakSelection()
        state.speakSelection()
        XCTAssertEqual(captures, 1)
        completion?(.completed("text from cancelled capture"))
        XCTAssertEqual(commands, 0)
        XCTAssertNil(state.confirmationText)
        state.speakSelection()
        XCTAssertEqual(captures, 2)
        completion?(.completed("fresh selection"))
        XCTAssertEqual(commands, 1)
    }

    private func speakingState(_ text: String = "old selection", preparing: Bool = false) -> VoiceState {
        let state = VoiceState()
        state.isConnected = true
        state.handleEvent(["type": "state", "state": "speaking", "text": preparing ? "Preparing speech…" : text,
                           "long_read": ["id": "old-read", "preparing": preparing]])
        return state
    }

    func testPlaybackCompletionDoesNotDropInFlightSelectionCapture() throws {
        let state = speakingState()
        var completion: ((SelectionCaptureResult) -> Void)?
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        let epoch = try XCTUnwrap(identityField("selectionSpeechEpoch", in: state) as? Int)

        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(identityField("selectionSpeechEpoch", in: state) as? Int, epoch)
        try XCTUnwrap(completion)(.completed("new"))

        XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text"])
        XCTAssertEqual(commands.first?["text"] as? String, "new")
    }

    func testPreparingReplacementSurvivesInterleavedPlaybackIdle() throws {
        for ownA in [false, true] {
            let state = VoiceState()
            state.isConnected = true
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            var a = "external-A"
            if ownA {
                state.selectionTextCaptureHandler = { $0(.completed("A")) }
                state.speakSelection()
                a = try XCTUnwrap(commands.last?["id"] as? String)
            }
            state.handleEvent(["type": "state", "state": "speaking", "request_id": a,
                "text": "Preparing speech…", "long_read": ["id": "read-A", "preparing": true]])
            state.selectionTextCaptureHandler = { $0(.completed("B")) }
            state.speakSelection()
            let b = try XCTUnwrap(commands.last?["id"] as? String)

            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            XCTAssertTrue(try submissionIDs(state).contains(b))
            state.handleEvent(["type": "state", "state": "speaking", "request_id": b,
                "text": "Preparing speech…", "long_read": ["id": "read-B", "preparing": true]])
            XCTAssertEqual(state.mode, .speaking, "ownA=\(ownA)")
            XCTAssertEqual(identityField("selectionReadRequestID", in: state) as? String, b)
            XCTAssertEqual(identityField("selectionReadText", in: state) as? String, "B")
            let retired = try XCTUnwrap(identityField("selectionRetiredRequestIDs", in: state) as? [String])
            XCTAssertFalse(retired.contains(b))
            state.handleEvent(["type": "state", "state": "speaking", "request_id": b,
                "text": "B", "long_read": ["id": "read-B", "preparing": false]])
            XCTAssertEqual(state.mode, .speaking)
            XCTAssertEqual(state.statusText, "B")
        }
    }

    func testSameSelectionStopDoesNotRestartAfterPlaybackIdleDuringCapture() throws {
        // SHA-256 of normalized "hello world", shared with the external receipt test.
        let hash = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        for own in [false, true] {
            for explicitStop in [false, true] {
                let state = VoiceState()
                state.isConnected = true
                var commands: [[String: Any]] = []
                state.sendCommand = { commands.append($0) }
                var id = "external-A"
                if own {
                    state.selectionTextCaptureHandler = { $0(.completed("hello world")) }
                    state.speakSelection()
                    id = try XCTUnwrap(commands.last?["id"] as? String)
                }
                for preparing in [true, false] {
                    var event: [String: Any] = ["type": "state", "state": "speaking", "request_id": id,
                        "text": preparing ? "Preparing speech…" : "projected display",
                        "long_read": ["id": "read-A", "preparing": preparing]]
                    if !own { event["text_hash"] = hash }
                    state.handleEvent(event)
                }
                commands.removeAll()
                var completion: ((SelectionCaptureResult) -> Void)?
                state.selectionTextCaptureHandler = { completion = $0 }
                state.speakSelection()
                if explicitStop { state.stop() }
                state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
                try XCTUnwrap(completion)(.completed(" hello\nworld "))
                XCTAssertFalse(commands.contains { $0["cmd"] as? String == "speak_text" },
                    "own=\(own), explicitStop=\(explicitStop)")
                XCTAssertEqual(state.mode, .idle)
                state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
                XCTAssertFalse(commands.contains { $0["cmd"] as? String == "speak_text" })
            }
        }
    }

    func testSpeechReceiptsDoNotAdvanceUserStopEpoch() throws {
        for rejected in [false, true] {
            let state = VoiceState()
            var request: [String: Any] = [:]
            state.sendCommand = { request = $0 }
            state.selectionTextCaptureHandler = { $0(.completed("B")) }
            state.speakSelection()
            let b = try XCTUnwrap(request["id"] as? String)
            state.handleEvent(["type": "state", "state": "speaking", "request_id": b,
                "text": "B", "long_read": ["id": "read-B", "preparing": false]])
            let epoch = try XCTUnwrap(identityField("selectionSpeechEpoch", in: state) as? Int)
            if rejected {
                state.handleEvent(["type": "ack", "command": "speak_text", "id": b,
                    "outcome": "reject", "reason": "busy"])
            } else {
                state.handleEvent(["type": "state", "state": "speaking", "request_id": "external",
                    "text": "X", "long_read": ["id": "read-X", "preparing": false]])
            }
            XCTAssertEqual(identityField("selectionSpeechEpoch", in: state) as? Int, epoch)
        }
    }

    func testIdentifiedReceiptsBindBAndCInEitherOrderAndThirdPressStopsC() throws {
        for order in [[0, 1], [1, 0]] {
            let state = speakingState("A")
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            for text in ["B", "C"] {
                state.selectionTextCaptureHandler = { $0(.completed(text)) }
                state.speakSelection()
            }
            let submissions = commands
            for index in order {
                state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                    "request_id": try XCTUnwrap(submissions[index]["id"] as? String),
                    "long_read": ["id": "read-\(index)", "preparing": true]])
            }
            state.selectionTextCaptureHandler = { $0(.completed("C")) }
            state.speakSelection()
            XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text", "speak_text", "stop"])
        }
    }

    func testUnrelatedIdentifiedPreparingReceiptInvalidatesPendingCapture() {
        let state = speakingState("A")
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("B")) }
        state.speakSelection()
        var completion: ((SelectionCaptureResult) -> Void)?
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
            "request_id": "unrelated", "long_read": ["id": "external", "preparing": true]])
        completion?(.completed("C"))
        XCTAssertEqual(commands.count, 1)
    }

    func testThirdCaptureSurvivesIdentifiedReceiptsAndAcceptAcksInEitherOrder() throws {
        for order in [[0, 1], [1, 0]] {
            let state = speakingState("A")
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            for text in ["B", "C"] {
                state.selectionTextCaptureHandler = { $0(.completed(text)) }
                state.speakSelection()
            }
            let submissions = commands
            var completion: ((SelectionCaptureResult) -> Void)?
            state.selectionTextCaptureHandler = { completion = $0 }
            state.speakSelection()
            for index in order {
                let id = try XCTUnwrap(submissions[index]["id"] as? String)
                state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "accept", "id": id])
                state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                    "request_id": id, "long_read": ["id": "read-\(index)", "preparing": true]])
            }
            completion?(.completed("D"))
            XCTAssertEqual(commands.compactMap { $0["text"] as? String }, ["B", "C", "D"])
        }
    }

    func testLegacyReceiptWithoutIdentityStillAcknowledgesOwnInput() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("legacy input")) }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
            "long_read": ["id": "legacy-read", "preparing": true]])
        state.speakSelection()
        XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text", "stop"])
    }

    func testExternalHashComparesRawSelectionDuringPreparationAndPlayback() {
        // SHA-256 of normalized "hello world" (shared TS/Swift wire vector).
        let hash = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        for preparing in [true, false] {
            for (selection, expected) in [(" hello\nworld ", "stop"), ("different", "speak_text"), ("", "stop")] {
                let state = VoiceState()
                state.handleEvent(["type": "state", "state": "speaking", "text": "projected text",
                    "request_id": "external", "text_hash": hash,
                    "long_read": ["id": "external-read", "preparing": preparing]])
                var commands: [[String: Any]] = []
                state.sendCommand = { commands.append($0) }
                state.selectionTextCaptureHandler = { $0(.completed(selection)) }
                state.speakSelection()
                XCTAssertEqual(commands.first?["cmd"] as? String, expected)
                if expected == "speak_text" { XCTAssertEqual((commands.first?["text_hash"] as? String)?.count, 64) }
            }
        }
    }

    func testPendingSubmissionSurvivesUnrelatedIdentifiedRead() throws {
        for preparing in [true, false] {
            let state = speakingState("playing A")
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            let raw = "# Own B\n\n- original selection שלום"
            state.selectionTextCaptureHandler = { $0(.completed(raw)) }
            state.speakSelection()
            let id = try XCTUnwrap(commands.first?["id"] as? String)
            state.handleEvent(["type": "state", "state": "speaking", "request_id": "external-X",
                "text": "Preparing external X…", "long_read": ["id": "read-X", "preparing": true]])
            state.handleEvent(["type": "state", "state": "speaking", "request_id": id,
                "text": preparing ? "Preparing speech…" : "Own B original selection שלום",
                "long_read": ["id": "read-B", "preparing": preparing]])
            XCTAssertEqual(state.statusText, preparing ? "Preparing speech…" : "Own B original selection שלום")
            // Compare against B's original input even when the displayed speech is projected.
            state.speakSelection()
            XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text", "stop"])
        }
    }

    func testNewerOwnReceiptStillSupersedesPendingRequestAfterExternalRead() throws {
        let state = speakingState("A")
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        for text in ["B", "C"] {
            state.selectionTextCaptureHandler = { $0(.completed(text)) }
            state.speakSelection()
        }
        state.handleEvent(["type": "state", "state": "speaking", "request_id": "external-X",
            "text": "X", "long_read": ["id": "read-X", "preparing": true]])
        for index in [1, 0] {
            state.handleEvent(["type": "state", "state": "speaking",
                "request_id": try XCTUnwrap(commands[index]["id"] as? String),
                "text": index == 1 ? "C" : "stale B",
                "long_read": ["id": "read-\(index)", "preparing": false]])
        }
        XCTAssertEqual(state.statusText, "C")
        state.selectionTextCaptureHandler = { $0(.completed("C")) }
        state.speakSelection()
        XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
    }

    func testCapacityEvictionAllowsLateReceiptAsExternalHashRead() throws {
        for next in [" selection 0\n", "different selection"] {
            let state = VoiceState()
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            for index in 0..<33 {
                state.selectionTextCaptureHandler = { $0(.completed("selection \(index)")) }
                state.speakSelection()
            }
            XCTAssertEqual(try submissionCount(state), 32)
            let first = try XCTUnwrap(commands.first)
            let id = try XCTUnwrap(first["id"] as? String)
            state.handleEvent(["type": "state", "state": "speaking", "request_id": id,
                "text_hash": try XCTUnwrap(first["text_hash"] as? String),
                "text": "Preparing evicted read…", "long_read": ["id": "read-0", "preparing": true]])
            XCTAssertEqual(state.mode, .speaking)
            XCTAssertEqual(state.statusText, "Preparing evicted read…")
            state.selectionTextCaptureHandler = { $0(.completed(next)) }
            state.speakSelection()
            XCTAssertEqual(commands.last?["cmd"] as? String, next == "different selection" ? "speak_text" : "stop")
        }
    }

    func testRejectionAfterExternalReadRetiresOnlyRejectedSubmission() throws {
        let state = VoiceState()
        var requests: [[String: Any]] = []
        state.sendCommand = { requests.append($0) }
        for text in ["B", "C"] {
            state.selectionTextCaptureHandler = { $0(.completed(text)) }
            state.speakSelection()
        }
        let b = try XCTUnwrap(requests[0]["id"] as? String)
        let c = try XCTUnwrap(requests[1]["id"] as? String)
        state.handleEvent(["type": "state", "state": "speaking", "request_id": "external-X",
            "text": "External X", "long_read": ["id": "read-X", "preparing": true]])
        state.handleEvent(["type": "ack", "command": "speak_text", "id": b,
                           "outcome": "reject", "reason": "busy"])
        XCTAssertEqual(state.selectionFeedbackNote, "Busy. Selection not read")
        XCTAssertEqual(try submissionCount(state), 1)
        state.handleEvent(["type": "state", "state": "speaking", "request_id": b,
            "text": "Rejected B", "long_read": ["id": "read-B", "preparing": false]])
        XCTAssertEqual(state.statusText, "External X")
        state.handleEvent(["type": "state", "state": "speaking", "request_id": c,
            "text": "C", "long_read": ["id": "read-C", "preparing": false]])
        XCTAssertEqual(state.statusText, "C")
    }

    func testExternalReadCompletionLeavesPendingSubmissionBindable() throws {
        for ending in [VoiceMode.idle, .error, .recording, .transcribing] {
            let state = VoiceState()
            var request: [String: Any] = [:]
            state.sendCommand = { request = $0 }
            state.selectionTextCaptureHandler = { $0(.completed("B")) }
            state.speakSelection()
            let id = try XCTUnwrap(request["id"] as? String)
            state.handleEvent(["type": "state", "state": "speaking", "request_id": "external-X",
                "text": "External X", "long_read": ["id": "read-X", "preparing": true]])
            if ending == .idle {
                state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            } else { state.mode = ending }
            XCTAssertEqual(try submissionCount(state), 1, "external ending \(ending)")
            state.handleEvent(["type": "state", "state": "speaking", "request_id": id,
                "text": "B", "long_read": ["id": "read-B", "preparing": false]])
            XCTAssertEqual(state.mode, .speaking)
            XCTAssertEqual(state.statusText, "B")
        }
    }

    func testRandomInterleavingsPreservePendingRequestsAcrossExternalLifecycles() throws {
        // Reproducible property traces; the model tracks only unacknowledged own requests.
        for seed in 1...16 {
            var rng = UInt64(seed)
            func draw(_ limit: Int) -> Int {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                return Int((rng >> 32) % UInt64(limit))
            }
            let state = VoiceState()
            state.isConnected = true
            var request: [String: Any] = [:]
            state.sendCommand = { request = $0 }
            var pending: [(id: String, order: Int)] = []
            var hasAcknowledgedCurrentRead = false
            for step in 0..<160 {
                let event = step < 40 ? 0 : draw(7)
                let context = "seed=\(seed) step=\(step) event=\(event)"
                switch event {
                case 0:
                    state.selectionTextCaptureHandler = { $0(.completed("own \(seed)-\(step)")) }
                    state.speakSelection()
                    let id = try XCTUnwrap(request["id"] as? String, context)
                    pending.append((id, step))
                    if pending.count + (hasAcknowledgedCurrentRead ? 1 : 0) > 32 { pending.removeFirst() }
                case 1, 2:
                    hasAcknowledgedCurrentRead = false
                    state.handleEvent(["type": "state", "state": "speaking",
                        "request_id": "external-\(seed)-\(step)", "text": "External X",
                        "long_read": ["id": "external-read-\(step)", "preparing": event == 1]])
                    // Exercise X's completion as well as a live external receipt.
                    if event == 2 {
                        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
                    }
                case 3:
                    if !pending.isEmpty {
                        let item = pending[draw(pending.count)]
                        state.handleEvent(["type": "state", "state": "speaking", "request_id": item.id,
                            "text": "Acknowledged own", "long_read": ["id": "own-\(step)", "preparing": true]])
                        pending.removeAll { $0.order <= item.order }
                        hasAcknowledgedCurrentRead = true
                    }
                case 4:
                    if !pending.isEmpty {
                        let item = pending.remove(at: draw(pending.count))
                        state.handleEvent(["type": "ack", "command": "speak_text", "id": item.id,
                                           "outcome": "reject", "reason": "busy"])
                        let ids = try submissionIDs(state)
                        XCTAssertFalse(ids.contains(item.id), context)
                    }
                case 5:
                    hasAcknowledgedCurrentRead = false
                    // Completion belongs only to the current read, never another pending request.
                    state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
                default:
                    if draw(2) == 0 { state.stop() } else { state.cancel() }
                    pending.removeAll()
                    hasAcknowledgedCurrentRead = false
                }
                let stored = try submissionIDs(state)
                XCTAssertTrue(Set(pending.map(\.id)).isSubset(of: stored), context)
                XCTAssertLessThanOrEqual(stored.count, 32, context)
                let retired = try XCTUnwrap(identityField("selectionRetiredRequestIDs", in: state) as? [String])
                XCTAssertTrue(Set(pending.map(\.id)).isDisjoint(with: retired), context)
                XCTAssertLessThanOrEqual(retired.count, 32, context)
                XCTAssertEqual(Set(retired).count, retired.count, context)
            }
        }
    }

    private func submissionIDs(_ state: VoiceState) throws -> Set<String> {
        let entries = try XCTUnwrap(identityField("selectionSubmissions", in: state))
        return Set(Mirror(reflecting: entries).children.compactMap {
            Mirror(reflecting: $0.value).children.first?.value as? String
        })
    }

    private func identityField(_ name: String, in state: VoiceState) -> Any? {
        Mirror(reflecting: state).children.first { $0.label == name || $0.label == "_" + name }?.value
    }

    private func submissionCount(_ state: VoiceState) throws -> Int {
        let entries = try XCTUnwrap(identityField("selectionSubmissions", in: state))
        return Mirror(reflecting: entries).children.count
    }

    func testRetiredIdentityCannotRebindAfterStopCancelOrCompletion() throws {
        for received in [false, true] {
            for end in ["stop", "cancel", "completion", "selection-stop", "error", "disconnect", "recording"] {
                let state = VoiceState()
                state.isConnected = true
                var commands: [[String: Any]] = []
                state.sendCommand = { commands.append($0) }
                state.selectionTextCaptureHandler = { $0(.completed("retire this selection")) }
                state.speakSelection()
                let id = try XCTUnwrap(commands.first?["id"] as? String)
                let receipt: [String: Any] = ["type": "state", "state": "speaking", "request_id": id,
                    "text_hash": commands.first?["text_hash"] as? String ?? "", "text": "Preparing speech…",
                    "long_read": ["id": "retired-read", "preparing": true]]
                if received { state.handleEvent(receipt) }
                switch end {
                case "stop": state.stop()
                case "cancel": state.cancel()
                case "completion": state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
                case "selection-stop": state.speakSelection()
                case "error": state.mode = .error
                case "disconnect": state.mode = .disconnected
                default: state.mode = .recording
                }
                let mode = state.mode
                let text = state.statusText
                let pendingSurvives = !received && ["completion", "error", "recording"].contains(end)
                XCTAssertEqual(try submissionCount(state), pendingSurvives ? 1 : 0, "\(end), received=\(received)")
                for field in ["selectionReadText", "selectionReadHash", "selectionReadRequestID", "selectionReadID"] {
                    if let value = identityField(field, in: state) {
                        XCTAssertEqual(Mirror(reflecting: value).children.count, 0, "\(end): \(field)")
                    }
                }
                if pendingSurvives {
                    state.handleEvent(receipt)
                    XCTAssertEqual(state.mode, .speaking, "Pending request after \(end)")
                    continue
                }
                state.handleEvent(receipt)
                XCTAssertEqual(state.mode, mode, "Late receipt after \(end)")
                XCTAssertEqual(state.statusText, text, "Late receipt after \(end)")
                XCTAssertEqual(try submissionCount(state), 0)
            }
        }
    }

    func testThirdPressAfterStopStartsFreshSelectionInsteadOfZombieToggle() throws {
        let state = VoiceState()
        state.isConnected = true
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("same selection")) }
        state.speakSelection()
        let id = try XCTUnwrap(commands.first?["id"] as? String)
        state.stop()
        state.handleEvent(["type": "state", "state": "speaking", "request_id": id,
            "text": "Preparing speech…", "long_read": ["id": "stopped-read", "preparing": true]])
        state.speakSelection()
        XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text", "stop", "speak_text"])
    }

    func testUnacknowledgedBurstIsBoundedAndNewReceiptReleasesSupersededText() throws {
        let state = VoiceState()
        var request: [String: Any] = [:]
        state.sendCommand = { request = $0 }
        for index in 0..<80 {
            state.selectionTextCaptureHandler = { $0(.completed("pending selection \(index)")) }
            state.speakSelection()
            XCTAssertLessThanOrEqual(try submissionCount(state), 32)
        }
        let id = try XCTUnwrap(request["id"] as? String)
        state.handleEvent(["type": "state", "state": "speaking", "request_id": id,
            "text": "Preparing speech…", "long_read": ["id": "newest-read", "preparing": true]])
        XCTAssertEqual(try submissionCount(state), 1)
        state.stop()
        XCTAssertEqual(try submissionCount(state), 0)
        let retired = try XCTUnwrap(identityField("selectionRetiredRequestIDs", in: state) as? [String])
        XCTAssertLessThanOrEqual(retired.count, 32)
    }

    func testRepeatedCompletedReadsReleaseTextAndBoundRetiredIDs() throws {
        let state = VoiceState()
        var request: [String: Any] = [:]
        state.sendCommand = { request = $0 }
        var lastID = ""
        for index in 0..<80 {
            state.selectionTextCaptureHandler = { $0(.completed("completed selection \(index)")) }
            state.speakSelection()
            lastID = try XCTUnwrap(request["id"] as? String)
            state.handleEvent(["type": "state", "state": "speaking", "request_id": lastID,
                "text": "Preparing speech…", "long_read": ["id": "read-\(index)", "preparing": true]])
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            XCTAssertEqual(try submissionCount(state), 0)
        }
        let retired = try XCTUnwrap(identityField("selectionRetiredRequestIDs", in: state) as? [String])
        XCTAssertEqual(retired.count, 32)
        XCTAssertEqual(Set(retired).count, 32)
        XCTAssertEqual(retired.last, lastID)
        state.handleEvent(["type": "state", "state": "speaking", "request_id": lastID,
            "text": "Preparing speech…", "long_read": ["id": "late-completion", "preparing": true]])
        XCTAssertEqual(state.mode, .idle)
    }

    func testDifferentSelectionReplacesSpeakingAndPreparingWithoutGlobalStop() {
        for preparing in [false, true] {
            let state = speakingState(preparing: preparing)
            let text = "NEW private selection שלום 👩‍💻\n\n  tail…  "
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.selectionTextCaptureHandler = { $0(.completed(text)) }
            state.speakSelection()
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.first?["cmd"] as? String, "speak_text")
            XCTAssertEqual(commands.first?["text"] as? String, text)
            XCTAssertEqual(commands.first?["source"] as? String, "selection")
        }
    }

    func testExternalPreparingTreatsEveryNonemptySelectionAsDifferentIncludingThePlaceholder() {
        for text in ["read this instead", "Preparing speech…"] {
            let state = speakingState(preparing: true)
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.selectionTextCaptureHandler = { $0(.completed(text)) }
            state.speakSelection()
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.first?["cmd"] as? String, "speak_text")
            XCTAssertEqual(commands.first?["text"] as? String, text)
        }
    }

    func testExternalPreparingWithoutHashReplacesAfterIdentityCleanup() {
        for text in ["different selection", "Preparing speech…"] {
            for requestID in [nil, "external-request"] as [String?] {
                let state = VoiceState()
                state.handleEvent(["type": "state", "state": "speaking", "request_id": "previous-request",
                    "text": "previous read", "long_read": ["id": "previous-read", "preparing": false]])
                var event: [String: Any] = ["type": "state", "state": "speaking", "text": "Preparing speech…",
                    "long_read": ["id": "external-read", "preparing": true]]
                if let requestID { event["request_id"] = requestID }
                state.handleEvent(event)
                var commands: [[String: Any]] = []
                state.sendCommand = { commands.append($0) }
                state.selectionTextCaptureHandler = { $0(.completed(text)) }
                state.speakSelection()
                XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text"])
                XCTAssertEqual(commands.first?["text"] as? String, text)
            }
        }
    }

    func testOwnPreparingUsesKnownInputForBothSameAndDifferentSelections() {
        for next in ["Preparing speech…", "different selection"] {
            let state = VoiceState()
            var commands: [String] = []
            var selection = "Preparing speech…"
            state.sendCommand = { commands.append($0["cmd"] as! String) }
            state.selectionTextCaptureHandler = { $0(.completed(selection)) }
            state.speakSelection()
            state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                               "long_read": ["id": "own-preparing", "preparing": true]])
            selection = next
            state.speakSelection()
            XCTAssertEqual(commands, ["speak_text", next == "Preparing speech…" ? "stop" : "speak_text"])
        }
    }

    func testExternalSpeakingWithoutCanonicalTextUsesUnknownTextRulesEvenWithSubtitleWords() {
        for (result, expected) in [(SelectionCaptureResult.completed("same"), "speak_text"),
                                   (.completed(nil), "stop"), (.captureFailed, "stop")] {
            let state = VoiceState()
            state.handleEvent(["type": "state", "state": "speaking"])
            state.handleEvent(["type": "subtitle", "words": [["text": "same", "offset_ms": 0, "duration_ms": 100]]])
            var commands: [String] = []
            state.sendCommand = { commands.append($0["cmd"] as! String) }
            state.selectionTextCaptureHandler = { $0(result) }
            state.speakSelection()
            XCTAssertEqual(commands, [expected], "Subtitle tokens are not canonical input text")
        }
    }

    func testExternalTextBecomingKnownDuringCaptureIsUsedForComparison() {
        let state = speakingState(preparing: true)
        var completion: ((SelectionCaptureResult) -> Void)?
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "now known text",
                           "long_read": ["id": "old-read", "preparing": false]])
        completion?(.completed("now  known\ntext"))
        XCTAssertEqual(commands, ["stop"])
    }

    func testSameSelectionWithNormalizedWhitespaceStops() {
        let state = speakingState("same  selection\nשלום")
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { $0(.completed("  same\tselection שלום\n")) }
        state.speakSelection()
        XCTAssertEqual(commands, ["stop"])
    }

    func testSameRawSelectionStopsDuringPreparationAndAfterMarkdownProjection() {
        let state = VoiceState()
        let text = "# Private title\n\n- original selection"
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed(text)) }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "own-read", "preparing": true]])
        state.speakSelection()
        XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
        // A new read must retain the original selection even though its display is projected.
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "next-read", "preparing": true]])
        state.handleEvent(["type": "state", "state": "speaking", "text": "Private title original selection",
                           "long_read": ["id": "next-read", "preparing": false]])
        state.speakSelection()
        XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
    }

    func testEmptyAndFailedCapturesStopSpeakingAndPreparing() {
        for preparing in [false, true] {
            for result in [SelectionCaptureResult.completed(nil), .completed(" \n\t"), .copyTimedOut,
                           .secureField, .captureFailed, .clipboardRestoreFailed, .clipboardChanged, .copyFailed, .copyEmpty] {
                let state = speakingState(preparing: preparing)
                var commands: [String] = []
                var captures = 0
                state.sendCommand = { commands.append($0["cmd"] as! String) }
                state.selectionTextCaptureHandler = { captures += 1; $0(result) }
                state.speakSelection()
                XCTAssertEqual(captures, 1)
                XCTAssertEqual(commands, ["stop"])
            }
        }
    }

    func testReplacementBusyAckHasVisibleTransientFeedbackWithoutStoppingOldRead() {
        let state = speakingState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("new selection")) }
        state.speakSelection()
        let id = commands.first?["id"] as? String ?? "missing-selection-id"
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "reason": "busy", "id": id])
        XCTAssertTrue(state.showsSelectionBusyNote)
        XCTAssertEqual(state.selectionFeedbackNote, "Busy. Selection not read")
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertEqual(state.statusText, "old selection")
        XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text"])
    }

    func testRejectedRequestCannotDonateItsInputToAnExternalReadArrivingBeforeTheAck() {
        let state = speakingState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("rejected input")) }
        state.speakSelection()
        let id = commands.first?["id"] as? String ?? "missing"
        state.handleEvent(["type": "state", "state": "speaking", "text": "external text",
                           "long_read": ["id": "external-read", "preparing": false]])
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "reason": "busy", "id": id])
        state.selectionTextCaptureHandler = { $0(.completed("external text")) }
        state.speakSelection()
        XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
    }

    func testNonBusyRejectionDoesNotClaimVoiceLayerIsBusyOrExposeDaemonDetails() {
        let state = speakingState()
        var request: [String: Any] = [:]
        state.sendCommand = { request = $0 }
        state.selectionTextCaptureHandler = { $0(.completed("new selection")) }
        state.speakSelection()
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject",
                           "reason": "private daemon error details", "id": request["id"] as? String ?? "missing"])
        XCTAssertEqual(state.selectionFeedbackNote, "Selection not read. Try again")
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertEqual(state.statusText, "old selection")
    }

    func testSecondPressStopsAndLateOrDuplicateCallbackCannotReplaceAFreshRead() {
        let state = speakingState()
        var callbacks: [(SelectionCaptureResult) -> Void] = []
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { callbacks.append($0) }
        state.speakSelection()
        XCTAssertTrue(commands.isEmpty, "capture comes before Stop")
        state.speakSelection()
        XCTAssertEqual(commands, ["stop"])
        guard let old = callbacks.first else { return XCTFail("missing capture") }
        old(.completed("stale selection"))
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.speakSelection()
        old(.completed("duplicate stale callback"))
        callbacks.last?(.completed("fresh selection"))
        XCTAssertEqual(commands, ["stop", "speak_text"])
    }

    func testStopAndDictationInvalidateCaptureEvenIfTheyFinishBeforeItReturns() {
        for interrupt in ["stop", "dictation", "f5", "disconnect"] {
            let state = speakingState()
            var completion: ((SelectionCaptureResult) -> Void)?
            var commands: [String] = []
            state.sendCommand = { commands.append($0["cmd"] as! String) }
            state.selectionTextCaptureHandler = { completion = $0 }
            state.speakSelection()
            switch interrupt {
            case "stop": state.stop()
            case "dictation": state.mode = .recording
            case "f5": state.hotkeyPhase = .pressing; state.hotkeyPhase = .idle
            default: state.mode = .disconnected
            }
            state.mode = .idle
            completion?(.completed("stale selection"))
            XCTAssertFalse(commands.contains("speak_text"), interrupt)
        }
    }

    func testPreparationToPlaybackOfSameReadDoesNotDiscardReplacementCapture() {
        let state = speakingState(preparing: true)
        var completion: ((SelectionCaptureResult) -> Void)?
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "old selection",
                           "long_read": ["id": "old-read", "preparing": false]])
        completion?(.completed("new selection"))
        XCTAssertEqual(commands, ["speak_text"])
    }

    func testSelectionCanRetryFromErrorButANewErrorInvalidatesAnOlderCapture() {
        let state = VoiceState()
        state.mode = .error
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { $0(.completed("retry selection")) }
        state.speakSelection()
        XCTAssertEqual(commands, ["speak_text"])
        state.mode = .idle
        var completion: ((SelectionCaptureResult) -> Void)?
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.mode = .error
        state.mode = .idle
        completion?(.completed("stale selection"))
        XCTAssertEqual(commands, ["speak_text"])
    }

    func testAnotherReadSupersedingCaptureWins() {
        let state = speakingState()
        var completion: ((SelectionCaptureResult) -> Void)?
        state.sendCommand = { _ in XCTFail("old capture cannot replace a newer read") }
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "new owner",
                           "long_read": ["id": "new-read", "preparing": false]])
        completion?(.completed("stale selection"))
    }

    @MainActor
    func testLatestCaptureSurvivesPendingSubmissionsFirstReceipt() async throws {
        for ackBeforeReceipt in [false, true] {
            for (result, expected) in [(SelectionCaptureResult.completed("pending B"), "stop"),
                                       (.completed("different C"), "speak_text"),
                                       (.completed(nil), "stop"), (.copyTimedOut, "stop"), (.captureFailed, "stop")] {
                let state = speakingState("playing A")
                var commands: [[String: Any]] = []
                state.sendCommand = { commands.append($0) }
                state.selectionTextCaptureHandler = { $0(.completed("pending B")) }
                state.speakSelection()
                let id = try XCTUnwrap(commands.first?["id"] as? String)
                var completion: ((SelectionCaptureResult) -> Void)?
                state.selectionTextCaptureHandler = { completion = $0 }
                state.speakSelection()
                await Task.yield()
                if ackBeforeReceipt {
                    state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "accept", "id": id])
                }
                state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                                   "long_read": ["id": "pending-read-B", "preparing": true]])
                await Task.yield()
                try XCTUnwrap(completion)(result)
                XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text", expected],
                               "ackBeforeReceipt=\(ackBeforeReceipt), outcome=\(result.outcome)")
                if expected == "speak_text" { XCTAssertEqual(commands.last?["text"] as? String, "different C") }
            }
        }
    }

    func testUnrelatedReadStillInvalidatesLatestCaptureWhileSubmissionIsPending() {
        let state = speakingState("playing A")
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { $0(.completed("pending B")) }
        state.speakSelection()
        var completion: ((SelectionCaptureResult) -> Void)?
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "unrelated D",
                           "long_read": ["id": "unrelated-read-D", "preparing": false]])
        completion?(.completed("stale C"))
        XCTAssertEqual(commands, ["speak_text"])
    }

    func testDaemonRejectionNoteSurvivesSpeakingRebroadcastAndChunkChange() throws {
        let state = speakingState()
        var request: [String: Any] = [:]
        state.sendCommand = { request = $0 }
        state.selectionTextCaptureHandler = { $0(.completed("new selection")) }
        state.speakSelection()
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "reason": "busy",
                           "id": try XCTUnwrap(request["id"] as? String)])
        for readID in ["old-read", "next-chunk-read"] {
            state.handleEvent(["type": "state", "state": "speaking", "text": "ongoing speech",
                               "long_read": ["id": readID, "preparing": false]])
            XCTAssertEqual(state.selectionFeedbackNote, "Busy. Selection not read")
        }
    }

    func testSameSelectionStopsBeforePreparationReceiptAndOldAckIsIgnored() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("own selection")) }
        state.speakSelection()
        state.speakSelection()
        XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text", "stop"])
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "reason": "busy",
                           "id": commands.first?["id"] as? String ?? "missing"])
        XCTAssertFalse(state.showsSelectionBusyNote)
    }

    @MainActor
    func testDaemonBusyNoteExpiresWithoutChangingPlayback() async throws {
        let state = speakingState()
        var request: [String: Any] = [:]
        state.sendCommand = { request = $0 }
        state.selectionTextCaptureHandler = { $0(.completed("new selection")) }
        state.speakSelection()
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "reason": "busy",
                           "id": request["id"] as? String ?? "missing"])
        XCTAssertTrue(state.showsSelectionBusyNote)
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertFalse(state.showsSelectionBusyNote)
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertEqual(state.statusText, "old selection")
    }

    func testBusySelectionReportsReasonWithoutChangingDictationOrCapturing() {
        for (mode, phase, reason) in [(VoiceMode.recording, HotkeyPhase.idle, "recording"),
                                      (.transcribing, .idle, "transcribing"),
                                      (.idle, .pressing, "f5_preview"),
                                      (.idle, .holding, "f5_preview"),
                                      (.idle, .awaitingSecondTap, "f5_preview")] {
            let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                                   recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
            state.mode = mode
            state.hotkeyPhase = phase
            state.transcript = "Synthetic words still being dictated שלום…"
            state.confirmationText = "Full previous transcript remains recoverable"
            state.recordingMode = "ptt"
            if mode == .recording { state.handleEvent(["type": "audio_level", "rms": 0.6]) }
            let previousMode = state.previousMode
            let captureLive = state.captureLive
            let waveform = state.recordingWaveformLevels
            let transcript = state.transcript
            var captures = 0
            var commands = 0
            var events: [(String, [String: String])] = []
            state.sendCommand = { _ in commands += 1 }
            state.selectionTextCaptureHandler = { _ in captures += 1 }
            state.diagnosticLogger = { events.append(($0, $1)) }
            state.speakSelection()
            XCTAssertEqual(events.count, 1, reason)
            XCTAssertEqual(events.first?.0, "selection_busy", reason)
            XCTAssertEqual(events.first?.1["reason"], reason)
            XCTAssertEqual(events.first?.1["appKeyWindowTitle"], "not_recorded")
            XCTAssertEqual(captures, 0, "no capture means no Copy event")
            XCTAssertEqual(commands, 0, "no speech, Stop or recorder command")
            XCTAssertEqual(state.mode, mode)
            XCTAssertEqual(state.previousMode, previousMode)
            XCTAssertEqual(state.hotkeyPhase, phase)
            XCTAssertEqual(state.transcript, transcript)
            XCTAssertEqual(state.recordingMode, "ptt")
            XCTAssertEqual(state.captureLive, captureLive)
            XCTAssertEqual(state.recordingWaveformLevels, waveform)
            XCTAssertEqual(state.confirmationText, "Full previous transcript remains recoverable")
            XCTAssertEqual(Set(events.first?.1.keys.map { $0 } ?? []), Set(["reason", "appKeyWindowTitle"]))
        }
    }

    @MainActor
    func testBusyNoteExpiresAndARepeatedPressRestartsItsTwoSeconds() async throws {
        let state = VoiceState()
        state.mode = .recording
        state.transcript = "Keep every synthetic word"
        state.handleEvent(["type": "audio_level", "rms": 0.6])
        state.sendCommand = { _ in XCTFail("busy expiry must not send commands") }
        state.selectionTextCaptureHandler = { _ in XCTFail("busy expiry must not capture") }
        state.speakSelection()
        XCTAssertTrue(state.showsSelectionBusyNote)
        try await Task.sleep(for: .milliseconds(1100))
        state.speakSelection()
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertTrue(state.showsSelectionBusyNote, "an old timer must not clear the repeated note early")
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(state.showsSelectionBusyNote)
        XCTAssertEqual(state.mode, .recording)
        XCTAssertTrue(state.captureLive)
        XCTAssertEqual(state.transcript, "Keep every synthetic word")
    }

    func testBusyNoteDoesNotInterceptTheExistingStopAction() {
        let state = VoiceState()
        state.mode = .recording
        state.isConnected = true
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { _ in XCTFail("busy note must not capture") }
        state.speakSelection()
        XCTAssertTrue(commands.isEmpty)
        state.stop()
        XCTAssertEqual(commands, ["stop"])
        XCTAssertEqual(state.mode, .transcribing)
    }

    func testEmptySelectionUsesExistingTransientConfirmation() {
        let state = VoiceState()
        state.sendCommand = { _ in XCTFail("empty selection must not speak") }
        state.isCollapsed = true
        for selection: String? in [nil, "", " \n\t "] {
            state.selectionTextCaptureHandler = { $0(.completed(selection)) }
            state.speakSelection()
            XCTAssertEqual(state.confirmationText, "No text selected")
            XCTAssertFalse(state.isCollapsed, "transient feedback must be visible from collapsed idle")
            XCTAssertEqual(state.mode, .idle)
        }
    }

    func testCaptureCompletionCannotInterruptNewDictation() {
        let state = VoiceState()
        var completion: ((SelectionCaptureResult) -> Void)?
        var captures = 0
        state.sendCommand = { _ in XCTFail("stale capture must not speak over dictation") }
        state.selectionTextCaptureHandler = { captures += 1; completion = $0 }
        state.speakSelection()
        XCTAssertEqual(captures, 1)
        state.mode = .recording
        completion?(.completed("selection"))
        XCTAssertEqual(state.mode, .recording)
    }
}
