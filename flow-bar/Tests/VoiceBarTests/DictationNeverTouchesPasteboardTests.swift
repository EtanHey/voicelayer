import AppKit
@testable import VoiceBarUI
import XCTest

/// AIDEV-NOTE: Etan's spec for how a transcript reaches the target, 2026-09-13:
/// *"the transcription is my paste instead of only Shift+F5 being paste of last
/// transcript and Command+V being kept for only actual clipboard use."*
///
///   - Shift+F5 pastes the last transcript.
///   - Cmd+V is his clipboard, only ever his clipboard.
///   - Dictation never writes to the pasteboard.
///
/// These replace `ClipboardPasteRaceTests`, whose subject — the timed clipboard
/// restore — no longer exists: there is no clipboard in the paste path at all.
/// That history is the AIDEV-NOTE at VoiceState's paste call site.
final class DictationNeverTouchesPasteboardTests: XCTestCase {
    /// His exact shape: copy A, dictate B, Cmd+V must still paste A.
    func testCopiedTextSurvivesADictationIntoATerminal() {
        let harness = PasteHarness(bundleIdentifier: "com.cmuxterm.app", pasteboard: "WHAT HE COPIED")
        harness.dictate("the transcript he dictated")

        XCTAssertEqual(harness.pasteboardWrites, [], "dictation must never write the pasteboard")
        XCTAssertEqual(harness.pasteboard, "WHAT HE COPIED", "Cmd+V must still give him what he copied")
        XCTAssertEqual(harness.typed.map(\.text), ["the transcript he dictated"])
    }

    /// Newlines must not self-submit, and the pasteboard still holds what he copied.
    func testMultiLineDictationIntoATerminalIsTypedAsOneDelivery() {
        let harness = PasteHarness(bundleIdentifier: "com.cmuxterm.app", pasteboard: "WHAT HE COPIED")
        harness.dictate("line one\nline two\nline three")

        XCTAssertEqual(harness.typed.count, 1, "one delivery, not one per line")
        XCTAssertEqual(harness.typed.first?.text, "line one\nline two\nline three")
        XCTAssertEqual(harness.pasteboard, "WHAT HE COPIED")
        XCTAssertEqual(harness.pasteboardWrites, [])
    }

    /// Missing AX focus does not authorize global typing into an unknown target.
    func testNonTerminalAXMissRetainsTranscriptWithoutTypingOrClipboardWrites() {
        let harness = PasteHarness(bundleIdentifier: "com.apple.TextEdit", pasteboard: "WHAT HE COPIED")
        harness.dictate("into an ordinary text field")

        XCTAssertEqual(harness.pasteboardWrites, [], "the clipboard is never a fallback")
        XCTAssertEqual(harness.pasteboard, "WHAT HE COPIED")
        XCTAssertEqual(harness.typed, [])
        XCTAssertEqual(harness.state.latestReusableTranscript, "into an ordinary text field")
        XCTAssertEqual(harness.state.latestDictationInsertionStatus, .notInserted)
    }

    func testTerminalAgentSurfacesKeepAutomaticTypedDeliveryAfterAXMiss() {
        for bundle in ["com.cmuxterm.app", "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"] {
            let harness = PasteHarness(bundleIdentifier: bundle, pasteboard: "WHAT HE COPIED")
            harness.state.asyncDictationInsertionHandlerProvider = { { _, _ in XCTFail("Terminals must keep skipping AX"); return false } }
            harness.dictate("ADD שלום 👩‍💻\nsecond line")
            XCTAssertEqual(harness.typed.map(\.text), ["ADD שלום 👩‍💻\nsecond line"], bundle)
            XCTAssertEqual(harness.pasteboard, "WHAT HE COPIED", bundle)
            XCTAssertEqual(harness.pasteboardWrites, [], bundle)
            XCTAssertEqual(harness.state.latestDictationInsertionStatus, .typed, "Posted events are typed, not readback")
        }
    }

    func testEveryTerminalKeepsTranscriptConfirmationAndTypedStatus() {
        let text = "ADD שלום 👩‍💻\nsecond line"
        for bundle in TerminalPasteTargets.bundleIdentifiers.sorted() {
            let harness = PasteHarness(bundleIdentifier: bundle, pasteboard: "WHAT HE COPIED")
            harness.state.asyncDictationInsertionHandlerProvider = {
                { _, _ in XCTFail("Terminals must keep skipping AX: \(bundle)"); return false }
            }
            harness.dictate(text)
            XCTAssertEqual(harness.state.confirmationText, text, "Automatic delivery: \(bundle)")
            XCTAssertEqual(harness.state.latestDictationInsertionStatus, .typed, bundle)
            XCTAssertEqual(harness.typed.map(\.text), [text], "Exactly one automatic delivery: \(bundle)")
            XCTAssertEqual(harness.state.latestReusableTranscript, text, bundle)

            harness.state.repasteLastTranscript(source: "shift_f5")
            XCTAssertEqual(harness.state.confirmationText, text, "Explicit recovery: \(bundle)")
            XCTAssertEqual(harness.state.latestDictationInsertionStatus, .typed, bundle)
            XCTAssertEqual(harness.typed.map(\.text), [text, text], "One explicit recovery, no duplicate fallback: \(bundle)")
            XCTAssertEqual(harness.state.latestReusableTranscript, text, bundle)
            XCTAssertEqual(harness.pasteboardWrites, [], bundle)
            XCTAssertEqual(harness.pasteboard, "WHAT HE COPIED", bundle)
        }
    }

    func testTerminalTypingFailureKeepsFailureFeedbackAndFullRecovery() {
        for bundle in TerminalPasteTargets.bundleIdentifiers.sorted() {
            let harness = PasteHarness(bundleIdentifier: bundle, pasteboard: "WHAT HE COPIED")
            var attempts = 0
            harness.state.textTypingHandler = { _ in attempts += 1; return false }
            harness.dictate("all words stay recoverable")
            XCTAssertEqual(attempts, 1, bundle)
            XCTAssertEqual(harness.state.latestDictationInsertionStatus, .failed, bundle)
            XCTAssertEqual(harness.state.confirmationText, "Paste failed. Click the text field and press Shift+F5.", bundle)
            XCTAssertEqual(harness.state.latestReusableTranscript, "all words stay recoverable", bundle)
            XCTAssertEqual(harness.pasteboardWrites, [], bundle)
            XCTAssertEqual(harness.pasteboard, "WHAT HE COPIED", bundle)
        }
    }

    /// Shift+F5 types the last transcript and leaves whatever he copied since alone.
    func testShiftF5RepasteTypesTheLastTranscriptAndLeavesTheClipboardAlone() {
        let harness = PasteHarness(bundleIdentifier: "com.cmuxterm.app", pasteboard: "EARLIER COPY")
        harness.dictate("the transcript he dictated")
        harness.pasteboard = "COPIED AFTER DICTATING"

        harness.state.repasteLastTranscript(source: "shift_f5")

        XCTAssertEqual(harness.pasteboardWrites, [], "re-paste must not write the pasteboard either")
        XCTAssertEqual(harness.pasteboard, "COPIED AFTER DICTATING")
        XCTAssertEqual(harness.typed.last?.text, "the transcript he dictated")
    }
}

private struct TypedDelivery: Equatable {
    let text: String
}

/// Drives the REAL `VoiceState` paste flow. Any pasteboard write or Cmd+V fails.
private final class PasteHarness {
    let state = VoiceState()
    var pasteboard: String?
    private(set) var pasteboardWrites: [String] = []
    private(set) var typed: [TypedDelivery] = []

    init(bundleIdentifier: String, pasteboard: String?) {
        self.pasteboard = pasteboard
        let app = FakeTargetApplication(bundleIdentifier: bundleIdentifier)
        state.sendCommand = { _ in }
        state.minimumTranscribingDisplayDuration = 0
        state.pasteConfirmationDelay = 0
        state.frontmostAppProvider = { app }
        state.targetAppActivator = { _ in }
        state.pasteScheduler = { _, block in block() }
        state.pasteboardWriter = { [weak self] text in
            self?.pasteboardWrites.append(text)
            self?.pasteboard = text
        }
        state.pasteboardStringProvider = { [weak self] in self?.pasteboard }
        state.simulatedPasteHandler = {
            XCTFail("dictation must never post Cmd+V")
            return false
        }
        state.textTypingHandler = { [weak self] text in
            self?.typed.append(TypedDelivery(text: text))
            return true
        }
    }

    func dictate(_ text: String) {
        state.record()
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent(["type": "transcription", "text": text])
    }
}

private final class FakeTargetApplication: NSRunningApplication, @unchecked Sendable {
    private let bundleID: String

    init(bundleIdentifier: String) {
        bundleID = bundleIdentifier
        super.init()
    }

    override var bundleIdentifier: String? {
        bundleID
    }

    override var processIdentifier: pid_t {
        4242
    }
}
