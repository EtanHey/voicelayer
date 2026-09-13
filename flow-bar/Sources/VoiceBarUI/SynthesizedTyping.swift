import CoreGraphics
import Foundation

/// One synthesized keyboard event in a typed delivery.
public enum SynthesizedKeystroke: Equatable {
    /// A key event whose Unicode string is `text` — printable characters only.
    case text(String)
    /// A line break, sent as Shift+Return.
    case newline
}

/// Turns a transcript into keyboard events. Never touches the pasteboard.
///
/// AIDEV-NOTE: No keystroke may carry a control character. v2.2.19 typed
/// ESC[200~ … ESC[201~ (and `\r` for each newline) inside the Unicode strings of
/// key events on virtual keycode 0. cmux does not send key text that starts with
/// a control character, and Ghostty's kitty keyboard encoder — on whenever Claude
/// Code or Codex runs — encodes the KEY instead of any key text that contains one
/// (ghostty `src/input/key_encode.zig`, the `plain_text` block). Keycode 0 is
/// `a`: every dictation arrived as "a<middle>a", and the words inside the first
/// and last event were gone. A typed key event cannot deliver an ESC byte to cmux
/// at all, so bracketed-paste markers cannot be synthesized by typing.
///
/// Line breaks go out as Shift+Return: under the kitty protocol Claude Code and
/// Codex read it as a new line, not a submit. Known limit: an app that has not
/// turned the kitty protocol on (a bare shell prompt) reads it as Return.
public enum SynthesizedTyping {
    /// A keyboard event carries at most ~20 UTF-16 units of text.
    public static let maxUTF16UnitsPerEvent = 20
    /// kVK_Return.
    public static let returnKeyCode: CGKeyCode = 36
    /// Carrier key for Unicode-string events. The receiving app types the string,
    /// not the key, as long as the string is printable — which is the invariant.
    public static let textCarrierKeyCode: CGKeyCode = 0

    public static func keystrokes(for text: String) -> [SynthesizedKeystroke] {
        var keystrokes: [SynthesizedKeystroke] = []
        var run = ""
        var runUnits = 0
        func flush() {
            guard !run.isEmpty else { return }
            keystrokes.append(.text(run))
            run = ""
            runUnits = 0
        }
        func append(_ piece: String) {
            let units = piece.utf16.count
            if runUnits + units > maxUTF16UnitsPerEvent { flush() }
            run += piece
            runUnits += units
        }
        // Iterating Characters keeps "\r\n" one break and never splits a grapheme
        // (a surrogate pair, an emoji sequence, Hebrew with its marks) across events.
        for character in text {
            if character.isNewline {
                flush()
                keystrokes.append(.newline)
                continue
            }
            if character.unicodeScalars.contains(where: isControl) {
                // A tab is a space's worth of text; any other control character is
                // not text, and is exactly what must never ride in a key event.
                if character == "\t" { append(" ") }
                continue
            }
            let piece = String(character)
            if piece.utf16.count <= maxUTF16UnitsPerEvent {
                append(piece)
            } else {
                // One character longer than an event goes out scalar by scalar
                // rather than being dropped.
                for scalar in character.unicodeScalars {
                    append(String(scalar))
                }
            }
        }
        flush()
        return keystrokes
    }

    /// Key-down/key-up pairs for `keystrokes`, in order, or nil if one could not
    /// be created. Posting them requires Accessibility.
    public static func events(for keystrokes: [SynthesizedKeystroke], source: CGEventSource?) -> [CGEvent]? {
        var events: [CGEvent] = []
        for keystroke in keystrokes {
            let keyCode: CGKeyCode
            let flags: CGEventFlags
            var unicode: [UniChar] = []
            switch keystroke {
            case let .text(payload):
                keyCode = textCarrierKeyCode
                // Explicitly no modifiers: Shift is physically held during a Shift+F5
                // re-paste, and it must not ride along on the typed text.
                flags = []
                unicode = Array(payload.utf16)
            case .newline:
                keyCode = returnKeyCode
                flags = .maskShift
            }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            else { return nil }
            down.flags = flags
            up.flags = flags
            if !unicode.isEmpty {
                down.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
                up.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
            }
            events.append(down)
            events.append(up)
        }
        return events
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value)
    }
}
