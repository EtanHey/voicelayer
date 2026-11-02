import AppKit
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest
@MainActor
final class LaneIFormalConformanceTests: XCTestCase {
    private final class ConformanceApp: NSRunningApplication, @unchecked Sendable {
        override var processIdentifier: pid_t { 12001 }
        override var bundleIdentifier: String? { "synthetic.editor" }
    }
    private func recordingState() -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] })
        state.controlLayerEventWriter = { _, _ in }
        state.frontmostAppProvider = { nil }
        state.isConnected = true
        return state
    }
    private func snapshot(_ state: VoiceState, a: String?, b: String? = nil, kind: String = "live") {
        var jobs: [[String: Any]] = []
        if let a { jobs.append(["take_id": "A", "kind": kind, "phase": a]) }
        if let b { jobs.append(["take_id": "B", "kind": "live", "phase": b]) }
        state.handleEvent(["type": "state", "state": b == "capturing" ? "recording" : "transcribing",
            "recording_jobs": jobs, "mic_take_id": b == "capturing" ? "B" as Any : NSNull()])
    }
    func testTLCFixedAdmissionThroughNativeRouter() throws {
        for kind in ["live", "history"] {
            for action in ["hold", "tap", "record", "toggle", "start"] {
                let state = recordingState()
                snapshot(state, a: "processing", kind: kind)
                var commands: [[String: Any]] = []
                state.sendCommand = { commands.append($0) }
                let router = VoiceBarCommandRouter(voiceState: state)
                switch action {
                case "hold": router.handleHotkeyHoldStart()
                case "tap": router.handleHotkeySingleTap()
                case "record": state.record(pressToTalk: true)
                case "toggle": try router.handle(url: XCTUnwrap(URL(string: "voicebar://toggle")))
                default: router.handle(controlCommand: .startRecording)
                }
                XCTAssertEqual(commands.count, 1, action)
                XCTAssertEqual(commands.first?["cmd"] as? String, "record", action)
                XCTAssertNotNil(commands.first?["take_id"] as? String)
                XCTAssertEqual(state.processingTakeCount, 1, action)
                XCTAssertEqual(state.mode, .recording, action)
                XCTAssertTrue(router.shouldHandleEscape)
            }
        }
    }
    func testTLCFixedCancellationEdges() async throws {
        let path = ProcessInfo.processInfo.environment["VOICEBAR_RECORD_TLC_CASES"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../formal/record-while-processing-runtime/corpus.json").standardized.path
        struct Corpus: Decodable {
            struct Cancel: Decodable { let origin, target: String; let stages: [String: String] }
            let cancellations: [Cancel]
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThan(corpus.cancellations.count, 5)
        for row in corpus.cancellations {
            let state = recordingState()
            state.processingCancellationTickDuration = .milliseconds(1)
            let phases = ["recording": "capturing", "draining": "draining", "captured": "queued", "processing": "processing", "ack": "delivering"]
            let jobs: [[String: Any]] = ["A", "B"].compactMap { id in
                guard let stage = row.stages[id], let phase = phases[stage] else { return nil }
                return ["take_id": id, "kind": "live", "phase": phase]
            }
            let mic = ["A", "B"].first { ["recording", "draining"].contains(row.stages[$0] ?? "") }
            state.handleEvent(["type": "state", "state": mic == nil ? "transcribing" : "recording",
                "recording_jobs": jobs, "mic_take_id": mic as Any])
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            let processing = ["captured", "processing"].contains(row.stages[row.target] ?? "")
            let escapeNeedsGuard = row.origin == "Escape" && mic == nil && state.displayedProcessingTakeID != row.target
            if processing && (row.origin == "click" || escapeNeedsGuard) {
                if escapeNeedsGuard {
                    VoiceBarCommandRouter(voiceState: state).handleEscape()
                    XCTAssertTrue(commands.isEmpty)
                    XCTAssertEqual(state.processingCancellationGuard?.takeID, row.target)
                } else { state.requestProcessingCancellation(takeID: row.target) }
                let deadline = Date().addingTimeInterval(2)
                while state.processingCancellationGuard?.remainingTicks != 0, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                }
                XCTAssertTrue(state.commitProcessingCancellation(takeID: row.target))
            } else if row.origin == "Escape" {
                VoiceBarCommandRouter(voiceState: state).handleEscape()
            } else {
                VoiceBarCommandRouter(voiceState: state).handleCancel()
            }
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.first?["cmd"] as? String, "cancel")
            XCTAssertEqual(commands.first?["take_id"] as? String, row.target, "\(row.origin) \(row.stages)")
        }
    }
    func testTLCScopedCancelGuardAndEscape() async throws {
        let state = recordingState()
        state.processingCancellationTickDuration = .milliseconds(5)
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        let router = VoiceBarCommandRouter(voiceState: state)
        snapshot(state, a: "processing")
        router.handleCancel()
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(state.processingCancellationGuard?.takeID, "A")
        XCTAssertEqual(state.processingCancellationGuard?.remainingTicks, 2)
        XCTAssertEqual(state.processingCancellationGuard?.isRingActive, true)
        XCTAssertFalse(state.commitProcessingCancellation(takeID: "A"))
        snapshot(state, a: "processing", b: "capturing")
        router.handleCancel()
        XCTAssertEqual(commands.last?["take_id"] as? String, "B")
        XCTAssertEqual(state.processingCancellationGuard?.takeID, "A", "B cancellation preserves A's guard")
        XCTAssertEqual(state.processingTakeCount, 1)
        router.handleEscape()
        XCTAssertEqual(commands.last?["take_id"] as? String, "B")
        snapshot(state, a: "processing")
        let deadline = Date().addingTimeInterval(2)
        while state.processingCancellationGuard?.remainingTicks != 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.processingCancellationGuard?.isRingActive, false)
        XCTAssertEqual(state.processingCancellationGuard?.ringProgress, 1)
        XCTAssertTrue(state.commitProcessingCancellation(takeID: "A"))
        XCTAssertEqual(commands.last?["take_id"] as? String, "A")
        XCTAssertNil(state.processingCancellationGuard)

        state.requestProcessingCancellation(takeID: "A")
        XCTAssertEqual(state.processingCancellationGuard?.remainingTicks, 2)
        router.handleEscape()
        XCTAssertEqual(commands.last?["take_id"] as? String, "A", "Escape bypasses cooldown")
        XCTAssertNil(state.processingCancellationGuard)
        XCTAssertTrue(router.shouldHandleEscape)
        snapshot(state, a: nil)
        XCTAssertFalse(router.shouldHandleEscape, "L8 and router share idle cancellation eligibility")
    }
    func testTLCStaleGuardCannotCancelLaterTake() async throws {
        let state = recordingState()
        state.processingCancellationTickDuration = .milliseconds(1)
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        snapshot(state, a: "processing")
        state.requestProcessingCancellation(takeID: "A")
        snapshot(state, a: nil, b: "processing")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(state.processingCancellationGuard)
        XCTAssertFalse(state.commitProcessingCancellation(takeID: "A"))
        XCTAssertTrue(commands.isEmpty)
        state.cancel()
        XCTAssertEqual(state.processingCancellationGuard?.takeID, "B")
        XCTAssertTrue(commands.isEmpty)
    }
    func testTLCImmediatePasteWhileBRecordsPreservesForegroundAndRawWords() throws {
        let state = recordingState()
        let app = ConformanceApp()
        state.frontmostAppProvider = { app }
        state.dictationTargetIdentityProvider = { { true } }
        var commands: [[String: Any]] = [], pasted: [String] = []
        state.sendCommand = { commands.append($0) }
        state.pasteHandler = { pasted.append($0); return true }
        state.record(pressToTalk: true)
        let a = try XCTUnwrap(commands.first?["take_id"] as? String)
        state.handleEvent(["type": "state", "state": "transcribing", "mic_take_id": NSNull(),
            "recording_jobs": [["take_id": a, "kind": "live", "phase": "processing"]]])
        state.record(pressToTalk: true)
        let b = try XCTUnwrap(commands.last?["take_id"] as? String)
        state.handleEvent(["type": "state", "state": "recording", "mic_take_id": b,
            "recording_jobs": [["take_id": a, "kind": "live", "phase": "processing"],
                               ["take_id": b, "kind": "live", "phase": "capturing"]]])
        let raw = "first\r\nשלום fu…\n"
        state.handleEvent(["type": "transcription", "take_id": a, "job_kind": "live", "delivery_id": a, "text": raw])
        XCTAssertEqual(pasted, [raw], "Final-result handler dispatches before returning, without a display timer")
        XCTAssertEqual(state.mode, .recording)
        XCTAssertEqual(state.microphoneTakeID, b)
        XCTAssertEqual(commands.last?["cmd"] as? String, "dictation_delivered")
        state.handleEvent(["type": "transcription", "take_id": a, "job_kind": "live", "delivery_id": a, "text": raw])
        XCTAssertEqual(pasted, [raw], "Repeated delivery is acknowledged without another paste")
    }
    func testTLCFinalIsImmediateAndSurvivesNewRecording() async throws {
        for newRecording in [false, true] {
            let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] })
            state.controlLayerEventWriter = { _, _ in }
            state.frontmostAppProvider = { nil }
            state.handleEvent(["type": "state", "state": "transcribing"])
            state.handleEvent(["type": "transcription", "text": "Synthetic final A"])
            XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), ["Synthetic final A"])
            if newRecording { state.handleEvent(["type": "state", "state": "recording", "bar_owned": false]) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), ["Synthetic final A"])
        }
        print("Fixed replay: final A retained immediately and survives a new recording event")
    }
}
