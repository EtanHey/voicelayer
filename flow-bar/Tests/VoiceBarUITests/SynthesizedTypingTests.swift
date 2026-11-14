@testable import VoiceBarUI
import XCTest

/// AIDEV-NOTE: v2.2.19 typed every transcript as Unicode key events wrapped in
/// ESC[200~ … ESC[201~. In cmux (Ghostty), under the kitty keyboard protocol that
/// Claude Code and Codex switch on, a key event whose text holds ANY control
// The legacy chunker wrapped control characters around payload text.
// The simulated terminal replaces each such event with a single character.
// The boundary fixture checks both missing ends exactly.
// The current chunker must preserve the entire input.
final class SynthesizedTypingTests: XCTestCase {
    private let short = "Shift+F5 should be paste."
    private let long = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
    private let list = "Three things:\n1. the bar\n2. the pill\r\n3. the paste"

    func testNoKeystrokeCarriesAControlCharacter() {
        for text in [short, long, list] {
            for case let .text(payload) in SynthesizedTyping.keystrokes(for: text) {
                let controls = payload.unicodeScalars.filter { $0.value < 0x20 || (0x7F ... 0x9F).contains($0.value) }
                XCTAssertTrue(controls.isEmpty, "\(payload.debugDescription) carries \(controls.map(\.value))")
            }
        }
    }

    /// The short shape that came out as "aa": every character must be typed.
    func testAShortDictationIsTypedWhole() {
        XCTAssertEqual(Self.typed(SynthesizedTyping.keystrokes(for: short)), short)
    }

    /// The long shape lost the words in its first and last events.
    func testALongDictationLosesNoWordsAtEitherEnd() {
        XCTAssertEqual(Self.typed(SynthesizedTyping.keystrokes(for: long)), long)
    }

    /// Line breaks are their own keystroke, so they can be sent as a key that
    /// breaks the line instead of submitting it. CRLF is one break, not two.
    func testLineBreaksBecomeNewlineKeystrokes() {
        let keystrokes = SynthesizedTyping.keystrokes(for: list)
        XCTAssertEqual(keystrokes.filter { $0 == .newline }.count, 3)
        XCTAssertEqual(Self.typed(keystrokes), "Three things:\n1. the bar\n2. the pill\n3. the paste")
    }

    func testEveryTextKeystrokeFitsOneEventAndKeepsCharactersWhole() {
        let mixed = String(repeating: "שלום עולם 👩‍💻 ", count: 6)
        let keystrokes = SynthesizedTyping.keystrokes(for: mixed)
        for case let .text(payload) in keystrokes {
            XCTAssertLessThanOrEqual(payload.utf16.count, SynthesizedTyping.maxUTF16UnitsPerEvent)
            XCTAssertFalse(payload.isEmpty)
        }
        XCTAssertEqual(Self.typed(keystrokes), mixed)
        // Joining can hide a split; per-event Characters cannot. A grapheme cut across
        // two events would show up here as two different Characters.
        XCTAssertEqual(Self.payloads(keystrokes).flatMap { Array($0) }, Array(mixed))
    }

    /// Policy for a grapheme longer than one event (a letter under 20 combining
    /// marks): it goes out scalar by scalar, in order, across consecutive events —
    /// never dropped, never reordered. Every other grapheme stays whole in one event.
    func testAGraphemeLongerThanOneEventIsSplitByScalarsInOrderAndNothingElseIs() {
        let oversized = "a" + String(repeating: "\u{0301}", count: 20)
        XCTAssertEqual(oversized.count, 1, "precondition: one Character")
        XCTAssertGreaterThan(oversized.utf16.count, SynthesizedTyping.maxUTF16UnitsPerEvent)
        let text = "before " + oversized + " after"

        let payloads = Self.payloads(SynthesizedTyping.keystrokes(for: text))
        for payload in payloads {
            XCTAssertLessThanOrEqual(payload.utf16.count, SynthesizedTyping.maxUTF16UnitsPerEvent)
        }
        XCTAssertEqual(payloads.joined(), text)
        XCTAssertEqual(
            payloads.flatMap(\.unicodeScalars).map(\.value),
            text.unicodeScalars.map(\.value),
            "every scalar, in order"
        )
        XCTAssertTrue(payloads.first?.hasPrefix("before ") == true, "the words before it stay whole")
        XCTAssertTrue(payloads.last?.hasSuffix(" after") == true, "the words after it stay whole")
    }

    func testTabsAreTypedAsSpacesNotDropped() {
        XCTAssertEqual(Self.typed(SynthesizedTyping.keystrokes(for: "a\tb")), "a b")
    }

    /// Regression shape reported 2026-09-13: control characters corrupt the first and last chunks.
    /// This invented 97-unit payload preserves the original UTF-16 chunk boundaries.
    func testSyntheticBoundarySampleIsTypedWholeWhereV2219AteBothEnds() {
        let dictated = String(repeating: "x", count: 97)
        let landedOn2219 = Self.cmuxKittyRendering(Self.v2219Keystrokes(for: dictated))
        XCTAssertEqual(landedOn2219, "a" + String(repeating: "x", count: 80) + "a")

        XCTAssertEqual(Self.cmuxKittyRendering(SynthesizedTyping.keystrokes(for: dictated)), dictated)
    }

    /// What cmux types per event under the kitty keyboard protocol: an event whose
    /// text holds a control character is encoded as its key instead — keycode 0, `a`.
    private static func cmuxKittyRendering(_ keystrokes: [SynthesizedKeystroke]) -> String {
        keystrokes.map { keystroke in
            switch keystroke {
            case let .text(payload): payload.unicodeScalars.contains { $0.value < 0x20 } ? "a" : payload
            case .newline: "\n"
            }
        }.joined()
    }

    /// v2.2.19's chunker, kept only as the fixture the rendering model is checked against.
    private static func v2219Keystrokes(for text: String) -> [SynthesizedKeystroke] {
        let body = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        let units = Array(("\u{1B}[200~" + body + "\u{1B}[201~").utf16)
        return stride(from: 0, to: units.count, by: 20).map { start in
            .text(String(decoding: units[start ..< min(start + 20, units.count)], as: UTF16.self))
        }
    }

    private static func payloads(_ keystrokes: [SynthesizedKeystroke]) -> [String] {
        keystrokes.compactMap { keystroke in
            if case let .text(payload) = keystroke { return payload }
            return nil
        }
    }

    private static func typed(_ keystrokes: [SynthesizedKeystroke]) -> String {
        keystrokes.map { keystroke in
            switch keystroke {
            case let .text(payload): payload
            case .newline: "\n"
            }
        }.joined()
    }
}
