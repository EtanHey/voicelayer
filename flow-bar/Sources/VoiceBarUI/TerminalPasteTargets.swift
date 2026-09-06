import Foundation

/// Delivery policy for terminal emulators.
///
/// AIDEV-NOTE: A terminal composer (Claude Code, a REPL, anything that turns on
/// bracketed paste / DECSET 2004) needs the transcript to arrive as a *paste*.
/// A real Cmd+V is wrapped by the terminal in `ESC[200~ … ESC[201~`, so every
/// newline inside stays literal. The AX insertion path is not wrapped: the text
/// is pushed into the focused element and each newline reaches the composer as a
/// bare Return, which submits the line instead of breaking it. That is the
/// 2026-09-06 "multi-line paste submits itself" bug — captured in
/// `com.cmuxterm.app` (Ghostty-backed) with a 3-line transcript:
///
///     clipboard paste  -> 033 [ 2 0 0 ~  … \n …  033 [ 2 0 1 ~   (94 + 12 bytes)
///     unbracketed text -> …  \n  …  \n  …                        (94 bytes)
///
/// So for these bundle identifiers we always take the clipboard + Cmd+V route
/// and never the AX/typed one.
public enum TerminalPasteTargets {
    /// Bundle identifiers that host a terminal emulator.
    public static let bundleIdentifiers: Set<String> = [
        "com.cmuxterm.app", // cmux (embeds Ghostty)
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
    ]

    public static func isTerminal(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
    }

    /// Removes at most one trailing newline. Internal newlines are kept — they are
    /// the user's line breaks and bracketed paste delivers them literally. A
    /// *trailing* newline has nothing after it to bracket-protect it from the
    /// composer, so it lands as a Return once the paste ends.
    public static func strippingSingleTrailingNewline(_ text: String) -> String {
        // "\r\n" is a single Character in Swift, so one dropLast removes the whole pair.
        guard let last = text.last, trailingNewlines.contains(last) else { return text }
        return String(text.dropLast())
    }

    private static let trailingNewlines: Set<Character> = ["\n", "\r", "\r\n"]
}
