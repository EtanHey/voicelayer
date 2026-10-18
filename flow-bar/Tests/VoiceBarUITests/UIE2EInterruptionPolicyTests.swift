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

    func testUIMonitorLatchesStopOnForeignInterruptionAndNeverRecovers() throws {
        // GATECAP1 R4 (lead ruling): a foreign interruption latches a STOP; the runner never
        // reactivates QA, queries the foreign hierarchy, presses anything, or continues.
        let flowTests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UIE2E/VoiceBarUIE2ETests/VoiceBarFlowTests.swift")
        let source = try String(contentsOf: flowTests)
        let monitorStart = try XCTUnwrap(source.range(of: "addUIInterruptionMonitor("))
        let monitorEnd = try XCTUnwrap(source[monitorStart.upperBound...].range(of: "step(\"launch isolated QA app\")"))
        let monitor = String(source[monitorStart.lowerBound..<monitorEnd.lowerBound])

        // Every classification is handled, and every path latches the STOP before returning.
        XCTAssertTrue(monitor.contains("UIE2EInterruptionPolicy.classify"))
        for kind in ["case .permissionPrompt", "case .qaOwnedInterruption", "case .knownBenignForeign", "case .unknown"] {
            XCTAssertTrue(monitor.contains(kind), "Unhandled interruption classification: \(kind)")
        }
        let latch = try XCTUnwrap(monitor.range(of: "self.latchForeignStop("))
        let handled = try XCTUnwrap(monitor.range(of: "return true"))
        XCTAssertLessThan(latch.lowerBound, handled.lowerBound, "STOP must be latched before the interruption is reported handled")
        XCTAssertFalse(monitor.contains("return false"), "An unhandled interruption lets an implicit handler dismiss it")
        // Only a redacted description is ever logged.
        XCTAssertTrue(monitor.contains("uie2eRedacted(alert.debugDescription)"))
        XCTAssertFalse(monitor.contains("\\(alert.debugDescription)"), "Raw foreign descriptions must never be logged")
        // No recover-and-continue: no QA reactivation, foreign AX query, or interaction.
        for forbidden in ["activate()", "queryHierarchyIfRunning", "foreign.dialogs", ".click()", ".tap()", "isHittable"] {
            XCTAssertFalse(monitor.contains(forbidden), "Interruption monitor must not recover or interact: \(forbidden)")
        }

        // The latch is permanent: once set it is never cleared, and every later boundary refuses.
        let latchBody = try XCTUnwrap(source.range(of: "    func latchForeignStop(_ reason: String) {"))
        let latchFunction = String(source[latchBody.lowerBound...].prefix(600))
        XCTAssertTrue(latchFunction.contains("guard foreignModalStop == nil else { return }"))
        XCTAssertTrue(latchFunction.contains("foreignModalStop = reason"))
        XCTAssertTrue(latchFunction.contains("XCTFail("))
        let boundary = try XCTUnwrap(source.range(of: "    func boundaryClear(_ kind: String) -> Bool {"))
        XCTAssertTrue(String(source[boundary.lowerBound...].prefix(400)).contains("guard foreignModalStop == nil else { return false }"),
                      "A latched STOP must refuse every later action, command and still")
        XCTAssertFalse(source.contains("foreignModalStop = nil"), "The STOP latch must never be cleared")
    }
}
