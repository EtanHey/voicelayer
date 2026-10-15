import Foundation
import XCTest

final class UIE2ECoverageLedgerTests: XCTestCase {
    func testDictationPasteNeverCoversAskResponsePaste() {
        var ledger = UIE2ECoverageLedger()
        let dictation = UIE2EControlContext(page: "History", scope: "Dictations", row: "qa-recording")
        let ask = UIE2EControlContext(page: "History", scope: "Ask", row: "qa-ask-response")
        let dictationKey = ledger.key(role: "button", identity: "Paste transcript", context: dictation)
        let askKey = ledger.key(role: "button", identity: "Paste transcript", context: ask)
        ledger.observed = [dictationKey, askKey]
        ledger.exercised = [dictationKey]
        XCTAssertNotEqual(dictationKey, askKey)
        XCTAssertEqual(ledger.missing, [askKey])
        ledger.exercised.insert(askKey)
        XCTAssertTrue(ledger.missing.isEmpty)
    }

    func testRowsAndProfilesRemainSeparate() {
        let ledger = UIE2ECoverageLedger()
        let contexts = [
            UIE2EControlContext(page: "History", scope: "Dictations", row: "qa-recording"),
            UIE2EControlContext(page: "History", scope: "Dictations", row: "qa-older"),
            UIE2EControlContext(page: "Speech", profile: "short"),
            UIE2EControlContext(page: "Speech", profile: "long"),
        ]
        XCTAssertEqual(Set(contexts.map { ledger.key(role: "button", identity: "Copy", context: $0) }).count, 4)
    }

    func testAskFlowHasItsOwnExactPayloadPasteAssertion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("UIE2E/VoiceBarUIE2ETests/VoiceBarFlowTests.swift"))
        let start = try XCTUnwrap(source.range(of: "open Ask history scope"))
        let rest = source[start.lowerBound...]
        XCTAssertTrue(rest.contains("assertHistoryPaste(\"QA response\")"))
    }
}
