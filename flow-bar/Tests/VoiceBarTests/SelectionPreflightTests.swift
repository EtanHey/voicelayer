import ApplicationServices
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class SelectionPreflightTests: XCTestCase {
    private typealias Providers = SpeakSelectionCapture.PreflightProviders
    private let sentinel = "PRIVATE_selection_clipboard_type_title_שלום"

    // An inert handle only: no AX query, messaging, permissions or application interaction.
    private var focus: CFTypeRef { AXUIElementCreateApplication(0) }

    private func providers(_ failure: String? = nil, secure: @escaping () -> Bool = { false },
                           subrole: String? = nil) -> Providers {
        Providers(secureInput: secure, trusted: { failure != "ax_untrusted" }, focused: {
            switch failure {
            case "focus_query_failed": return (.cannotComplete, self.sentinel as CFString)
            case "focus_absent": return (.success, nil)
            case "focus_wrong_type": return (.success, self.sentinel as CFString)
            default: return (.success, self.focus)
            }
        }, attribute: { _, key in
            if key == kAXSubroleAttribute {
                return (.success, subrole.map { $0 as CFString })
            }
            XCTAssertEqual(key, kAXRoleAttribute)
            switch failure {
            case "role_query_failed": return (.attributeUnsupported, self.sentinel as CFString)
            case "role_absent": return (.success, nil)
            case "role_wrong_type": return (.success, NSNumber(value: 13))
            case "secure_role": return (.success, kAXSecureTextFieldSubrole as CFString)
            default: return (.success, self.sentinel as CFString)
            }
        })
    }

    func testEachDeniedGuardClassifiesBothStagesAndStopsFurtherWork() {
        let cases: [(String, AXError?)] = [
            ("ax_untrusted", nil), ("focus_query_failed", .cannotComplete),
            ("focus_absent", .success), ("focus_wrong_type", .success),
            ("role_query_failed", .attributeUnsupported), ("role_absent", .success),
            ("role_wrong_type", .success),
        ]
        for (reason, status) in cases {
            for recheck in [false, true] {
                var passes = 0
                var selections = 0
                var snapshots = 0
                var generations = 0
                let denied = providers(reason)
                let allowed = providers()
                let input = Providers(secureInput: { false }, trusted: {
                    passes += 1
                    return recheck && passes == 1 ? true : denied.trusted()
                }, focused: {
                    recheck && passes == 1 ? allowed.focused() : denied.focused()
                }, attribute: { element, key in
                    recheck && passes == 1 ? allowed.attribute(element, key) : denied.attribute(element, key)
                })
                let capture = SpeakSelectionCapture(preflight: input, snapshotReader: {
                    snapshots += 1
                    return []
                }, readAXSelection: { selections += 1; return nil }, postCopy: {
                    XCTFail("denied preflight must never Copy: \(reason)"); return self.unexpectedCopy()
                }, pasteboardChangeCount: { generations += 1; return 4 })
                let result = run(capture)
                XCTAssertEqual(result.outcome, .captureFailed, reason)
                XCTAssertNil(result.text)
                let fields = result.diagnosticDetails
                XCTAssertEqual(fields["preflight_stage"], recheck ? "recheck" : "initial", reason)
                XCTAssertEqual(fields["preflight_reason"], reason)
                XCTAssertEqual(fields["preflight_ax_status"], status.map { String($0.rawValue) })
                XCTAssertEqual(fields["path"], recheck ? "copy" : "unknown")
                XCTAssertEqual(fields["ax_read"], recheck ? "unavailable" : "not_attempted")
                XCTAssertEqual(passes, recheck ? 2 : 1, "no preflight retry")
                XCTAssertEqual(selections, recheck ? 1 : 0)
                XCTAssertEqual(snapshots, recheck ? 1 : 0)
                XCTAssertEqual(generations, recheck ? 2 : 0)
                XCTAssertEqual(Set(fields.keys), Set(["outcome", "ax_read", "path", "host_structure",
                    "appKeyWindowTitle", "preflight_stage", "preflight_reason"] +
                    (status == nil ? [] : ["preflight_ax_status"])))
                XCTAssertFalse(fields.values.contains { $0.contains(sentinel) })
            }
        }
    }

    func testSecureInputRoleAndSubroleKeepSecurityPrecedence() {
        var secureChecks = 0
        let inputs: [(Providers, String)] = [
            (Providers(secureInput: { true }, trusted: { XCTFail("secure input precedes trust"); return false },
                focused: { XCTFail("must not query focus"); return (.failure, nil) },
                attribute: { _, _ in XCTFail("must not query role"); return (.failure, nil) }), "secure_input"),
            (providers("secure_role"), "secure_role"),
            (providers("role_query_failed", subrole: kAXSecureTextFieldSubrole), "secure_role"),
            (providers("role_absent", secure: { secureChecks += 1; return secureChecks == 2 }), "secure_input"),
        ]
        for (denied, reason) in inputs {
            for recheck in [false, true] {
                secureChecks = 0
                var secureReads = 0
                let allowed = providers()
                let input = Providers(secureInput: {
                    secureReads += 1
                    return recheck && secureReads <= 2 ? false : denied.secureInput()
                }, trusted: {
                    recheck && secureReads <= 2 ? true : denied.trusted()
                }, focused: {
                    recheck && secureReads <= 2 ? allowed.focused() : denied.focused()
                }, attribute: { element, key in
                    recheck && secureReads <= 2 ? allowed.attribute(element, key) : denied.attribute(element, key)
                })
                let result = run(SpeakSelectionCapture(preflight: input,
                    snapshotReader: { if !recheck { XCTFail("secure initial preflight must not snapshot") }; return [] },
                    readAXSelection: { if !recheck { XCTFail("secure initial preflight must not read selection") }; return nil },
                    postCopy: { XCTFail("secure preflight must not Copy"); return self.unexpectedCopy() },
                    pasteboardChangeCount: { if !recheck { XCTFail("must not inspect clipboard") }; return 0 }))
                XCTAssertEqual(result.outcome, .secureField)
                XCTAssertEqual(result.diagnosticDetails["preflight_reason"], reason)
                XCTAssertEqual(result.diagnosticDetails["preflight_stage"], recheck ? "recheck" : "initial")
            }
        }
    }

    func testAllowedFocusReachesExistingAXPathWithoutClipboardAndDoesNotLogPayload() {
        var reads = 0
        let result = run(SpeakSelectionCapture(preflight: providers(),
            snapshotReader: { XCTFail("AX text must not snapshot"); return nil },
            readAXSelection: { reads += 1; return self.sentinel },
            postCopy: { XCTFail("AX text must not Copy"); return self.unexpectedCopy() },
            pasteboardChangeCount: { XCTFail("AX text must not inspect clipboard"); return 0 }))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.text, sentinel)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.path, .ax)
        XCTAssertNil(result.diagnosticDetails["preflight_stage"])
        XCTAssertFalse(result.diagnosticDetails.values.contains { $0.contains(sentinel) })
    }

    func testSnapshotFailureAndGenerationChangeStillPrecedeRecheckFailure() {
        for snapshotFails in [true, false] {
            var checks = 0
            var generations = 0
            let input = providers(secure: { checks += 1; return checks == 3 })
            let result = run(SpeakSelectionCapture(preflight: input,
                snapshotReader: { snapshotFails ? nil : [] }, readAXSelection: { nil },
                postCopy: { XCTFail("failed snapshot/generation must not Copy"); return self.unexpectedCopy() },
                pasteboardChangeCount: { generations += 1; return generations }))
            XCTAssertEqual(checks, 3, "recheck still runs even if snapshot fails")
            XCTAssertEqual(result.outcome, snapshotFails ? .captureFailed : .clipboardChanged)
            XCTAssertNil(result.diagnosticDetails["preflight_stage"], "do not blame the lower-priority guard")
        }
    }

    private func unexpectedCopy() -> Bool {
        // Stop before copyAndPoll can restore/poll a real pasteboard on a regression.
        fatalError("Offline selection test crossed the Copy boundary")
    }

    private func run(_ capture: SpeakSelectionCapture) -> SelectionCaptureResult {
        let done = expectation(description: "one completion on main")
        done.assertForOverFulfill = true
        var result = SelectionCaptureResult.captureFailed
        capture.capture { value in
            XCTAssertTrue(Thread.isMainThread)
            result = value
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return result
    }
}
