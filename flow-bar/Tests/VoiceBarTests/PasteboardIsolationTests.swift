import Foundation
import XCTest

final class PasteboardIsolationTests: XCTestCase {
    // These targets have no live-clipboard opt-in. Reject acquiring the general board,
    // including reads: saving/restoring it still races the user's clipboard owner.
    private static func generalPasteboardReferences(in source: String) -> [Int] {
        let patterns = [
            #"NSPasteboard\s*\.\s*general\b"#,
            #"NSPasteboard\s*\(\s*name\s*:\s*\.general\b"#,
            #"NSPasteboard(?:\.Name)?\s*=\s*\.general\b"#,
            #"pasteboard\s*:\s*\.general\b"#,
        ]
        let range = NSRange(source.startIndex..., in: source)
        let lines = patterns.flatMap { pattern in
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.matches(in: source, range: range).map { match in
                let start = String.Index(utf16Offset: match.range.location, in: source)
                return source[..<start].filter { $0 == "\n" }.count + 1
            }
        }
        return Array(Set(lines)).sorted()
    }

    func testGeneralBoardAcquisitionGuardRejectsAliasesAndInjectedGeneralBoard() {
        let type = "NS" + "Pasteboard"
        for source in [
            "let board = \(type).general",
            "let board = \(type) . general",
            "let board = \(type)\n .general",
            "let board = \(type)(name: .general)",
            "let board: \(type) = .general",
            "let name: \(type).Name = .general",
            "let state = VoiceState(pasteboard: " + ".general)",
        ] {
            XCTAssertEqual(Self.generalPasteboardReferences(in: source), [1], source)
        }
        XCTAssertEqual(Self.generalPasteboardReferences(in: "let board = \(type).withUniqueName()"), [])
        XCTAssertEqual(Self.generalPasteboardReferences(in: "let tab = SettingsTab.general"), [])
    }

    func testVoiceBarTestTargetsNeverAcquireTheUsersGeneralPasteboard() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var violations: [String] = []
        for target in ["VoiceBarTests", "VoiceBarUITests"] {
            let root = tests.appendingPathComponent(target)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for line in Self.generalPasteboardReferences(in: source) {
                    violations.append("\(target)/\(file.lastPathComponent):\(line)")
                }
            }
        }
        XCTAssertEqual(violations, [], "Use a private uniquely named pasteboard and inject it: \(violations)")
    }
}
