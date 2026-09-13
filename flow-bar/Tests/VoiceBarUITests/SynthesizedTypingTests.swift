import CoreGraphics
@testable import VoiceBarUI
import XCTest

/// AIDEV-NOTE: v2.2.19 typed every transcript as Unicode key events wrapped in
/// ESC[200~ … ESC[201~. In cmux (Ghostty), under the kitty keyboard protocol that
/// Claude Code and Codex switch on, a key event whose text holds ANY control
/// character is not sent as text: Ghostty encodes the key itself instead, and the
/// events were built on virtual keycode 0 — `a`. Etan, 2026-09-13: *"keeps doing
/// 'a' at the begining and 'a' at the end, or 'aa' for short ones."* The words in
/// those two events were lost with it. So: no keystroke may carry a control
/// character, and every word must come out.
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
    }

    func testTabsAreTypedAsSpacesNotDropped() {
        XCTAssertEqual(Self.typed(SynthesizedTyping.keystrokes(for: "a\tb")), "a b")
    }

    /// The events actually posted: keycode 0 only ever carries printable text, and
    /// a line break is Shift+Return — never a bare Return, which submits.
    func testPostedEventsNeverTypeTheCarrierKeyAndBreakLinesWithShiftReturn() throws {
        let source = CGEventSource(stateID: .privateState)
        let events = try XCTUnwrap(SynthesizedTyping.events(
            for: SynthesizedTyping.keystrokes(for: list),
            source: source
        ))
        var lineBreakEvents = 0
        var typedText = ""
        for (index, event) in events.enumerated() {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == SynthesizedTyping.returnKeyCode {
                XCTAssertTrue(event.flags.contains(.maskShift), "a line break must never be a bare Return")
                lineBreakEvents += 1
                if index % 2 == 0 { typedText += "\n" }
                continue
            }
            XCTAssertEqual(keyCode, SynthesizedTyping.textCarrierKeyCode)
            XCTAssertFalse(event.flags.contains(.maskShift), "held Shift must not ride along on typed text")
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 64)
            event.keyboardGetUnicodeString(
                maxStringLength: buffer.count,
                actualStringLength: &length,
                unicodeString: &buffer
            )
            let text = String(utf16CodeUnits: buffer, count: length)
            XCTAssertFalse(text.isEmpty, "keycode 0 with no text types the key itself: `a`")
            XCTAssertFalse(text.unicodeScalars.contains { $0.value < 0x20 }, "\(text.debugDescription)")
            if index % 2 == 0 { typedText += text }
        }
        XCTAssertEqual(lineBreakEvents, 6, "three breaks, key-down and key-up each")
        XCTAssertEqual(typedText, "Three things:\n1. the bar\n2. the pill\n3. the paste")
    }

    /// Etan's live sample from the installed v2.2.19, relayed by orc on 2026-09-13:
    ///
    ///     dictated: "Scoring has deduplication for every 15 minutes … it's just not the same everything."
    ///     landed:   "aduplication for every 15 minutes … it's just not the same everythia"
    ///
    /// The relay elided his middle, so `middle` is filler of the length that puts
    /// v2.2.19's last event on "ng." + ESC[201~ — the alignment his sentence had.
    /// The head needs no filler: it is his real text and his real result.
    func testEtansLiveSampleIsTypedWholeWhereV2219AteBothEnds() {
        let middle = " and then again, "
        let dictated = "Scoring has deduplication for every 15 minutes" + middle + "it's just not the same everything."

        let landedOn2219 = Self.cmuxKittyRendering(Self.v2219Keystrokes(for: dictated))
        XCTAssertTrue(landedOn2219.hasPrefix("aduplication for every 15 minutes"), landedOn2219)
        XCTAssertTrue(landedOn2219.hasSuffix("it's just not the same everythia"), landedOn2219)

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

    private static func typed(_ keystrokes: [SynthesizedKeystroke]) -> String {
        keystrokes.map { keystroke in
            switch keystroke {
            case let .text(payload): payload
            case .newline: "\n"
            }
        }.joined()
    }
}
