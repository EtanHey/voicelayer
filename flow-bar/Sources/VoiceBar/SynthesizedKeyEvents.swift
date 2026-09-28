import CoreGraphics
import VoiceBarUI

/// Builds the CGEvents for a keystroke plan from `SynthesizedTyping`. The plan
/// (what text rides in which event, and why no control character may) lives in
/// VoiceBarUI; constructing and posting events is kept here, in the executable,
/// so VoiceBarUI stays presentation-only (BoundaryContractTests).
enum SynthesizedKeyEvents {
    /// kVK_Return.
    static let returnKeyCode: CGKeyCode = 36
    /// Carrier key for Unicode-string events. The receiving app types the string,
    /// not the key, as long as the string is printable — which is the invariant.
    static let textCarrierKeyCode: CGKeyCode = 0

    /// Key-down/key-up pairs for `keystrokes`, in order, or nil if one could not
    /// be created. Posting them requires Accessibility.
    static func events(for keystrokes: [SynthesizedKeystroke], source: CGEventSource?) -> [CGEvent]? {
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
}
