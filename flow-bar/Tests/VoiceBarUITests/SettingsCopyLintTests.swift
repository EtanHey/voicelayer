import Foundation
@testable import VoiceBarUI
import XCTest

final class SettingsCopyLintTests: XCTestCase {
    private let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    func testNoUIStringLiteralUsesAnEmDashASpacedEnDashOrThreeDots() throws {
        var scanned = 0
        var violations: [String] = []
        for target in ["VoiceBarUI", "VoiceBar"] {
            let directory = sourcesRoot.appendingPathComponent(target)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
            for file in files {
                scanned += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                let name = "\(target)/\(file.lastPathComponent)"
                violations += SwiftStringLiteralScanner.literals(in: source)
                    .filter { !$0.isLogText }
                    .flatMap { literal in
                        UICopyRule.violations(in: literal.text).map { "\(name):\(literal.line) \($0): \(literal.text)" }
                    }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the lint must actually read the VoiceBar sources")
        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    func testTheRuleCatchesEachPunctuationMistake() {
        XCTAssertEqual(UICopyRule.violations(in: "Voice is busy — wait"), ["em dash"])
        XCTAssertEqual(UICopyRule.violations(in: "Voice is busy – wait"), ["en dash as punctuation"])
        XCTAssertEqual(UICopyRule.violations(in: "Loading history..."), ["three dots"])
        XCTAssertEqual(UICopyRule.violations(in: "Wait... then retry"), ["three dots"])
        XCTAssertEqual(UICopyRule.violations(in: "Loading history…"), [])
        XCTAssertEqual(UICopyRule.violations(in: "Pages 1–5"), [], "an en dash in a range is correct")
        XCTAssertEqual(UICopyRule.violations(in: "–"), [], "a bare bullet token is not prose")
    }

    func testTheScannerFindsAnEmDashWhereverAUIStringCanHideIt() {
        let source = #"""
        Text("Busy — wait")
        let tip = "Done \("inner — nested")"
        let escaped = "Busy \u{2014} wait"
        let block = """
            Line — two
            """
        """#
        let flagged = SwiftStringLiteralScanner.literals(in: source)
            .filter { !$0.isLogText && UICopyRule.violations(in: $0.text).contains("em dash") }
            .map(\.line)
        XCTAssertEqual(flagged, [1, 2, 3, 4])
    }

    func testTheScannerSkipsCommentsAndLogText() {
        let source = #"""
        // Comment — not shown
        /* Block — /* nested — */ still a comment */
        NSLog(
            "[VoiceBar] Hotkey system unavailable — missing permissions: %@",
            names.map { "\($0) — name" }
        )
        HotkeyDiagnostics.log("[HotkeyManager] letting it through "
            + "because a gesture is active — unwinding hold")
        Self.logger.error("socket — closed")
        heartbeatGapLogger("gap — \(seconds)")
        public static let activationLogMessage = "[VoiceBar] Hotkey system active — primary shortcut is F5"
        print("debug — only")
        Text("Shown — here")
        """#
        let shown = SwiftStringLiteralScanner.literals(in: source).filter { !$0.isLogText }.map(\.text)
        XCTAssertEqual(shown, ["Shown — here"])
    }

    func testRawStringsAndEscapedQuotesStayOneLiteral() {
        let source = ##"""
        let raw = #"He said "hi" — then left"#
        let quoted = "a \"quoted\" word — here"
        """##
        let literals = SwiftStringLiteralScanner.literals(in: source)
        XCTAssertEqual(literals.map(\.text), [#"He said "hi" — then left"#, #"a "quoted" word — here"#])
    }
}

enum UICopyRule {
    static func violations(in text: String) -> [String] {
        var found: [String] = []
        if text.contains("\u{2014}") { found.append("em dash") }
        let characters = Array(text)
        let spacedEnDash = characters.indices.contains { index in
            characters[index] == "\u{2013}" && characters.count > 1
                && ((index > 0 && characters[index - 1].isWhitespace)
                    || (index + 1 < characters.count && characters[index + 1].isWhitespace))
        }
        if spacedEnDash { found.append("en dash as punctuation") }
        if text.contains("...") { found.append("three dots") }
        return found
    }
}

struct SwiftStringLiteral: Equatable {
    let line: Int
    let text: String
    let isLogText: Bool
}

enum SwiftStringLiteralScanner {
    private struct Call {
        let name: String
        var isLog: Bool {
            let components = name.split(separator: ".").map { $0.lowercased() }
            guard let callee = components.last else { return false }
            if ["nslog", "print", "debugprint", "os_log"].contains(callee) { return true }
            if callee.hasPrefix("log") || callee.hasSuffix("logger") { return true }
            return components.dropLast().contains { $0.hasSuffix("logger") }
        }
    }

    private struct CodeFrame {
        var calls: [Call] = []
        let endsInterpolation: Bool
    }

    private struct StringFrame {
        let line: Int
        let hashes: Int
        let isMultiline: Bool
        let isLog: Bool
        var text = ""
    }

    private enum Frame {
        case code(CodeFrame)
        case string(StringFrame)
    }

    static func literals(in source: String) -> [SwiftStringLiteral] {
        let characters = Array(source)
        var frames: [Frame] = [.code(CodeFrame(endsInterpolation: false))]
        var found: [SwiftStringLiteral] = []
        var line = 1
        var index = 0
        var binding = ""
        var lastSignificant: Character = "\n"

        func matches(_ pattern: String, at position: Int) -> Bool {
            let pattern = Array(pattern)
            guard position + pattern.count <= characters.count else { return false }
            return Array(characters[position ..< position + pattern.count]) == pattern
        }

        func isInsideLog() -> Bool {
            if binding.lowercased().hasSuffix("logmessage") { return true }
            return frames.contains { frame in
                if case let .code(code) = frame { return code.calls.contains(where: \.isLog) }
                if case let .string(string) = frame { return string.isLog }
                return false
            }
        }

        func identifierChain(endingBefore position: Int) -> String {
            var start = position
            while start > 0, characters[start - 1] == " " { start -= 1 }
            let end = start
            while start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber
                || characters[start - 1] == "_" || characters[start - 1] == "." { start -= 1 }
            return String(characters[start ..< end])
        }

        while index < characters.count {
            let character = characters[index]
            switch frames[frames.count - 1] {
            case var .code(code):
                if matches("//", at: index) {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                    continue
                }
                if matches("/*", at: index) {
                    var depth = 0
                    while index < characters.count {
                        if matches("/*", at: index) { depth += 1; index += 2; continue }
                        if matches("*/", at: index) { depth -= 1; index += 2; if depth == 0 { break }; continue }
                        if characters[index] == "\n" { line += 1 }
                        index += 1
                    }
                    continue
                }
                var hashes = 0
                while index + hashes < characters.count, characters[index + hashes] == "#" { hashes += 1 }
                if index + hashes < characters.count, characters[index + hashes] == "\"" {
                    let quote = index + hashes
                    let isMultiline = matches("\"\"\"", at: quote)
                    var start = quote + (isMultiline ? 3 : 1)
                    let startLine = line
                    if isMultiline {
                        while start < characters.count, characters[start] != "\n" { start += 1 }
                        start += 1
                        line += 1
                    }
                    frames.append(.string(StringFrame(line: startLine, hashes: hashes, isMultiline: isMultiline,
                                                      isLog: isInsideLog())))
                    index = start
                    continue
                }
                if character.isLetter || character == "_" {
                    var end = index
                    while end < characters.count, characters[end].isLetter || characters[end].isNumber
                        || characters[end] == "_" { end += 1 }
                    let word = String(characters[index ..< end])
                    if word == "let" || word == "var" {
                        var next = end
                        while next < characters.count, characters[next] == " " { next += 1 }
                        var nameEnd = next
                        while nameEnd < characters.count, characters[nameEnd].isLetter
                            || characters[nameEnd].isNumber || characters[nameEnd] == "_" { nameEnd += 1 }
                        binding = String(characters[next ..< nameEnd])
                    }
                    lastSignificant = characters[end - 1]
                    index = end
                    continue
                }
                switch character {
                case "(":
                    code.calls.append(Call(name: identifierChain(endingBefore: index)))
                    frames[frames.count - 1] = .code(code)
                case ")":
                    if code.calls.isEmpty, code.endsInterpolation {
                        frames.removeLast()
                        index += 1
                        continue
                    }
                    _ = code.calls.popLast()
                    frames[frames.count - 1] = .code(code)
                case "\n":
                    line += 1
                    if code.calls.isEmpty, !["=", "+", ",", "(", "?", ":"].contains(lastSignificant) { binding = "" }
                default:
                    break
                }
                if !character.isWhitespace { lastSignificant = character }
                index += 1

            case var .string(string):
                let delimiter = (string.isMultiline ? "\"\"\"" : "\"") + String(repeating: "#", count: string.hashes)
                if matches(delimiter, at: index) {
                    if string.isMultiline {
                        let lines = string.text.split(separator: "\n", omittingEmptySubsequences: false)
                        let indent = lines.last.map { $0.prefix { $0 == " " }.count } ?? 0
                        string.text = lines.dropLast().map { String($0.dropFirst(indent)) }.joined(separator: "\n")
                    }
                    frames.removeLast()
                    found.append(SwiftStringLiteral(line: string.line, text: string.text, isLogText: string.isLog))
                    index += delimiter.count
                    lastSignificant = "\""
                    continue
                }
                let escape = "\\" + String(repeating: "#", count: string.hashes)
                if matches(escape, at: index) {
                    let next = index + escape.count
                    if next < characters.count, characters[next] == "(" {
                        frames[frames.count - 1] = .string(string)
                        frames.append(.code(CodeFrame(endsInterpolation: true)))
                        index = next + 1
                        continue
                    }
                    if matches("u{", at: next), let close = characters[next...].firstIndex(of: "}"),
                       let scalar = UInt32(String(characters[next + 2 ..< close]), radix: 16).flatMap(Unicode.Scalar.init) {
                        string.text.append(Character(scalar))
                        index = close + 1
                    } else if next < characters.count {
                        let escaped = characters[next]
                        if escaped == "\n" { line += 1 }
                        string.text.append(["n": "\n", "t": "\t", "0": "\0", "r": "\r"][escaped] ?? escaped)
                        index = next + 1
                    } else {
                        index = next
                    }
                    frames[frames.count - 1] = .string(string)
                    continue
                }
                if character == "\n" { line += 1 }
                string.text.append(character)
                frames[frames.count - 1] = .string(string)
                index += 1
            }
        }
        return found
    }
}
