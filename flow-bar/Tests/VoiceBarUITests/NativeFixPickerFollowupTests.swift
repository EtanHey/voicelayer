import XCTest
@testable import VoiceBarUI

@MainActor
final class NativeFixPickerFollowupTests: XCTestCase {
    private func voice() -> VoiceState {
        VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] })
    }

    func testExplicitRetryOfEitherFailedDesiredEngineSendsOnceAndPreservesDesired() throws {
        for (desired, effective, parakeet, whisper, reason) in [
            ("whisper", "parakeet", "ready", "error", "whisper-startup-failed"),
            ("parakeet", "whisper", "error", "ready", "parakeet-startup-failed")
        ] {
            let state = voice(); var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.setConnectionStatus(true)
            state.handleEvent(RecognizerBindingTests.event(desired: desired, effective: effective,
                parakeet: parakeet, whisper: whisper, fallback: reason))
            let engine = try XCTUnwrap(RecognizerPickerEngine(rawValue: desired))
            var pureCommands: [RecognizerPickerEngine] = []
            XCTAssertTrue(state.recognizerPickerState.select(engine, send: { pureCommands.append($0) }))
            XCTAssertEqual(pureCommands, [engine])
            state.selectRecognizer(engine)
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.last?["cmd"] as? String, "set_recognizer")
            XCTAssertEqual(commands.last?["recognizer"] as? String, desired)
            XCTAssertNotNil(commands.last?["id"] as? String)
            XCTAssertEqual(state.recognizerPickerState.selected, engine)
            state.selectRecognizer(engine)
            XCTAssertEqual(commands.count, 1, "A pending retry cannot queue another write")
        }
    }

    func testLegacyLanguageAndPromptReasonsDoNotDescribeAutomaticRouting() throws {
        for reason in ["language", "prompt"] {
            let raw = RecognizerBindingTests.event(desired: "parakeet", effective: "whisper", fallback: reason)["recognizer_status"] as! [String: Any]
            let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: raw)))
            XCTAssertEqual(state.selected, .parakeet)
            XCTAssertEqual(state.explanation, "Using Whisper for this recording.", "Legacy reason codes describe only the reported effective provider")
            let current = RecognizerBindingTests.event(desired: "parakeet", effective: "parakeet", parakeet: "ready", fallback: reason)["recognizer_status"] as! [String: Any]
            XCTAssertNil(RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: current))).explanation)
        }
    }

    func testReadySleepingBusyAndUnavailableCannotRetryTheSameDesiredChoice() {
        for state in [
            RecognizerPickerState(selected: .whisper, effective: .whisper, parakeet: .unloaded, whisper: .loaded),
            RecognizerPickerState(selected: .whisper, effective: nil, parakeet: .unloaded, whisper: .unloaded),
            RecognizerPickerState(selected: .whisper, effective: .parakeet, parakeet: .loaded, whisper: .error, disabledReason: "Voice is busy"),
            RecognizerPickerState.unavailable
        ] {
            var sent: [RecognizerPickerEngine] = []
            XCTAssertFalse(state.select(.whisper, send: { sent.append($0) }))
            XCTAssertTrue(sent.isEmpty)
        }
    }
}
