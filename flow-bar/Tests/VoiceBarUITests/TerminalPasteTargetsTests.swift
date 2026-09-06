@testable import VoiceBarUI
import XCTest

final class TerminalPasteTargetsTests: XCTestCase {
    func testRecognisesKnownTerminalBundleIdentifiers() {
        XCTAssertTrue(TerminalPasteTargets.isTerminal("com.cmuxterm.app"))
        XCTAssertTrue(TerminalPasteTargets.isTerminal("com.apple.Terminal"))
        XCTAssertTrue(TerminalPasteTargets.isTerminal("com.googlecode.iterm2"))
        XCTAssertTrue(TerminalPasteTargets.isTerminal("com.mitchellh.ghostty"))
        XCTAssertTrue(TerminalPasteTargets.isTerminal("net.kovidgoyal.kitty"))
        XCTAssertTrue(TerminalPasteTargets.isTerminal("com.github.wez.wezterm"))
        XCTAssertTrue(TerminalPasteTargets.isTerminal("org.alacritty"))
    }

    func testDoesNotClaimNonTerminalsOrMissingBundleIdentifiers() {
        XCTAssertFalse(TerminalPasteTargets.isTerminal("com.apple.TextEdit"))
        XCTAssertFalse(TerminalPasteTargets.isTerminal("com.example.Editor"))
        XCTAssertFalse(TerminalPasteTargets.isTerminal(""))
        XCTAssertFalse(TerminalPasteTargets.isTerminal(nil))
    }

    func testStripsAtMostOneTrailingNewlineAndKeepsInternalOnes() {
        XCTAssertEqual(TerminalPasteTargets.strippingSingleTrailingNewline("a\nb\n"), "a\nb")
        XCTAssertEqual(TerminalPasteTargets.strippingSingleTrailingNewline("a\nb\r\n"), "a\nb")
        XCTAssertEqual(TerminalPasteTargets.strippingSingleTrailingNewline("a\nb\r"), "a\nb")
        XCTAssertEqual(TerminalPasteTargets.strippingSingleTrailingNewline("a\nb\n\n"), "a\nb\n")
        XCTAssertEqual(TerminalPasteTargets.strippingSingleTrailingNewline("a\nb"), "a\nb")
        XCTAssertEqual(TerminalPasteTargets.strippingSingleTrailingNewline(""), "")
        XCTAssertEqual(TerminalPasteTargets.strippingSingleTrailingNewline("\n"), "")
    }

    func testKeepsTrailingWhitespaceThatIsNotANewline() {
        // The 2026-09-06 specimens end with a space; only newlines are Return-shaped.
        XCTAssertEqual(
            TerminalPasteTargets.strippingSingleTrailingNewline("2. I went to the store. "),
            "2. I went to the store. "
        )
    }
}
