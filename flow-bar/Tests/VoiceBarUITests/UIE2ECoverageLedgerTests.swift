import Foundation
import XCTest

final class UIE2ECoverageLedgerTests: XCTestCase {
    func testExplicitDictionarySheetControlDoesNotScrollSettingsOnSameLabelCollision() {
        // Edit-sheet Cancel and inline-delete Cancel share a label. The sheet
        // target is explicitly scoped, even while Settings contains a match.
        XCTAssertFalse(UIE2ERevealRouting.shouldReveal(
            isHittable: false,
            isMenuItem: false,
            settingsContainsMatchingControl: true,
            policy: .explicitlyScoped
        ))
    }

    func testOffscreenSettingsOwnedControlStillUsesSettingsReveal() {
        XCTAssertTrue(UIE2ERevealRouting.shouldReveal(
            isHittable: false,
            isMenuItem: false,
            settingsContainsMatchingControl: true,
            policy: .automatic
        ))
        XCTAssertFalse(UIE2ERevealRouting.shouldReveal(
            isHittable: true,
            isMenuItem: false,
            settingsContainsMatchingControl: true,
            policy: .automatic
        ))
        XCTAssertFalse(UIE2ERevealRouting.shouldReveal(
            isHittable: false,
            isMenuItem: true,
            settingsContainsMatchingControl: true,
            policy: .automatic
        ))
    }

    func testDictionarySheetRoutingPreservesReachabilityAndDismissalAssertions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("UIE2E/VoiceBarUIE2ETests/VoiceBarFlowTests.swift"))
        let clickStart = try XCTUnwrap(source.range(of: "func click(_ resolve:"))
        let clickEnd = try XCTUnwrap(source[clickStart.upperBound...].range(of: "    func tab("))
        let click = source[clickStart.lowerBound..<clickEnd.lowerBound]
        XCTAssertTrue(click.contains("UIE2ERevealRouting.shouldReveal"))
        XCTAssertTrue(click.contains("element.isEnabled, element.isHittable"), "A no-scroll route must still reject unreachable controls")

        let sheetStart = try XCTUnwrap(source.range(of: "func clickDictionarySheetButton("))
        let sheetEnd = try XCTUnwrap(source[sheetStart.upperBound...].range(of: "    func assertTerm("))
        let sheet = source[sheetStart.lowerBound..<sheetEnd.lowerBound]
        XCTAssertTrue(sheet.contains("revealPolicy: .explicitlyScoped"), "Sheet controls must bypass Settings scrolling")
        XCTAssertTrue(sheet.contains("waitForDictionarySheetStable"))
        XCTAssertTrue(sheet.contains("dictionaryEditSheet() == nil"), "The action still requires sheet dismissal")

        let dictionaryStart = try XCTUnwrap(source.range(of: "func dictionaryFlow()"))
        let dictionaryEnd = try XCTUnwrap(source[dictionaryStart.upperBound...].range(of: "    func speechFlow()"))
        let dictionary = source[dictionaryStart.lowerBound..<dictionaryEnd.lowerBound]
        XCTAssertTrue(dictionary.contains("replace(dictionarySheetControl(.textField, label: \"Correct spelling\"), \"QA initial\")"))
        XCTAssertTrue(dictionary.contains("replace(dictionarySheetControl(.textField, label: \"Misheard as\"), \"qa kept variant\")"))
        XCTAssertTrue(dictionary.contains("Remove misheard spelling initial variant"))
        XCTAssertTrue(dictionary.contains("clickDictionarySheetButton(\"Save\")"))
        XCTAssertTrue(dictionary.contains(#"assertTerm("QA initial", variants: ["qa kept variant"])"#))
        let initialSaved = try XCTUnwrap(dictionary.range(of: #"assertTerm("QA initial", variants: ["qa kept variant"])"#))
        let afterInitialSave = dictionary[initialSaved.upperBound...]
        let reopen = try XCTUnwrap(afterInitialSave.range(of: #"click(app.buttons["Edit term QA initial"])"#))
        let afterReopen = afterInitialSave[reopen.upperBound...]
        let cancel = try XCTUnwrap(afterReopen.range(of: #"clickDictionarySheetButton("Cancel")"#))
        let afterCancel = afterReopen[cancel.upperBound...]
        let persistedAfterCancel = try XCTUnwrap(afterCancel.range(of: #"assertTerm("QA initial", variants: ["qa kept variant"])"#))
        XCTAssertLessThan(reopen.lowerBound, cancel.lowerBound)
        XCTAssertLessThan(cancel.lowerBound, persistedAfterCancel.lowerBound)
    }

    func testFocusedScopeCannotSatisfyTheFullSurfaceGate() {
        var focused = UIE2ECoverageLedger()
        focused.requiredScope = ["338:paste-feedback", "338:busy"]
        focused.verifiedSurfaces = ["338:paste-feedback"]
        XCTAssertEqual(focused.missingSurfaces, ["338:busy"])
        let full = UIE2ECoverageLedger()
        XCTAssertTrue(full.missingSurfaces.contains("Speech"))
        XCTAssertFalse(focused.recordExpected(surface: "notch:list-newlines", issue: .listNewlines,
            descriptions: ["[P14b] unrelated known issue"]))
    }

    func testGalleryRequiresVisibleUnclippedTextAndSeparatePanels() {
        let panels = ["first": CGRect(x: 20, y: 30, width: 400, height: 160),
                      "second": CGRect(x: 440, y: 30, width: 400, height: 160)]
        // Deliberately synthetic overflow stress text; this is not current product copy.
        let text = "Insertion unverified — transcript kept in History. Check the input before retrying or Copy."
        XCTAssertTrue(UIE2EGalleryFrames.problems(panels: panels,
            texts: ["first": CGRect(x: 35, y: 45, width: 365, height: 90),
                    "second": CGRect(x: 455, y: 45, width: 365, height: 90)],
            expected: ["first": text, "second": "QA terminal"],
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600)).isEmpty)
        XCTAssertFalse(UIE2EGalleryFrames.problems(panels: panels,
            texts: ["first": CGRect(x: 35, y: 45, width: 90, height: 15)],
            expected: ["first": text, "second": "QA terminal"],
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600)).isEmpty,
            "Full AX content must not hide clipped text or a missing sibling state")
        XCTAssertFalse(UIE2EGalleryFrames.problems(panels: ["first": panels["first"]!, "second": panels["first"]!],
            texts: ["first": CGRect(x: 35, y: 45, width: 100, height: 20),
                    "second": CGRect(x: 35, y: 45, width: 100, height: 20)],
            expected: ["first": "QA", "second": "QA"],
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600)).isEmpty)
    }

    func testGalleryCreditsEachVariantWithoutMaskingItsClippedSibling() {
        let panels = ["recovery": CGRect(x: 20, y: 30, width: 300, height: 100),
                      "terminal": CGRect(x: 340, y: 30, width: 300, height: 100)]
        let text = ["recovery": "Unverified\nIn History", "terminal": "QA terminal transcript שלום 👋"]
        let frames = ["recovery": CGRect(x: 30, y: 40, width: 100, height: 30),
                      "terminal": CGRect(x: 350, y: 40, width: 90, height: 15)]
        XCTAssertEqual(UIE2EGalleryFrames.verifiedIDs(panels: panels, texts: frames, expected: text,
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600)), ["recovery"])
        XCTAssertTrue(UIE2EGalleryFrames.verifiedIDs(panels: ["recovery": panels["recovery"]!, "terminal": panels["recovery"]!],
            texts: ["recovery": frames["recovery"]!, "terminal": frames["recovery"]!],
            expected: ["recovery": text["recovery"]!, "terminal": text["recovery"]!],
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600)).isEmpty,
            "Overlapping panels cannot earn individual visual coverage")
    }

    func testHistoryHitUsesTheRenderedLeadingTextRatherThanTheWideSpacer() {
        for frame in [CGRect(x: 265, y: 516, width: 623, height: 50), CGRect(x: 275, y: 577, width: 138, height: 32)] {
            let point = UIE2EHistoryGeometry.selectionOffset(in: frame)
            XCTAssertTrue(CGRect(x: 28, y: 2, width: 100, height: 18).contains(CGPoint(x: point.dx, y: point.dy)),
                "A duration label can widen AX across an inert Spacer; click the leading text")
        }
    }
    func testAskActionsStayInsideTheirOwnPayloadInterval() {
        let first = CGRect(x: 300, y: 600, width: 500, height: 20)
        let loaded = CGRect(x: 300, y: 760, width: 500, height: 20)
        let copies = [CGRect(x: 330, y: 625, width: 20, height: 20), CGRect(x: 330, y: 800, width: 20, height: 20)]
        XCTAssertEqual(UIE2EHistoryGeometry.actionIndex(after: first, before: loaded.minY, candidates: copies), 0)
        XCTAssertEqual(UIE2EHistoryGeometry.actionIndex(after: loaded, before: nil, candidates: copies), 1)
        XCTAssertNil(UIE2EHistoryGeometry.actionIndex(after: first, before: loaded.minY, candidates: [copies[1]]),
            "A missing first-row action must not borrow the loaded row")
        XCTAssertNil(UIE2EHistoryGeometry.actionIndex(after: loaded, before: nil, candidates: [copies[1], copies[1]]))
        XCTAssertNil(UIE2EHistoryGeometry.actionIndex(after: .zero, before: nil, candidates: copies))
    }

    func testFullAXTextCannotProveThatAOneLineFeedbackFrameIsReadable() {
        // Deliberately synthetic overflow stress text; this is not current product copy.
        let text = "Insertion unverified — transcript kept in History. Check the input before retrying or Copy."
        XCTAssertFalse(UIE2EFeedbackFrame.isReadable(text: text, frame: CGRect(x: 0, y: 0, width: 90, height: 15)))
        XCTAssertTrue(UIE2EFeedbackFrame.isReadable(text: text, frame: CGRect(x: 0, y: 0, width: 700, height: 30)))
        XCTAssertFalse(UIE2EFeedbackFrame.isReadable(text: text, frame: .zero))
    }

    func testTwoLineRecoveryMustHaveSpaceForBothLines() {
        for text in ["Not pasted\nIn History", "Unverified\nIn History", "Part pasted\nHistory: full"] {
            XCTAssertFalse(UIE2EFeedbackFrame.isReadable(text: text,
                frame: CGRect(x: 0, y: 0, width: 130, height: 15)))
            XCTAssertTrue(UIE2EFeedbackFrame.isReadable(text: text,
                frame: CGRect(x: 0, y: 0, width: 130, height: 30)))
        }
    }

    func testSelectionFeedbackWaiverRequiresP1fAndActualFailure() {
        var ledger = UIE2ECoverageLedger()
        ledger.requiredScope = ["338:static:selection-copy-empty"]
        XCTAssertFalse(ledger.recordExpected(surface: "338:static:selection-copy-empty", issue: .selectionFeedback,
            descriptions: ["Missing/unreachable gallery control"]))
        XCTAssertTrue(ledger.recordExpected(surface: "338:static:selection-copy-empty", issue: .selectionFeedback,
            descriptions: ["[P1f] full error text cannot fit its visible frame"]))
        XCTAssertTrue(ledger.missingSurfaces.isEmpty)
    }

    func testTerminalMayShowAnEllipsizedPreviewOnlyWhenFullTextIsVisibleInCard() {
        let full = "QA terminal transcript שלום 👋"
        let panel = CGRect(x: 0, y: 0, width: 489, height: 115)
        XCTAssertTrue(UIE2ETerminalPreview.isProven(fullText: full,
            previewFrame: CGRect(x: 380, y: 90, width: 98, height: 15),
            fullFrame: CGRect(x: 20, y: 10, width: 300, height: 20), panel: panel))
        XCTAssertFalse(UIE2ETerminalPreview.isProven(fullText: full, previewFrame: .zero,
            fullFrame: CGRect(x: 20, y: 10, width: 300, height: 20), panel: panel))
        XCTAssertFalse(UIE2ETerminalPreview.isProven(fullText: full,
            previewFrame: CGRect(x: 380, y: 90, width: 98, height: 15), fullFrame: .zero, panel: panel))
        XCTAssertFalse(UIE2ETerminalPreview.isProven(fullText: full,
            previewFrame: CGRect(x: 380, y: 90, width: 98, height: 15),
            fullFrame: CGRect(x: 20, y: 10, width: 60, height: 15), panel: panel))
    }


    func testFeedbackMatchesNativeStaticTextValueWithoutReadingNumericControlValues() {
        let predicate = UIE2EAXText.predicate("Pasted", staticTextRole: 48)
        XCTAssertTrue(predicate.evaluate(with: ["label": "", "value": "Pasted", "elementType": 48]))
        XCTAssertTrue(predicate.evaluate(with: ["label": "Pasted", "value": 1, "elementType": 9]))
        XCTAssertFalse(predicate.evaluate(with: ["label": "", "value": 1, "elementType": 9]))
        XCTAssertFalse(predicate.evaluate(with: ["label": "", "value": "Pasted", "elementType": 9]))
    }

    func testSelectableTextViewValueMatchesFullPayloadWithoutLabel() {
        let payload = "QA terminal transcript שלום 👋"
        // XCUIElement.ElementType.textView has raw value 52; selectable SwiftUI
        // Text can be exposed as a text view while leaving its AX label blank.
        let predicate = UIE2EAXText.predicate(payload, staticTextRole: 48, additionalTextRoles: [52])
        XCTAssertTrue(predicate.evaluate(with: ["label": "", "value": payload, "elementType": 52]))
        XCTAssertFalse(predicate.evaluate(with: ["label": "", "value": 1, "elementType": 9]))
        XCTAssertFalse(predicate.evaluate(with: ["label": "", "value": payload, "elementType": 9]))
    }

    func testRadioScopeSelectionAcceptsTheNativeNumericAXValue() {
        XCTAssertTrue(UIE2EAXSelection.isSelected(flag: false, value: NSNumber(value: 1)))
        XCTAssertFalse(UIE2EAXSelection.isSelected(flag: false, value: NSNumber(value: 0)))
        XCTAssertTrue(UIE2EAXSelection.isSelected(flag: false, value: "1"))
        XCTAssertTrue(UIE2EAXSelection.isSelected(flag: true, value: nil))
        XCTAssertFalse(UIE2EAXSelection.isSelected(flag: false, value: nil))
    }

    func testStableScrollInMiddleCannotProveAnEdge() {
        XCTAssertFalse(UIE2EScrollEdge.reached(0.5, direction: -1))
        XCTAssertFalse(UIE2EScrollEdge.reached(0, direction: -1))
        XCTAssertTrue(UIE2EScrollEdge.reached(1, direction: -1))
        XCTAssertTrue(UIE2EScrollEdge.reached(0, direction: 1))
        XCTAssertFalse(UIE2EScrollEdge.reached(.nan, direction: 1))
    }

    func testGeometryDetectsReplayRestartShiftAndRowResize() {
        let baseline = UIE2EControlGeometry(replay: CGRect(x: 100, y: 20, width: 20, height: 20),
            eye: CGRect(x: 130, y: 20, width: 20, height: 20), terminal: CGRect(x: 160, y: 20, width: 20, height: 20),
            row: CGRect(x: 100, y: 20, width: 80, height: 20))
        XCTAssertTrue(baseline.differences(from: baseline).isEmpty)
        var restarted = baseline
        restarted.replay.origin.x += 12
        restarted.row.size.width += 12
        XCTAssertEqual(Set(restarted.differences(from: baseline)), ["Replay.x", "row.width"])
        restarted = baseline
        restarted.terminal.origin.x -= 6
        XCTAssertEqual(restarted.differences(from: baseline), ["terminal.x"])
    }

    func testEmptyControlInventoryCannotProveFullFlowCoverage() {
        let ledger = UIE2ECoverageLedger()
        XCTAssertTrue(ledger.missing.isEmpty)
        XCTAssertEqual(ledger.missingSurfaces, UIE2ECoverageLedger.requiredSurfaces)
        XCTAssertTrue(ledger.missingSurfaces.contains("notch:seek-idle"))
        XCTAssertTrue(ledger.missingSurfaces.contains("notch:supersede-preparing"))
    }

    func testControlDispatchCannotDischargeARequiredSurface() {
        var ledger = UIE2ECoverageLedger()
        ledger.exercised.insert("click Dictionary")
        XCTAssertTrue(ledger.missingSurfaces.contains("Dictionary"))
        ledger.verifiedSurfaces.insert("Dictionary")
        XCTAssertFalse(ledger.missingSurfaces.contains("Dictionary"))
        XCTAssertTrue(ledger.missingSurfaces.contains("History"))
    }

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
