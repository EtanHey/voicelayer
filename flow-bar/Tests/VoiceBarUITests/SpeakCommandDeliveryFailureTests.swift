@testable import VoiceBarUI
import XCTest

@MainActor
final class SpeakCommandDeliveryFailureTests: XCTestCase {
    func testConnectedDeliveryFailureAllowsSameTextResubmissionWithoutPhantomStop() throws {
        for clipboard in [true, false] {
            let state = makeState()
            state.isConnected = true
            var commands: [[String: Any]] = []
            let text = "  Synthetic speech שלום 👩‍💻\n"
            state.sendCommand = { commands.append($0) }
            state.clipboardTextReadHandler = { _, done in done(.completed(text)) }
            state.selectionTextCaptureHandler = { $0(.completed(text)) }
            let submit = { if clipboard { state.readClipboard() } else { state.speakSelection() } }
            submit()
            let first = try XCTUnwrap(commands.first)
            let firstID = try XCTUnwrap(first["id"] as? String)
            // Model aggregate connection updates during owner handover, without a false edge.
            state.setConnectionStatus(true)
            state.handleCommandDeliveryFailure(first, reason: "VoiceLayer is reconnecting")
            state.setConnectionStatus(true)
            XCTAssertTrue(state.isConnected)
            XCTAssertEqual(state.mode, .idle)
            XCTAssertEqual(state.selectionFeedbackNote, "Selection not read. Try again")
            XCTAssertEqual(commands.count, 1, "Delivery failure must not retry automatically")
            submit()
            XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text", "speak_text"])
            let second = try XCTUnwrap(commands.last)
            XCTAssertNotEqual(try XCTUnwrap(second["id"] as? String), firstID)
            XCTAssertEqual(second["text"] as? String, text)
            XCTAssertEqual(second["source"] as? String, clipboard ? "clipboard" : "selection")
            XCTAssertNil(state.pendingIntent, "Speech must not become a recorder intent")
        }
    }

    func testOlderFailureRetiresOnlyOlderRequestAndLeavesNewerPendingOrActive() throws {
        for active in [false, true] {
            let state = makeState()
            state.isConnected = true
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            for text in ["Older synthetic read", "Newer synthetic read"] {
                state.clipboardTextReadHandler = { _, done in done(.completed(text)) }
                state.readClipboard()
            }
            let older = commands[0]
            let olderID = try XCTUnwrap(older["id"] as? String)
            let newerID = try XCTUnwrap(commands[1]["id"] as? String)
            if active { state.handleEvent(speakingEvent(id: newerID, text: "Newer synthetic read")) }
            let status = state.statusText
            state.handleCommandDeliveryFailure(older)
            state.handleEvent(speakingEvent(id: olderID, text: "Late undelivered read"))
            XCTAssertEqual(state.mode, active ? .speaking : .idle)
            XCTAssertEqual(state.statusText, status, "Retired request cannot bind a late receipt")
            XCTAssertTrue(state.isConnected)
            XCTAssertEqual(commands.count, 2)
            state.readClipboard()
            XCTAssertEqual(commands.last?["cmd"] as? String, "stop", "Newer same-text identity remains live")
        }
    }

    func testDuplicateOldFailureCannotRetireSameTextResubmission() throws {
        for active in [false, true] {
            let state = makeState()
            state.isConnected = true
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.clipboardTextReadHandler = { _, done in done(.completed("Same synthetic text")) }
            state.readClipboard()
            let older = try XCTUnwrap(commands.first)
            // Existing raw reject seam makes this stale-ID control independent of the new routing.
            state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "id": older["id"]!])
            state.readClipboard()
            let newerID = try XCTUnwrap(commands.last?["id"] as? String)
            XCTAssertNotEqual(newerID, older["id"] as? String)
            if active { state.handleEvent(speakingEvent(id: newerID, text: "Same synthetic text")) }
            state.handleCommandDeliveryFailure(older)
            XCTAssertEqual(state.mode, active ? .speaking : .idle)
            XCTAssertEqual(commands.count, 2)
            state.readClipboard()
            XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
        }
    }

    func testMissingMalformedAndUnknownIDsLeaveCurrentSpeechAndRecorderIntentIntact() throws {
        for active in [false, true] {
            let state = makeState()
            state.isConnected = true
            var commands: [[String: Any]] = []
            var recorderAcks: [SocketAckEvent] = []
            state.sendCommand = { commands.append($0) }
            state.onAckEvent = { recorderAcks.append($0) }
            state.clipboardTextReadHandler = { _, done in done(.completed("Current synthetic text")) }
            state.readClipboard()
            let id = try XCTUnwrap(commands.first?["id"] as? String)
            if active { state.handleEvent(speakingEvent(id: id, text: "Current synthetic text")) }
            let recorderID = UUID().uuidString
            state.pendingIntent = PendingIntent(id: recorderID, command: .record)
            let failures: [[String: Any]] = [
                ["cmd": "speak_text"], ["cmd": "speak_text", "id": ""],
                ["cmd": "speak_text", "id": 42], ["cmd": "speak_text", "id": UUID().uuidString],
                ["cmd": "speak_text", "id": recorderID], ["cmd": "unknown", "id": id], ["id": id],
            ]
            for failure in failures {
                state.handleCommandDeliveryFailure(failure)
            }
            XCTAssertEqual(state.mode, active ? .speaking : .idle)
            XCTAssertNil(state.selectionFeedbackNote)
            XCTAssertEqual(state.pendingIntent?.id, recorderID)
            XCTAssertTrue(recorderAcks.isEmpty)
            XCTAssertEqual(commands.count, 1)
            state.readClipboard()
            XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
        }
    }

    func testMatchingSpeechFailurePreservesRecorderRoutingAndDefaultReason() throws {
        let state = makeState()
        state.isConnected = true
        var commands: [[String: Any]] = []
        var acks: [SocketAckEvent] = []
        state.sendCommand = { commands.append($0) }
        state.onAckEvent = { acks.append($0) }
        state.clipboardTextReadHandler = { _, done in done(.completed("Synthetic pending speech")) }
        state.readClipboard()
        let recorderID = UUID().uuidString
        state.pendingIntent = PendingIntent(id: recorderID, command: .record)
        state.handleCommandDeliveryFailure(try XCTUnwrap(commands.first))
        XCTAssertEqual(state.selectionFeedbackNote, "Selection not read. Try again")
        XCTAssertEqual(state.pendingIntent?.id, recorderID)
        XCTAssertTrue(acks.isEmpty, "Raw speech rejection must not enter the recorder ack contract")
        state.handleCommandDeliveryFailure(["cmd": "record"])
        state.handleCommandDeliveryFailure(["cmd": "unknown", "id": recorderID])
        XCTAssertTrue(acks.isEmpty)
        state.handleCommandDeliveryFailure(["cmd": "record", "id": UUID().uuidString])
        XCTAssertEqual(state.pendingIntent?.id, recorderID)
        state.handleCommandDeliveryFailure(["cmd": "record", "id": recorderID])
        XCTAssertNil(state.pendingIntent)
        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(acks.count, 2)
        let ack = try XCTUnwrap(acks.last)
        XCTAssertEqual(ack.command, .record)
        XCTAssertEqual(ack.outcome, .reject)
        XCTAssertEqual(ack.id, recorderID)
        XCTAssertEqual(ack.reason, "VoiceLayer is starting")
        XCTAssertEqual(commands.count, 1, "Neither failure path resends a command")
    }

    func testFullDisconnectStillClearsPendingSpeechBeforeSameTextResubmission() throws {
        let state = makeState()
        state.isConnected = true
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.clipboardTextReadHandler = { _, done in done(.completed("Synthetic reconnect text")) }
        state.readClipboard()
        let firstID = try XCTUnwrap(commands.first?["id"] as? String)
        state.setConnectionStatus(false)
        XCTAssertEqual(state.mode, .disconnected)
        state.setConnectionStatus(true)
        state.readClipboard()
        XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text", "speak_text"])
        XCTAssertNotEqual(try XCTUnwrap(commands.last?["id"] as? String), firstID)
    }

    private func makeState() -> VoiceState {
        VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            playbackAmplitudeClock: { 0 }, keepsExpandedInDevState: false)
    }

    private func speakingEvent(id: String, text: String) -> [String: Any] {
        ["type": "state", "state": "speaking", "request_id": id, "text": text,
         "long_read": ["id": "synthetic-\(id)", "preparing": false]]
    }
}
