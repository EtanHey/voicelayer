import CoreGraphics
@testable import VoiceBar
import VoiceBarUI
import XCTest

/// The CGEvent half of typed delivery, which lives in the executable so VoiceBarUI
/// stays presentation-only. Why no keystroke may carry a control character, and
/// the v2.2.19 stray-"a" history, is in `SynthesizedTypingTests`.
final class SynthesizedKeyEventsTests: XCTestCase {
    private let list = "Three things:\n1. the bar\n2. the pill\r\n3. the paste"

    /// The events actually posted: keycode 0 only ever carries printable text, and
    /// a line break is Shift+Return — never a bare Return, which submits.
    func testPostedEventsNeverTypeTheCarrierKeyAndBreakLinesWithShiftReturn() throws {
        let source = CGEventSource(stateID: .privateState)
        let events = try XCTUnwrap(SynthesizedKeyEvents.events(
            for: SynthesizedTyping.keystrokes(for: list),
            source: source
        ))
        var lineBreakEvents = 0
        var typedText = ""
        for (index, event) in events.enumerated() {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == SynthesizedKeyEvents.returnKeyCode {
                XCTAssertTrue(event.flags.contains(.maskShift), "a line break must never be a bare Return")
                lineBreakEvents += 1
                if index % 2 == 0 { typedText += "\n" }
                continue
            }
            XCTAssertEqual(keyCode, SynthesizedKeyEvents.textCarrierKeyCode)
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
}
