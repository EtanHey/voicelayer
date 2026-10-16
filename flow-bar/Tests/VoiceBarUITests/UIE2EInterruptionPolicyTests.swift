import XCTest

final class UIE2EInterruptionPolicyTests: XCTestCase {
    func testOwnQASheetIsNeverClassifiedAsForeign() {
        XCTAssertEqual(
            UIE2EInterruptionPolicy.classify(
                alertDescription: "Other at {{375, 539}, {332, 265}} from Application 'com.voicelayer.voicebar.uie2e'"
            ),
            .qaOwnedInterruption
        )
    }

    func testOnlyKnownBenignOwnersAreRecoverable() {
        XCTAssertEqual(
            UIE2EInterruptionPolicy.classify(
                alertDescription: "Dialog from Application 'com.t3tools.t3code'"
            ),
            .knownBenignForeign(owner: "com.t3tools.t3code")
        )
        XCTAssertEqual(
            UIE2EInterruptionPolicy.classify(
                alertDescription: "Dialog from Application 'com.example.unknown'"
            ),
            .unknown(owner: "com.example.unknown")
        )
    }

    func testPermissionPromptAlwaysBlocksEvenWhenOwnerLooksBenign() {
        XCTAssertEqual(
            UIE2EInterruptionPolicy.classify(
                alertDescription: "Enable UI Automation: Application 'com.t3tools.t3code' would like permission"
            ),
            .permissionPrompt
        )
    }

    func testNonrunningOrUnknownForeignAppNeverQueriesItsHierarchy() {
        for state in [UIE2EInterruptionProcessState.notRunning, .unknown] {
            var queried = false
            let result = UIE2EInterruptionPolicy.queryHierarchyIfRunning(state: state) {
                queried = true
                return true
            }

            XCTAssertNil(result)
            XCTAssertFalse(queried, "A foreign AX query must not run for state \(state)")
        }
    }

    func testRunningBenignAppMayBeInspectedAndReactivatedOnlyAfterMatch() {
        var queried = false
        let result = UIE2EInterruptionPolicy.queryHierarchyIfRunning(state: .running) {
            queried = true
            return true
        }

        XCTAssertTrue(queried)
        XCTAssertEqual(result, true)
    }

    func testUIMonitorUsesClassificationAndStateGateBeforeForeignAXQuery() throws {
        let flowTests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UIE2E/VoiceBarUIE2ETests/VoiceBarFlowTests.swift")
        let source = try String(contentsOf: flowTests)
        let monitorStart = try XCTUnwrap(source.range(of: "addUIInterruptionMonitor("))
        let monitorEnd = try XCTUnwrap(source[monitorStart.upperBound...].range(of: "step(\"launch isolated QA app\")"))
        let monitor = source[monitorStart.lowerBound..<monitorEnd.lowerBound]

        XCTAssertTrue(monitor.contains("UIE2EInterruptionPolicy.classify"))
        XCTAssertTrue(monitor.contains("case .qaOwnedInterruption"))
        XCTAssertTrue(monitor.contains("queryHierarchyIfRunning"))
        let ownAppCase = try XCTUnwrap(monitor.range(of: "case .qaOwnedInterruption"))
        let state = try XCTUnwrap(monitor.range(of: "let foreignState = foreign.state"))
        let foreignQuery = try XCTUnwrap(monitor.range(of: "foreign.dialogs.allElementsBoundByIndex"))
        let reactivateQA = try XCTUnwrap(monitor.range(of: "self.app.activate()"))
        XCTAssertLessThan(ownAppCase.lowerBound, foreignQuery.lowerBound,
            "QA-owned sheets must be handled before the benign-foreign branch")
        XCTAssertLessThan(state.lowerBound, foreignQuery.lowerBound,
            "The foreign application state must be read before any hierarchy query")
        XCTAssertLessThan(foreignQuery.lowerBound, reactivateQA.lowerBound,
            "Re-activate QA only after the running benign owner matched the interruption frame")
    }
}
