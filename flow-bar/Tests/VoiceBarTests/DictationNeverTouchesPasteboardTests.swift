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
        XCTAssertEqual(harness.typed.map(\.bracketed), [true], "a terminal gets bracketed typing")
    }

    /// Newlines must not self-submit, and the pasteboard still holds what he copied.
    func testMultiLineDictationIntoATerminalIsTypedAsOneBracketedPaste() {
        let harness = PasteHarness(bundleIdentifier: "com.cmuxterm.app", pasteboard: "WHAT HE COPIED")
        harness.dictate("line one\nline two\nline three")

        XCTAssertEqual(harness.typed.count, 1, "one delivery, not one per line")
        XCTAssertEqual(harness.typed.first?.text, "line one\nline two\nline three")
        XCTAssertEqual(harness.typed.first?.bracketed, true, "bracketed, so each newline stays literal")
        XCTAssertEqual(harness.pasteboard, "WHAT HE COPIED")
        XCTAssertEqual(harness.pasteboardWrites, [])
    }

    /// A non-terminal whose AX insertion misses falls back to typing — never the clipboard.
    func testNonTerminalAXMissFallsBackToTypingNeverTheClipboard() {
        let harness = PasteHarness(bundleIdentifier: "com.apple.TextEdit", pasteboard: "WHAT HE COPIED")
        harness.dictate("into an ordinary text field")

        XCTAssertEqual(harness.pasteboardWrites, [], "the clipboard is never a fallback")
        XCTAssertEqual(harness.pasteboard, "WHAT HE COPIED")
        XCTAssertEqual(harness.typed.map(\.text), ["into an ordinary text field"])
        XCTAssertEqual(harness.typed.map(\.bracketed), [false], "no paste markers outside a terminal")
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
    let bracketed: Bool
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
        state.textTypingHandler = { [weak self] text, bracketed in
            self?.typed.append(TypedDelivery(text: text, bracketed: bracketed))
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
