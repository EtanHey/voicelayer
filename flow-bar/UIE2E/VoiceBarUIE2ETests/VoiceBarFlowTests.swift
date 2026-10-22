import AppKit
import CryptoKit
import XCTest

// BEGIN UIE2E BOUNDARY
// The sandboxed runner asks the owned boundary broker (voicebar-ui-e2e-permissions --broker) for a
// fresh, synchronous foreign-modal decision before each fixture command, UI action and still.
let uie2eBoundaryPrefix = "com.voicelayer.voicebar.uie2e.boundary."
func uie2eBoundaryName(token: String, kind: String) -> String { uie2eBoundaryPrefix + token + "." + kind }
func uie2eBoundaryAck(_ data: Data?) -> [String: Any]? {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["count"] is Int, object["kind"] is String, object["status"] is String else { return nil }
    return object
}
/// Only a fresh "clear" answer to exactly this request lets the boundary proceed.
func uie2eBoundaryClear(_ ack: [String: Any]?, count: Int, kind: String) -> Bool {
    ack?["count"] as? Int == count && ack?["kind"] as? String == kind && ack?["status"] as? String == "clear"
}
/// The step's frame receipt: a PROVEN window-ID capture of the proven QA process, or NOT_PROVEN.
func uie2eStillReceipt(_ ack: [String: Any]?, count: Int) -> [String: Any] {
    guard ack?["count"] as? Int == count, ack?["kind"] as? String == "still",
          let capture = ack?["capture"] as? [String: Any], let status = capture["status"] as? String else {
        return ["source": "qa-window-id", "status": "NOT_PROVEN", "reason": "no-broker-answer"]
    }
    guard status == "PROVEN", capture["path"] is String, let windows = capture["windows"] as? [Int], !windows.isEmpty else {
        var receipt: [String: Any] = ["source": "qa-window-id", "status": "NOT_PROVEN", "reason": capture["reason"] as? String ?? "unproven"]
        if let proof = capture["absenceProof"] as? [String: Any], uie2eAbsenceProven(proof) { receipt["absenceProof"] = proof }
        if let proof = capture["terminationProof"] as? [String: Any], uie2eTerminationProven(proof) { receipt["terminationProof"] = proof }
        return receipt
    }
    return ["source": "qa-window-id", "status": "PROVEN", "windows": windows, "qaPid": capture["qaPid"] ?? 0]
}
/// Expected hidden-alive cases, also checked against the explicit declarations at their call sites.
func uie2eExpectsHiddenQA(step name: String, scenario: String) -> Bool {
    guard ["hide1", "gate2246"].contains(scenario) else { return false }
    // The visual scenarios install their menu with every QA window ordered out.
    if ["launch isolated QA app", "relaunch isolated QA app"].contains(name)
        || (name.hasPrefix("GUARD launch ") && name.hasSuffix(" installed")) { return true }
    if ["HIDE1VIS", "GATE2246"].contains(where: { name == $0 + " no-device guard installed before fixtures"
        || name == $0 + " no device-start or process tripwire invoked" }) { return true }
    if name.hasPrefix("HIDE1VIS "), name.hasSuffix(" hidden") { return true }
    // Deferred failures keep every QA window hidden until Show; a dismissed immediate alert
    // leaves the snoozed panel hidden (except the "visible" case).
    if ["GATE2246 HIDE background failure", "GATE2246 HIDE recovered failure"].contains(name) { return true }
    if name.hasPrefix("GATE2246 HIDE "), name.hasSuffix(" dismiss Later"),
       !["GATE2246 HIDE visible dismiss Later", "GATE2246 HIDE background dismiss Later"].contains(name) { return true }
    return false
}
/// A positive expected-absent proof: a successful CG inventory with zero on-screen QA windows.
func uie2eInventoryProven(_ proof: [String: Any]?) -> Bool {
    guard let birth = proof?["qaBirth"] as? [Int], birth.count == 2, birth[0] > 0,
          (0..<1_000_000).contains(birth[1]) else { return false }
    return proof?["cgInventory"] as? String == "ok" && proof?["onScreenQAWindows"] as? Int == 0
        && proof?["qaPid"] as? Int ?? 0 > 0
}
func uie2eAbsenceProven(_ proof: [String: Any]?) -> Bool {
    uie2eInventoryProven(proof) && proof?["pidLifetime"] as? String == "alive"
}
func uie2eTerminationProven(_ proof: [String: Any]?) -> Bool {
    uie2eInventoryProven(proof) && proof?["pidLifetime"] as? String == "ended"
        && proof?["visibleOwnerPaths"] as? String == "non-qa"
}
/// Hidden-alive and terminated proofs are distinct; no declaration or failed read can pass.
func uie2eFrameFailure(_ capture: [String: Any], contract: String?) -> String? {
    guard let contract, ["visible", "hidden-alive", "terminated"].contains(contract) else { return "undeclared evidence contract" }
    if capture["status"] as? String == "PROVEN" { return contract == "terminated" ? "termination contract carries a window" : nil }
    let reason = capture["reason"] as? String ?? "unproven"
    let proven = contract == "hidden-alive" ? uie2eAbsenceProven(capture["absenceProof"] as? [String: Any])
        : contract == "terminated" && uie2eTerminationProven(capture["terminationProof"] as? [String: Any])
    return proven ? nil : "visual NOT_PROVEN for " + contract + " (" + reason + ")"
}
func uie2eRedacted(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    return "<redacted len=\(text.count) sha256=\(digest.prefix(8))>"
}
// END UIE2E BOUNDARY

/// The one serial UI test runs only through voicebar-ui-e2e.sh on an unoccupied Mac.
@MainActor
final class VoiceBarFlowTests: XCTestCase {
    var app: XCUIApplication!
    var root: URL!
    var steps: [[String: Any]] = []
    var completed = false
    var scenario = "full"
    var knownVisualGaps: [String] = []
    var limitations = ["NOT_PROVEN: external T3-client selection Speak is outside this isolated VoiceBar run. SEL1 probes the real VoiceState method with synthetic selection capture only."]
    var ledger = UIE2ECoverageLedger()
    var terminalFullTextProven = false
    var gate2245Enabled = false
    var guardRequired = false
    var guardLaunches = 0
    /// Latched on the first foreign modal / unanswered boundary: no later action, command or still runs.
    var foreignModalStop: String?
    var observed: Set<String> { get { ledger.observed } set { ledger.observed = newValue } }
    var exercised: Set<String> { get { ledger.exercised } set { ledger.exercised = newValue } }
    var activePage = "General"
    var activeHistoryScope = "Dictations"
    var selectedHistoryRow = "qa-recording"
    var editingDictionaryRow: String?
    var lastActionEventIndex = 0
    var pasteboardSaved = false
    var pasteboardItems: [[NSPasteboard.PasteboardType: Data]] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        scenario = env["VOICEBAR_UIE2E_SCENARIO"] ?? "full"
        guard ["full", "focused-338", "hide1", "gate2246"].contains(scenario) else { throw NSError(domain: "UIE2E invalid scenario", code: 1) }
        if scenario == "focused-338" {
            limitations = ["Gallery variants use real production BarView/DictationCard in arbitrary page positions; they do not prove notch placement. One actual production-geometry notch render per family is checked separately.",
                "Static confirmation holds are synthetic presentations of actual production outcomes; synchronized lifetime uses fresh production timers. No real microphone, audio, global hotkey, external insertion or installed-app acceptance is claimed.",
                "P1e readability is a normal assertion; focused results permit no P1e XFAIL or capability skip and do not establish full release coverage."]
        }
        root = URL(fileURLWithPath: try XCTUnwrap(env["VOICEBAR_UIE2E_ROOT"]))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".uie2e-sandbox")), "voicebar-ui-e2e-v1\n")
        pasteboardItems = try (NSPasteboard.general.pasteboardItems ?? []).map { item in
            try Dictionary(uniqueKeysWithValues: item.types.map { type in
                (type, try XCTUnwrap(item.data(forType: type), "Cannot preserve pasteboard type \(type.rawValue)"))
            })
        }
        pasteboardSaved = true
        let appURL = URL(fileURLWithPath: try XCTUnwrap(env["VOICEBAR_UIE2E_APP"]))
        guard appURL.resolvingSymlinksInPath() == root.appendingPathComponent("VoiceBarQA.app").resolvingSymlinksInPath(),
              Bundle(url: appURL)?.bundleIdentifier == "com.voicelayer.voicebar.uie2e",
              Bundle(url: appURL)?.object(forInfoDictionaryKey: "VoiceBarUIE2EOnly") as? Bool == true
        else { throw NSError(domain: "UIE2E unsafe app", code: 1) }
        app = XCUIApplication(url: appURL)
        gate2245Enabled = Bundle(url: appURL)?.object(forInfoDictionaryKey: "UIE2EGate2245") as? Bool == true
        app.launchEnvironment = ["VOICEBAR_UIE2E": "1", "VOICEBAR_UIE2E_SCENARIO": scenario, "VOICEBAR_UIE2E_ROOT": root.path,
            "HOME": root.appendingPathComponent("home").path, "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
            "QA_VOICE_DISABLE_FLAG_PATH": root.appendingPathComponent("disabled").path,
            "VOICEBAR_USER_DEFAULTS_SUITE": "com.voicelayer.uie2e.\(root.lastPathComponent)",
            "VOICELAYER_SOCKET_PATH": root.appendingPathComponent("v.sock").path,
            "VOICELAYER_MCP_SOCKET_PATH": root.appendingPathComponent("m.sock").path]
        if gate2245Enabled {
            app.launchEnvironment["QA_VOICEBAR_CAPTURE_TOP_RIGHT"] = "1"
            app.launchEnvironment["VOICEBAR_QA_ALLOW_PARALLEL_INSTANCE"] = "1"
        }
        // Every GATE2245 build or scenario constructs the real AppDelegate: insert the tripwire.
        if gate2245Enabled || ["hide1", "gate2246"].contains(scenario) {
            let library = try XCTUnwrap(env["VOICEBAR_UIE2E_DEVICE_GUARD"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: library))
            app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = library
            guardRequired = true // Each launch gets its own receipt path in launchQA().
        }
        addUIInterruptionMonitor(withDescription: "Foreign interruption: latch STOP, never interact") { [unowned self] alert in
            // GATECAP1 R4: never recover focus and continue around a foreign window. Latch STOP and
            // log only a redacted description; returning true means "handled" with nothing pressed,
            // so no implicit default handler can dismiss it.
            let kind: String
            switch UIE2EInterruptionPolicy.classify(alertDescription: alert.debugDescription) {
            case .permissionPrompt: kind = "permission-prompt"
            case .qaOwnedInterruption: kind = "qa-owned"
            case .knownBenignForeign: kind = "known-foreign"
            case .unknown: kind = "unknown"
            }
            self.latchForeignStop("interruption " + kind + " " + uie2eRedacted(alert.debugDescription))
            return true
        }
        step("launch isolated QA app", evidenceContract: launchEvidenceContract) {
            launchQA()
            app.activate()
            if ["hide1", "gate2246"].contains(scenario) {
                XCTAssertTrue(app.menuBars.menuBarItems["HIDE1VIS"].waitForExistence(timeout: 15))
            } else { XCTAssertTrue(app.windows["VoiceBar QA Settings"].waitForExistence(timeout: 15)) }
            XCTAssertEqual(app.state, .runningForeground)
        }
        recordGuardedLaunch()
    }

    override func tearDownWithError() throws {
        // XCTest owns attachment storage, including when its signed runner is sandboxed.
        // Keep the final snapshot after termination and clipboard restoration assertions.
        defer {
            attachJSON("UIE2E-LEDGER", ["version": 1, "scenario": scenario, "scope": scenario, "steps": steps, "completed": completed,
                "failures": testRun?.failureCount ?? 1,
                "coverage": ["scenario": scenario, "observed": observed.sorted(), "exercised": exercised.sorted(), "missing": ledger.missing.sorted(),
                    "missingSurfaces": ledger.missingSurfaces.sorted(), "verifiedSurfaces": ledger.verifiedSurfaces.sorted(),
                    "expectedSurfaces": ledger.expectedSurfaces],
                "knownVisualGaps": knownVisualGaps, "limitations": limitations])
        }
        if app != nil, app.state != .notRunning { step("terminate QA app", evidenceContract: "terminated") { app.terminate() } }
        finishGuardedLaunch()
        guard pasteboardSaved else { return }
        NSPasteboard.general.clearContents()
        let restored = pasteboardItems.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { XCTAssertTrue(NSPasteboard.general.writeObjects(restored)) }
    }

    func attachJSON(_ name: String, _ object: Any) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch { XCTFail("Cannot attach receipt: \(error)") }
    }

    /// All input operations go through this wrapper, including scrolling, typing and menu dismissal.
    /// A failed assertion/action still produces a keepAlways attachment and a FAIL receipt.
    func step(_ name: String, evidenceContract: String = "visible", skipped: String? = nil, expected issue: UIE2EKnownIssue? = nil,
              surface: String? = nil, surfaces: [String] = [], _ body: () -> Void) {
        let number = steps.count + 1
        let attachment = String(format: "UIE2E-%04d", number)
        let before = testRun?.failureCount ?? 0
        var matched: [String] = []
        var capture: [String: Any] = [:]
        XCTContext.runActivity(named: "\(attachment) \(name)") { activity in
            // Fresh synchronous modal decision before the UI action; a STOP skips the action entirely.
            if !boundaryClear("action") {
                capture = ["source": "qa-window-id", "status": "NOT_PROVEN", "reason": "foreign-modal-stop"]
            } else if let issue {
                let options = XCTExpectedFailure.Options()
                options.isStrict = true
                options.issueMatcher = { recorded in
                    guard recorded.type == .assertionFailure, issue.matches(recorded.compactDescription) else { return false }
                    matched.append(recorded.compactDescription)
                    return true
                }
                XCTExpectFailure("Known product packet " + issue.rawValue, options: options) { body() }
            } else { body() }
            if foreignModalStop == nil {
                // Window-ID capture of the proven QA process only, taken by the broker after its own
                // fresh modal check. No proven QA window: no capture, the frame is NOT_PROVEN.
                let request = boundary("still")
                if request.ack?["status"] as? String != "clear" { latchForeignStop("before still: " + (request.ack?["status"] as? String ?? "no-answer")) }
                capture = uie2eStillReceipt(request.ack, count: request.count)
                let path = (request.ack?["capture"] as? [String: Any])?["path"] as? String
                if capture["status"] as? String == "PROVEN" {
                    if let path, let png = try? Data(contentsOf: URL(fileURLWithPath: path)), !png.isEmpty {
                        let screenshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                        screenshot.name = attachment
                        screenshot.lifetime = .keepAlways
                        activity.add(screenshot)
                    } else { capture = ["source": "qa-window-id", "status": "NOT_PROVEN", "reason": "still-unreadable"] }
                }
                if let failure = uie2eFrameFailure(capture, contract: evidenceContract) { XCTFail(failure) }
            }
        }
        let passed = (testRun?.failureCount ?? 0) == before
        var receipt: [String: Any] = ["number": number, "name": name, "attachment": attachment, "passed": passed,
                                      "capture": capture, "evidenceContract": evidenceContract]
        if let skipped { receipt["skipped"] = skipped }
        if let issue, !matched.isEmpty, passed {
            var expectedReceipt: [String: Any] = ["packet": issue.rawValue, "surface": surface ?? "", "descriptions": matched]
            if !surfaces.isEmpty {
                expectedReceipt["surfaces"] = surfaces
                for id in surfaces { XCTAssertTrue(ledger.recordExpected(surface: id, issue: issue, descriptions: matched)) }
            }
            receipt["expectedFailure"] = expectedReceipt
        }
        steps.append(receipt)
        let result = !passed ? "FAIL" : !matched.isEmpty ? "XFAIL [\(issue!.rawValue)]" : "PASS"
        print("UIE2E \(result) \(number) \(name)")
        // Individual receipts survive an aborted method; only the final ledger can complete a run.
        attachJSON(String(format: "UIE2E-RECEIPT-%04d", number), receipt)
    }

    @discardableResult
    func click(_ resolve: @autoclosure () -> XCUIElement, _ name: String? = nil,
               revealPolicy: UIE2EClickRevealPolicy = .automatic, evidenceContract: String = "visible") -> Bool {
        var clicked = false
        var found = false
        var needsReveal = false
        var label = "control"
        step("locate \(name ?? "control")") {
            let element = resolve()
            found = element.exists || element.waitForExistence(timeout: 4)
            guard found else { XCTFail("Missing control: \(element.debugDescription)"); return }
            label = element.label
            // A main menu exists even while closed. Its mere presence must
            // never suppress scrolling an offscreen Settings/sheet control.
            // Only Settings descendants can be revealed by scrolling Settings.
            let settingsContainsMatch = app.windows["VoiceBar QA Settings"].descendants(matching: element.elementType)
                .matching(identifier: element.identifier.isEmpty ? element.label : element.identifier).firstMatch.exists
            needsReveal = UIE2ERevealRouting.shouldReveal(isHittable: element.isHittable,
                isMenuItem: element.elementType == .menuItem,
                settingsContainsMatchingControl: settingsContainsMatch, policy: revealPolicy)
        }
        guard found else { return false }
        if needsReveal { reveal(resolve()) }
        step(name ?? "click \(label)", evidenceContract: evidenceContract) {
            // Re-resolve after scrolling/row changes; never click the inspection snapshot.
            let element = resolve()
            guard element.exists || element.waitForExistence(timeout: 4), element.isEnabled, element.isHittable else {
                XCTFail("Missing, disabled or unreachable: \(element.debugDescription)"); return
            }
            let forbidden = ["preview", "play", "replay", "speak", "ask", "start voice recording"]
            let audioLabel = element.label.lowercased()
            let audioAction = forbidden.contains(audioLabel) || ["play ", "preview ", "replay ", "speak ", "ask "].contains { audioLabel.hasPrefix($0) }
            guard !(audioAction && element.elementType != .radioButton) else { XCTFail("Forbidden audio action"); return }
            let key = controlKey(element)
            let label = element.label
            let type = element.elementType
            lastActionEventIndex = fixtureEvents().count
            let beforeValue = controlValue(element)
            let failures = testRun?.failureCount ?? 0
            if label.contains(", Connected, Make default") {
                // The combined AX row's centre is inert; the actual child button is at its right edge.
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
                waitUntil { self.fixtureEvents().dropFirst(self.lastActionEventIndex).contains("microphone-order") }
                XCTAssertFalse(resolve().exists, "The old Make default row must become Default")
            } else if activePage == "History", type == .button,
                      label.hasPrefix("QA fixture transcript") || label.hasPrefix("QA older transcript") || label.hasPrefix("QA loaded transcript") {
                // Native RED: the plain row's AX centre falls between its two
                // text lines; the older row stayed unselected after dispatch.
                // Hit the first rendered line, then require actual selection.
                let offset = UIE2EHistoryGeometry.selectionOffset(in: element.frame)
                element.coordinate(withNormalizedOffset: .zero).withOffset(offset).click()
                waitUntil { element.isSelected }
            } else if type == .disclosureTriangle {
                // Native AX starts 22.5pt before the visible label/container edge:
                // original frame x260.5; arrow x287. Centre and x+8 were inert.
                element.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: 27, dy: element.frame.height / 2)).click()
                waitUntil { self.controlValue(element) != beforeValue }
            } else { element.click() }
            if evidenceContract == "terminated" { XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)) }
            guard (testRun?.failureCount ?? 0) == failures else { return }
            exercised.insert(key); clicked = true
            didActivate(label: label, type: type)
        }
        return clicked
    }

    func replace(_ field: XCUIElement, _ value: String) {
        guard click(field, "focus \(field.label)") else { return }
        step("select field contents") { field.typeKey("a", modifierFlags: .command) }
        step("type \(value)") {
            if value.isEmpty { field.typeKey(.delete, modifierFlags: []) }
            else { field.typeText(value) }
        }
        step("assert exact field value after typing") {
            guard field.exists else { XCTFail("Edited field disappeared"); return }
            XCTAssertEqual(field.value as? String, value, "Text replacement must not append to an old value")
        }
    }

    func tab(_ name: String) {
        let sidebar = app.windows["VoiceBar QA Settings"].outlines["Sidebar"]
        click(sidebar.staticTexts[name], "open \(name) tab")
        step("assert selected \(name) tab and content") {
            let row = sidebar.descendants(matching: .outlineRow).containing(.staticText, identifier: name).firstMatch
            waitUntil { row.exists && row.isSelected }
            let content: XCUIElement
            switch name {
            case "General": content = app.buttons["Check shortcut"]
            case "Transcription": content = app.scrollViews["models-settings-form"]
            case "Dictionary": content = app.textFields["Search terms and variants"]
            case "Speech": content = app.textFields["speech-short_limit_chars"]
            default: content = app.radioButtons["Dictations"]
            }
            XCTAssertTrue(content.waitForExistence(timeout: 3))
            activePage = name
        }
    }

    func scroll(_ direction: CGFloat, times: Int = 6) {
        for index in 1...times {
            step("scroll \(direction > 0 ? "up" : "down") \(index)") {
                guard let area = app.windows["VoiceBar QA Settings"].scrollViews.allElementsBoundByIndex.last
                else { XCTFail("Missing Settings scroll view"); return }
                area.scroll(byDeltaX: 0, deltaY: direction * 420)
                observeControls()
            }
        }
    }

    func assertCopy(_ label: String, equals expected: String? = nil, contains required: String? = nil,
                    target: XCUIElement? = nil, resolver: (() -> XCUIElement)? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("UIE2E clipboard sentinel", forType: .string)
        guard click(resolver?() ?? target ?? (app.menuItems[label].exists ? app.menuItems[label] : app.buttons[label].firstMatch), "copy " + label) else { return }
        step("assert pasteboard for \(label)") {
            let actual = NSPasteboard.general.string(forType: .string)
            XCTAssertNotEqual(actual, "UIE2E clipboard sentinel")
            if let expected { XCTAssertEqual(actual, expected) }
            if let required { XCTAssertTrue(actual?.contains(required) == true, actual ?? "nil") }
        }
    }

    func testFocused338StateGallery() throws {
        try runFocused338StateGallery()
    }

    func testFullUIOnlyFlow() throws {
        guard scenario == "full" else { throw NSError(domain: "UIE2E full test selected in focused run", code: 1) }
        if gate2245Enabled {
            step("GATE2245 no-device guard installed before fixtures") {
                XCTAssertTrue(guardReceiptIsClean(guardLaunches))
            }
            gate2245Flow()
            step("GATE2245 no device-start or process tripwire invoked") {
                XCTAssertTrue(guardReceiptIsClean(guardLaunches))
            }
            guard (testRun?.failureCount ?? 1) == 0 else { return }
        }
        // Dictionary's animated top-level edit sheet and inline delete confirmation
        // have separate Cancel controls. Exercise both before the long tab sweeps.
        for (name, run) in [("Dictionary", dictionaryFlow), ("History", historyFlow), ("Pill", pillFlow),
            ("Popover", menuBarFlow), ("Context menu", contextMenuFlow), ("Notch", notchRegressionFlow),
            ("General", generalFlow), ("Transcription", transcriptionFlow), ("Speech", speechFlow)] {
            let before = testRun?.failureCount ?? 0
            run()
            step("verify completed surface \(name)", evidenceContract: name == "Context menu" ? "terminated" : "visible") {
                XCTAssertEqual(testRun?.failureCount ?? 0, before, "Surface did not complete successfully")
                if (testRun?.failureCount ?? 0) == before { ledger.verifiedSurfaces.insert(name) }
            }
            if name == "Context menu", app.state == .notRunning { relaunchQA() }
        }
        step("all observed non-audio Settings controls exercised") {
            let missing = observed.subtracting(exercised).sorted()
            XCTAssertTrue(missing.isEmpty, "Unexercised controls: \(missing.joined(separator: ", "))")
            XCTAssertTrue(ledger.missingSurfaces.isEmpty, "Unverified surfaces: \(ledger.missingSurfaces.sorted())")
        }
        completed = true
    }
}

extension VoiceBarFlowTests {
    func controlValue(_ element: XCUIElement) -> String? {
        if let number = element.value as? NSNumber { return number.stringValue }
        return element.value as? String
    }
    /// Posts one boundary request and waits for the broker's answer to exactly it.
    func boundary(_ kind: String) -> (count: Int, ack: [String: Any]?) {
        let ackURL = root.appendingPathComponent("boundary/ack.json")
        let count = (uie2eBoundaryAck(try? Data(contentsOf: ackURL))?["count"] as? Int ?? 0) + 1
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(uie2eBoundaryName(token: root.lastPathComponent, kind: kind)),
            object: nil, userInfo: nil, deliverImmediately: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let ack = uie2eBoundaryAck(try? Data(contentsOf: ackURL)), ack["count"] as? Int == count {
                return (count, ack["kind"] as? String == kind ? ack : nil)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return (count, nil)
    }

    /// True only on a fresh clear decision; anything else latches STOP for the rest of the run.
    func boundaryClear(_ kind: String) -> Bool {
        guard foreignModalStop == nil else { return false }
        let request = boundary(kind)
        if uie2eBoundaryClear(request.ack, count: request.count, kind: kind) { return true }
        latchForeignStop("before " + kind + ": " + (request.ack?["status"] as? String ?? "no-broker-answer"))
        return false
    }

    func latchForeignStop(_ reason: String) {
        guard foreignModalStop == nil else { return }
        foreignModalStop = reason
        XCTFail("Foreign modal STOP latched (" + reason + "); no further action, command or capture")
        _ = boundary("action")  // Lets the broker take its own fresh decision and latch the supervisor STOP.
    }

    func waitUntil(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 3) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: timeout), .completed)
    }

    func fixtureEvents() -> [String] {
        do { return try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("events.json"))) }
        catch { XCTFail("Cannot read isolated fixture events: \(error)"); return [] }
    }

    func foregroundQA() {
        step("activate QA window on screen") {
            app.activate()
            let window = app.windows["VoiceBar QA Settings"]
            waitUntil { self.app.state == .runningForeground && window.isHittable }
            XCTAssertTrue(window.frame.width > 0 && window.frame.height > 0)
            XCTAssertTrue(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "QA window is off-screen")
        }
    }
    func controlKey(_ element: XCUIElement) -> String {
        let label = element.label
        let section = label.hasPrefix("Your terms") ? "Your terms" : label.hasPrefix("Included terms") ? "Included terms" : nil
        let identity = section ?? (element.identifier.isEmpty ? (element.elementType == .popUpButton ? "voice-picker" : label) : element.identifier)
        var context = UIE2EControlContext(page: activePage)
        if label == "Open General settings" { context.page = "Navigation" }
        if context.page == "History" {
            let selector = element.elementType == .radioButton && ["Ask", "Dictations"].contains(label)
            context.scope = selector ? "scope-selector" : activeHistoryScope
            if label.hasPrefix("QA fixture transcript") { context.row = "qa-recording" }
            else if label.hasPrefix("QA loaded transcript") { context.row = "qa-loaded" }
            else if label.hasPrefix("QA older transcript") { context.row = "qa-older" }
            else if ["Copy transcript", "Paste transcript", "Re-transcribe stored audio", "Open stored audio in Finder",
                     "Copy recording details", "Copied recording details"].contains(label) {
                context.row = activeHistoryScope == "Ask" ? askControlRow(element) : selectedHistoryRow
            }
        }
        if activePage == "Dictionary" {
            for prefix in ["Edit term ", "Delete term ", "Copy term ", "Copied term "] where label.hasPrefix(prefix) {
                context.row = String(label.dropFirst(prefix.count))
            }
            if ["Cancel", "Save", "Delete?", "Correct spelling", "Misheard as"].contains(label) ||
                label.hasPrefix("Remove misheard spelling ") {
                context.row = editingDictionaryRow
            }
        }
        if activePage == "Speech", element.elementType == .popUpButton || element.elementType == .slider || label.contains("daemon command") {
            context.profile = speechProfile(element)
        }
        return ledger.key(role: String(element.elementType.rawValue), identity: identity, context: context)
    }

    func speechProfile(_ element: XCUIElement) -> String {
        // Native CU: the same ID is inherited by Text/Picker/Slider descendants.
        // Match role + ID instead of evaluating an ambiguous any-element query.
        for kind in ["short", "long"] {
            if element.identifier == "speech-\(kind).voice" || element.identifier == "speech-\(kind).rate" { return kind }
        }
        // Section headings are AX headings rather than StaticText. Associate
        // S3 Copy with its one-picker native section; never use a shared label key.
        if element.label.lowercased().contains("daemon command") {
            let window = app.windows["VoiceBar QA Settings"]
            for kind in ["short", "long"] {
                let sections = window.descendants(matching: .any)
                    .containing(.popUpButton, identifier: "speech-\(kind).voice").allElementsBoundByIndex
                for section in sections where section.popUpButtons.count == 1 {
                    let copies = section.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'daemon command'"))
                    if copies.count == 1 && copies.firstMatch.frame == element.frame { return kind }
                }
            }
        }
        XCTFail("Cannot resolve Speech profile for \(element.label); refusing a shared coverage identity")
        return "unresolved-profile"
    }

    func askPayloadFrames() -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for (row, payload) in [("qa-ask-response", "QA response"), ("qa-ask-loaded-response", "QA loaded response")] {
            let texts = app.windows["VoiceBar QA Settings"].staticTexts.matching(UIE2EAXText.predicate(payload,
                staticTextRole: XCUIElement.ElementType.staticText.rawValue)).allElementsBoundByIndex
                .map(\.frame).filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
            frames[row] = texts.min { $0.width * $0.height < $1.width * $1.height }
        }
        return frames
    }

    func askControl(_ label: String, row: String) -> XCUIElement? {
        let payloads = askPayloadFrames()
        guard let payload = payloads[row] else { return nil }
        let nextY = payloads.values.filter { $0.minY > payload.minY }.map(\.minY).min()
        let buttons = app.windows["VoiceBar QA Settings"].buttons.matching(identifier: label).allElementsBoundByIndex
        guard let index = UIE2EHistoryGeometry.actionIndex(after: payload, before: nextY, candidates: buttons.map(\.frame)) else { return nil }
        return buttons[index]
    }

    func askControlRow(_ element: XCUIElement) -> String {
        let label = element.identifier.isEmpty ? element.label : element.identifier
        for row in ["qa-ask-response", "qa-ask-loaded-response"] {
            if let control = askControl(label, row: row), control.frame == element.frame { return row }
        }
        XCTFail("Cannot resolve Ask control row; refusing a shared coverage identity")
        return "unresolved-ask-row"
    }

    func didActivate(label: String, type: XCUIElement.ElementType) {
        if type == .staticText, ["General", "Transcription", "Dictionary", "Speech", "History"].contains(label) { activePage = label }
        if label == "View history →" { activePage = "History" }
        if label == "Open General settings" { activePage = "General" }
        if activePage == "History", type == .radioButton, ["Ask", "Dictations"].contains(label) {
            activeHistoryScope = label
            selectedHistoryRow = label == "Ask" ? "qa-ask-response" : "qa-recording"
            // Every scope receives an inventory; another scope's click cannot discharge it.
            observeControls()
        }
        if activePage == "History", label.hasPrefix("QA fixture transcript") { selectedHistoryRow = "qa-recording" }
        if activePage == "History", label.hasPrefix("QA older transcript") { selectedHistoryRow = "qa-older" }
        if activePage == "History", label.hasPrefix("QA loaded transcript") { selectedHistoryRow = "qa-loaded" }
        if activePage == "Dictionary" {
            for prefix in ["Edit term ", "Delete term "] where label.hasPrefix(prefix) {
                editingDictionaryRow = String(label.dropFirst(prefix.count))
            }
            if ["Cancel", "Save", "Delete?"].contains(label) { editingDictionaryRow = nil }
        }
    }

    /// Snapshot every enabled control encountered while scrolling, rather than silently
    /// passing when a newly added control is absent from this flow. Audio remains excluded.
    func observeControls() {
        let window = app.windows["VoiceBar QA Settings"]
        for type: XCUIElement.ElementType in [.button, .switch, .checkBox, .link, .radioButton, .popUpButton, .slider, .textField, .disclosureTriangle] {
            for element in window.descendants(matching: type).allElementsBoundByIndex where element.isEnabled && element.isHittable {
                let label = element.label.lowercased()
                if element.identifier.hasPrefix("qa-fixture-") || label.hasPrefix("copied") { continue }
                if element.identifier.hasPrefix("_XCUI:") || label == "windowsharingsessionbutton" { continue }
                if ["close", "minimize", "zoom", "full screen"].contains(label) { continue }
                if label.hasPrefix("play ") || ["preview", "play", "replay", "speak", "start voice recording"].contains(label) { continue }
                observed.insert(controlKey(element))
            }
        }
    }

    func reveal(_ resolve: @autoclosure () -> XCUIElement) {
        for direction: CGFloat in [-1, 1] {
            for _ in 0..<7 {
                var hittable = false
                step("inspect control visibility") {
                    let element = resolve()
                    hittable = element.exists && element.isHittable
                }
                if hittable { return }
                scroll(direction, times: 1)
            }
        }
    }

    func walk(_ name: String) {
        foregroundQA()
        tab(name)
        step("inventory \(name) controls") { observeControls() }
        scrollFully(-1)
        scrollFully(1)
    }

    func scrollFully(_ direction: CGFloat) {
        let area = app.windows["VoiceBar QA Settings"].scrollViews.allElementsBoundByIndex.last
        func position() -> Double? {
            guard let bar = area?.scrollBars.allElementsBoundByIndex.first(where: { $0.frame.height > $0.frame.width }),
                  let text = controlValue(bar) else { return nil }
            return Double(text)
        }
        func signature() -> [String] {
            // Native CU exposes a normalized vertical scrollbar. Reading its
            // position avoids hundreds of AX round-trips after every scroll.
            if let value = position() { return ["vertical-scroll-position:\(value)"] }
            return area?.descendants(matching: .any).allElementsBoundByIndex.map {
                "\($0.elementType.rawValue)|\($0.label)|\($0.frame)"
            } ?? []
        }
        var before = signature()
        var stable = 0
        for _ in 0..<16 {
            scroll(direction, times: 1)
            let after = signature()
            stable = before == after ? stable + 1 : 0
            if stable >= 2 {
                if let value = position() {
                    step("assert native scroll edge") { XCTAssertTrue(UIE2EScrollEdge.reached(value, direction: direction),
                        "Scroll stopped before requested edge: \(value), direction \(direction)") }
                }
                return
            }
            before = after
        }
        step("assert full scroll reached edge") { XCTFail("Scroll did not stabilize within 16 actions") }
    }

    func receipt(_ expected: String, evidenceContract: String = "visible") {
        step("assert intent \(expected)", evidenceContract: evidenceContract) {
            do {
                let events = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("events.json")))
                XCTAssertTrue(events.dropFirst(lastActionEventIndex).contains(expected), "Missing fresh fixture intent: \(expected)")
            } catch { XCTFail("Cannot read fixture receipts: \(error)") }
        }
    }

    func generalFlow() {
        walk("General")
        click(app.buttons["Restart F5 listener"])
        receipt("restart-listener")
        assertCopy("Copy F5 listener error", equals: "Still off: the F5 listener couldn't start. If you just allowed access, quit and reopen VoiceBar.")
        click(app.buttons["Check shortcut"])
        receipt("check-shortcut")
        assertCopy("Copy shortcut check result", equals: "QA shortcut failure\nSecond line")
        click(app.buttons["Open Microphone"])
        click(app.buttons["Open Accessibility"])
        click(app.buttons["Open Input Monitoring"])
        click(app.buttons["Run setup again"])
        receipt("run-setup")
        wizardFlow()
        step("assert QA floating panel exists before Hide") { XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].waitForExistence(timeout: 3)) }
        click(app.buttons["Hide VoiceBar for 1 hour"])
        receipt("hide")
        step("assert Hide removes the QA floating panel") {
            waitUntil { !self.app.dialogs["VoiceBar QA Pill"].exists }
        }
        click(app.buttons["Show VoiceBar"])
        receipt("show")
        step("assert Show restores the QA floating panel") {
            XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].waitForExistence(timeout: 3))
        }
        click(app.buttons["QA microphone B, Connected, Make default"], "make QA microphone B default")
        receipt("microphone-order")
        click(app.buttons["QA microphone A, Connected, Make default"], "restore QA microphone A default")
        click(app.buttons["Advanced"])
        click(app.buttons["Set up"])
        receipt("relay-setup")
        assertCopy("Copy F5 setup error", equals: "installer exited 7: Second line\n\nInstaller output:\nQA relay failure\nSecond line")
        let bundle = Bundle(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_APP"]!))!
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let commit = bundle.object(forInfoDictionaryKey: "GitCommit") as? String ?? "Unknown"
        assertCopy("Copy build and diagnostic summary", equals: [
            "VoiceBar: \(version) (build \(build))", "App commit: \(commit)", "Daemon identity: Unknown (not reported)",
            "Recognizer status: available", "Configured model: QA recognizer", "Active model: Unknown",
            "Residency: loaded", "Configured effort: accurate", "Active effort: Unknown"].joined(separator: "\n"))
        assertCopy("Copy last dictation", equals: "QA fixture transcript שלום 👋")
        click(app.links["View history →"])
        step("assert General link opened History content") { XCTAssertTrue(app.radioButtons["Dictations"].waitForExistence(timeout: 3)) }
        click(app.buttons["Open General settings"])
        // Exercise both disclosure states, keeping the form fully scrollable.
        click(app.buttons["Advanced"])
    }

    func transcriptionFlow() {
        walk("Transcription")
        let residency = app.buttons["models-residency-control"]
        click(residency, "unload synthetic recognizer")
        step("assert recognizer unloaded") { XCTAssertEqual(residency.label, "Load") }
        click(residency, "load synthetic recognizer")
        step("assert recognizer loaded") { XCTAssertEqual(residency.label, "Unload") }
        let disclosure = app.disclosureTriangles["Recognizer details"]
        click(disclosure, "expand recognizer details")
        step("historical effort is a fact, no effort picker") {
            XCTAssertTrue(app.descendants(matching: .any)["Configured effort"].firstMatch.exists)
            XCTAssertFalse(app.popUpButtons["models-effort-picker"].exists)
        }
        click(disclosure, "collapse recognizer details")
        for key in ["model_polish", "outro_gate", "smart_chunks"] {
            let toggle = app.switches["models-processing-\(key)"]
            var before: String?
            step("inspect \(key) switch") {
                XCTAssertTrue(toggle.waitForExistence(timeout: 3))
                if toggle.exists { before = controlValue(toggle) }
            }
            guard toggle.exists else { continue }
            click(toggle, "toggle \(key)")
            step("assert \(key) changed") { XCTAssertNotNil(before); XCTAssertNotEqual(controlValue(toggle), before) }
            click(toggle, "restore \(key)")
            step("assert \(key) restored") { XCTAssertEqual(controlValue(toggle), before) }
        }
        assertCopy("Copy recognizer error", equals: "QA recognizer failure\nSecond line")
    }

    func wizardFlow() {
        let before = testRun?.failureCount ?? 0
        let window = app.windows["VoiceBar QA Setup"]
        step("assert production setup wizard opened") { XCTAssertTrue(window.waitForExistence(timeout: 3)) }
        guard window.exists else { return }
        for (title, next) in [("Welcome to VoiceBar", "Get started"), ("Allow access", "Continue"),
            ("Set up the F5 key", "Continue"), ("Choose your microphone", "Continue"),
            ("Try it", "Continue"), ("You're all set", "Start using VoiceBar")] {
            step("assert setup page \(title)") { XCTAssertTrue(window.staticTexts[title].waitForExistence(timeout: 3)) }
            click(window.buttons[next], "setup \(next)")
        }
        step("assert setup finished and closed") {
            waitUntil { !window.exists }
            if (testRun?.failureCount ?? 0) == before { ledger.verifiedSurfaces.insert("Setup wizard") }
        }
    }

    func dictionaryEntries() -> [[String: Any]] {
        do { return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("dictionary.json"))) as? [[String: Any]] ?? [] }
        catch { XCTFail("Missing fixture dictionary: \(error)"); return [] }
    }

    /// DictionaryAddSheetView is presented as a separate top-level sheet. Do not
    /// resolve its Cancel/Save/Add controls from the whole application: the
    /// Dictionary tab also has inline delete-confirmation Cancel/Delete? rows.
    func dictionaryEditSheet() -> XCUIElement? {
        let correctField = NSPredicate(format: "label == %@", "Correct spelling")
        let candidates = app.sheets.allElementsBoundByIndex.filter {
            $0.textFields.matching(correctField).firstMatch.exists
        }
        if candidates.count == 1 { return candidates[0] }
        if candidates.count > 1 { return nil }

        // Some macOS/XCTest versions expose a SwiftUI sheet as a top-level
        // window instead of XCUIElementTypeSheet.
        let windowCandidates = app.windows.allElementsBoundByIndex.filter {
            $0.textFields.matching(correctField).firstMatch.exists
        }
        return windowCandidates.count == 1 ? windowCandidates[0] : nil
    }

    func dictionarySheetControl(_ role: XCUIElement.ElementType, label: String) -> XCUIElement {
        guard let sheet = dictionaryEditSheet() else {
            XCTFail("Expected exactly one open Dictionary edit sheet for control \(label)")
            return app.descendants(matching: role).matching(identifier: "__missing_uie2e_dictionary_sheet_control__").firstMatch
        }
        return sheet.descendants(matching: role)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @discardableResult
    func waitForDictionarySheetStable(action: String) -> Bool {
        var becameStable = false
        step("wait for Dictionary sheet to settle before \(action)") {
            var priorSheetFrame: CGRect?
            var priorSettingsFrame: CGRect?
            var stableSamples = 0
            waitUntil({
                guard let sheet = self.dictionaryEditSheet() else {
                    priorSheetFrame = nil
                    priorSettingsFrame = nil
                    stableSamples = 0
                    return false
                }
                let sheetFrame = sheet.frame
                let settingsFrame = self.app.windows["VoiceBar QA Settings"].frame
                guard !sheetFrame.isEmpty, sheet.isHittable else { return false }
                if sheetFrame == priorSheetFrame && settingsFrame == priorSettingsFrame {
                    stableSamples += 1
                } else {
                    priorSheetFrame = sheetFrame
                    priorSettingsFrame = settingsFrame
                    stableSamples = 0
                }
                becameStable = stableSamples >= 2
                return becameStable
            }, timeout: 5)
        }
        return becameStable
    }

    @discardableResult
    func clickDictionarySheetButton(_ label: String) -> Bool {
        guard waitForDictionarySheetStable(action: label) else { return false }
        guard click(dictionarySheetControl(.button, label: label), "Dictionary sheet \(label)",
                    revealPolicy: .explicitlyScoped) else { return false }
        var dismissed = false
        step("assert Dictionary sheet dismissed after \(label)") {
            waitUntil {
                dismissed = self.dictionaryEditSheet() == nil
                return dismissed
            }
        }
        return dismissed
    }

    func assertTerm(_ canonical: String, variants: [String]?, exists: Bool = true) {
        step("assert persisted dictionary \(canonical)") {
            let entry = dictionaryEntries().first { $0["canonical"] as? String == canonical }
            XCTAssertEqual(entry != nil, exists)
            if let variants { XCTAssertEqual(entry?["variants"] as? [String], variants) }
        }
    }

    func dictionaryFlow() {
        walk("Dictionary")
        // The initial row's controls are part of the inventory too.
        click(app.buttons["Edit term QA initial"])
        guard waitForDictionarySheetStable(action: "edit initial Dictionary term") else { return }
        replace(dictionarySheetControl(.textField, label: "Correct spelling"), "QA initial")
        replace(dictionarySheetControl(.textField, label: "Misheard as"), "qa kept variant")
        click(dictionarySheetControl(.button, label: "Remove misheard spelling initial variant"),
            "remove initial misheard spelling", revealPolicy: .explicitlyScoped)
        clickDictionarySheetButton("Save")
        assertTerm("QA initial", variants: ["qa kept variant"])
        click(app.buttons["Edit term QA initial"])
        clickDictionarySheetButton("Cancel")
        assertTerm("QA initial", variants: ["qa kept variant"])
        click(app.buttons["Delete term QA initial"])
        click(app.windows["VoiceBar QA Settings"].buttons["Cancel"], "cancel inline dictionary delete")
        click(app.buttons["Add term"])
        guard waitForDictionarySheetStable(action: "enter new term") else { return }
        replace(dictionarySheetControl(.textField, label: "Correct spelling"), "QA new term")
        replace(dictionarySheetControl(.textField, label: "Misheard as"), "qa misheard")
        click(dictionarySheetControl(.button, label: "Swap correct and misheard text"))
        click(dictionarySheetControl(.button, label: "Swap correct and misheard text"))
        clickDictionarySheetButton("Add")
        assertTerm("QA new term", variants: ["qa misheard"])
        assertCopy("Copy term QA new term", equals: "QA new term")
        click(app.buttons["Edit term QA new term"])
        guard waitForDictionarySheetStable(action: "edit QA new term") else { return }
        replace(dictionarySheetControl(.textField, label: "Misheard as"), "qa second variant")
        clickDictionarySheetButton("Save")
        assertTerm("QA new term", variants: ["qa misheard", "qa second variant"])
        click(app.buttons["Edit term QA new term"])
        guard waitForDictionarySheetStable(action: "edit QA new term for cancelled rename") else { return }
        replace(dictionarySheetControl(.textField, label: "Correct spelling"), "QA cancelled rename")
        clickDictionarySheetButton("Cancel")
        assertTerm("QA new term", variants: ["qa misheard", "qa second variant"])
        click(app.buttons["Edit term QA new term"])
        guard waitForDictionarySheetStable(action: "rename QA new term") else { return }
        replace(dictionarySheetControl(.textField, label: "Correct spelling"), "QA renamed term")
        clickDictionarySheetButton("Save")
        assertTerm("QA renamed term", variants: ["qa misheard", "qa second variant"])
        assertTerm("QA new term", variants: nil, exists: false)
        click(app.buttons["Edit term QA renamed term"])
        guard waitForDictionarySheetStable(action: "remove a misheard spelling") else { return }
        click(dictionarySheetControl(.button, label: "Remove misheard spelling qa misheard"))
        clickDictionarySheetButton("Save")
        assertTerm("QA renamed term", variants: ["qa second variant"])
        let search = app.textFields["Search terms and variants"]
        replace(search, "second variant")
        step("search matches variant and filters unrelated term") {
            XCTAssertTrue(app.buttons["Edit term QA renamed term"].exists)
            XCTAssertFalse(app.buttons["Edit term QA initial"].exists)
        }
        replace(search, "TypeScript")
        // A filtered included section may expand automatically; explicitly open it otherwise.
        let included = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Included terms'")).firstMatch
        if included.exists && (included.value as? String) != "Expanded" { click(included) }
        assertCopy("Copy term TypeScript", equals: "TypeScript")
        replace(search, "")
        assertCopy("Copy term QA initial", equals: "QA initial")
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Your terms'")).firstMatch)
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Your terms'")).firstMatch)
        click(app.windows["VoiceBar QA Settings"].buttons["Delete term QA renamed term"])
        click(app.windows["VoiceBar QA Settings"].buttons["Cancel"], "cancel renamed-term inline delete")
        assertTerm("QA renamed term", variants: ["qa second variant"])
        click(app.windows["VoiceBar QA Settings"].buttons["Delete term QA renamed term"])
        click(app.windows["VoiceBar QA Settings"].buttons["Delete?"])
        assertTerm("QA renamed term", variants: nil, exists: false)
        click(app.buttons["Add term"])
        clickDictionarySheetButton("Cancel")
    }

    func speechFlow() {
        walk("Speech")
        for (index, kind) in ["short", "long"].enumerated() {
            let picker = app.popUpButtons["speech-\(kind).voice"]
            click(picker, "open grouped voice list \(index)")
            step("Fast and Cloned groups with Theo and fixture-ready Ben") {
                XCTAssertTrue(app.menuItems["Fast"].exists)
                XCTAssertTrue(app.menuItems["Cloned"].exists)
                XCTAssertTrue(app.menuItems["Theo"].exists)
                XCTAssertTrue(app.menuItems["Ben"].exists)
            }
            click(app.menuItems["Ben"], "select ready Ben fixture \(index)")
            step("assert Ben selection \(index)") { XCTAssertTrue(picker.value as? String == "Ben" || picker.label.contains("Ben")) }
            let slider = app.sliders["speech-\(kind).rate"]
            reveal(slider)
            step("change speech rate \(index)") {
                guard slider.exists, slider.isHittable else { XCTFail("Missing speech rate slider"); return }
                slider.adjust(toNormalizedSliderPosition: 0.75)
                exercised.insert(controlKey(slider))
            }
        }
        let threshold = app.textFields["speech-short_limit_chars"]
        replace(threshold, "650")
        step("commit threshold") { threshold.typeKey(.return, modifierFlags: []) }
        step("assert saved speech settings") {
            do {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("speech.json"))) as! [String: Any]
                XCTAssertEqual((object["short_limit_chars"] as? [String: Any])?["effective"] as? Int, 650)
                let profiles = object["profiles"] as? [String: [String: [String: Any]]]
                XCTAssertEqual(profiles?["short"]?["voice"]?["effective"] as? String, "ben-c1")
                XCTAssertEqual(profiles?["long"]?["voice"]?["effective"] as? String, "ben-c1")
            } catch { XCTFail("Speech fixture was not saved: \(error)") }
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "fast voice (fallback)", "fast voice (fallback)")).firstMatch.exists)
            for kind in ["short", "long"] { XCTAssertFalse(app.buttons["speech-\(kind)-preview"].isEnabled) }
        }
        speechCopyFlow()
    }

    func skipCapability(_ reason: String) {
        step(reason, skipped: reason) {}
        print("UIE2E SKIP: \(reason)")
    }

    func speechCopyFlow() {
        let command = app.buttons["Copy daemon command"].firstMatch
        let error = app.buttons["Copy speech error"].firstMatch
        // Inspect both edges first so a lazy Form cannot be mistaken for an absent feature.
        scrollFully(-1)
        let hasError = error.exists
        scrollFully(1)
        let hasCommand = command.exists
        guard hasCommand || hasError else { skipCapability("S3 not in this build"); return }
        let commands = app.buttons.matching(NSPredicate(format: "label == 'Copy daemon command' OR label == 'Copied daemon command'"))
        for index in 0..<2 {
            assertCopy("Copy daemon command", equals: "voicelayer daemon", target: commands.element(boundBy: index))
        }
        assertCopy("Copy speech error", equals: "Couldn't complete the speech request - provider unavailable\nFull diagnostic: connection refused · שלום 🎧")
    }

    /// Native evidence: row selection, Refresh and Clear search replace detail views.
    /// Resolve a new scope + payload container for EVERY inspection/click, never retain a detail element.
    func historyControl(_ label: String) -> XCUIElement {
        let window = app.windows["VoiceBar QA Settings"]
        let selector = window.radioButtons[activeHistoryScope]
        let payload = activeHistoryScope == "Ask" ?
            (selectedHistoryRow == "qa-ask-loaded-response" ? "QA loaded response" : "QA response") :
            selectedHistoryRow == "qa-older" ? "QA older transcript" :
            selectedHistoryRow == "qa-loaded" ? "QA loaded transcript" : "QA fixture transcript שלום 👋"
        let missing = window.buttons["UIE2E-missing-\(activeHistoryScope)-\(selectedHistoryRow)-\(label)"]
        guard selector.exists, UIE2EAXSelection.isSelected(flag: selector.isSelected, value: selector.value) else {
            XCTFail("History scope \(activeHistoryScope) is not selected"); return missing
        }
        // Dictations' list rows are buttons; only its detail has the static transcript.
        // Ask's matching response text scopes the response controls independently of Dictations.
        // Native CU: Dictations combines transcript + Audio length into one AX
        // StaticText value. Exact label matching loses the fresh detail container.
        let anchor = NSPredicate(format: "elementType == %d AND (label CONTAINS %@ OR value CONTAINS %@)",
            XCUIElement.ElementType.staticText.rawValue, payload, payload)
        // Clearing search recreates the detail after its debounced archive
        // load. Wait on the real payload before taking a fresh container list.
        let payloadText = window.descendants(matching: .staticText).matching(anchor).firstMatch
        guard payloadText.exists || payloadText.waitForExistence(timeout: 4) else {
            attachJSON("UIE2E-HISTORY-MISSING-DETAIL", ["scope": activeHistoryScope,
                "row": selectedHistoryRow, "payload": payload, "AX": window.debugDescription])
            XCTFail("History detail payload did not appear for \(activeHistoryScope)/\(selectedHistoryRow)")
            return missing
        }
        if activeHistoryScope == "Ask" {
            if let control = askControl(label, row: selectedHistoryRow) { return control }
            attachJSON("UIE2E-ASK-MISSING-ACTION", ["row": selectedHistoryRow, "label": label, "AX": window.debugDescription])
            XCTFail("Missing unambiguous Ask row action for " + selectedHistoryRow + "/" + label)
            return missing
        }
        let containers = window.descendants(matching: .any).containing(anchor).allElementsBoundByIndex
            .filter { $0.buttons.matching(identifier: label).count == 1 }
            .sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let container = containers.first else {
            XCTFail("Missing unambiguous \(activeHistoryScope)/\(selectedHistoryRow) \(label)"); return missing
        }
        return container.buttons.matching(identifier: label).firstMatch
    }

    func assertHistoryCopy(_ label: String = "Copy transcript", equals expected: String? = nil, contains required: String? = nil) {
        assertCopy(label, equals: expected, contains: required, resolver: { self.historyControl(label) })
    }

    func assertHistoryPaste(_ expected: String) {
        var before = 0
        step("snapshot paste sink before \(activeHistoryScope) paste") {
            do { before = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("events.json"))).count }
            catch { XCTFail("Cannot read paste sink: \(error)") }
        }
        guard click(historyControl("Paste transcript"), "paste \(activeHistoryScope) \(selectedHistoryRow)") else { return }
        step("assert exact new paste payload \(expected)") {
            do {
                let events = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("events.json")))
                let received = Array(events.dropFirst(before))
                attachJSON("UIE2E-HISTORY-PASTE-\(activeHistoryScope)-\(selectedHistoryRow)",
                    ["scope": activeHistoryScope, "row": selectedHistoryRow, "expected": expected, "received": received])
                XCTAssertEqual(received, ["history-paste:" + expected])
            } catch { XCTFail("Cannot read paste sink: \(error)") }
        }
    }

    func historyFlow() {
        walk("History")
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA fixture transcript'")).firstMatch, "select fixture history row")
        assertHistoryCopy(equals: "QA fixture transcript שלום 👋")
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA older transcript'")).firstMatch, "select specific older row")
        assertHistoryCopy(equals: "QA older transcript")
        assertHistoryPaste("QA older transcript")
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA fixture transcript'")).firstMatch, "restore latest row before metadata assertions")
        assertHistoryPaste("QA fixture transcript שלום 👋")
        click(historyControl("Re-transcribe stored audio"))
        receipt("history-retranscribe")
        click(historyControl("Open stored audio in Finder"))
        receipt("history-finder")
        assertHistoryCopy("Copy recording details", contains: "Model: QA recognizer\nEffort: accurate")
        click(app.buttons["Load more"])
        step("assert Dictations pagination visibly adds its next row") {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA loaded transcript'")).firstMatch
            XCTAssertTrue(row.exists || row.waitForExistence(timeout: 4))
            XCTAssertFalse(app.buttons["Load more"].exists)
            waitUntil { self.fixtureEvents().dropFirst(self.lastActionEventIndex).contains("history-page:200") }
        }
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA loaded transcript'")).firstMatch,
              "select the newly loaded Dictations row")
        assertHistoryCopy(equals: "QA loaded transcript")
        assertHistoryPaste("QA loaded transcript")
        click(app.buttons["Refresh history"])
        step("assert Refresh history reloads the active page") {
            waitUntil { self.fixtureEvents().dropFirst(self.lastActionEventIndex).contains("history-page:200") }
        }
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA older transcript'")).firstMatch,
              "select older row before Jump to latest")
        click(app.buttons["Jump to latest"])
        step("assert Jump scroll contract without inventing a selection change") {
            let latest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA fixture transcript'")).firstMatch
            let older = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA older transcript'")).firstMatch
            waitUntil { latest.isHittable }
            XCTAssertTrue(older.isSelected, "Jump scrolls; only a row click changes selection")
        }
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA fixture transcript'")).firstMatch,
              "select newest row explicitly after Jump")
        replace(app.textFields["Search transcripts"], "no-match-uie2e")
        step("recording history search empty state") { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: app.buttons["Copy transcript"])], timeout: 4), .completed) }
        click(app.buttons["Clear search"].firstMatch)
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA fixture transcript'")).firstMatch,
              "select newest row after search recreates detail")
        assertHistoryCopy(equals: "QA fixture transcript שלום 👋")
        // This is the history scope selector, never an audio Ask operation.
        click(app.radioButtons["Ask"], "open Ask history scope")
        step("inventory Ask response controls") { observeControls() }
        assertHistoryCopy(equals: "QA response")
        assertHistoryPaste("QA response")
        click(app.buttons["Load older ask history"])
        step("assert Ask pagination visibly adds its next row") {
            let row = app.staticTexts.matching(UIE2EAXText.predicate("QA loaded question",
                staticTextRole: XCUIElement.ElementType.staticText.rawValue)).firstMatch
            XCTAssertTrue(row.exists || row.waitForExistence(timeout: 4))
            XCTAssertFalse(app.buttons["Load older ask history"].exists)
            waitUntil { self.fixtureEvents().dropFirst(self.lastActionEventIndex).contains("ask-history-page:200") }
        }
        selectedHistoryRow = "qa-ask-loaded-response"
        assertHistoryCopy(equals: "QA loaded response")
        assertHistoryPaste("QA loaded response")
        selectedHistoryRow = "qa-ask-response"
        click(app.buttons["Refresh ask history"])
        step("assert Refresh Ask history reloads the active page") {
            waitUntil { self.fixtureEvents().dropFirst(self.lastActionEventIndex).contains("ask-history-page:200") }
        }
        replace(app.textFields["Search questions and answers"], "no-match-uie2e")
        step("ask history search empty state") { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: app.buttons["Copy transcript"])], timeout: 4), .completed) }
        click(app.buttons["Clear search"].firstMatch)
        assertHistoryCopy(equals: "QA response")
        click(app.radioButtons["Dictations"])
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA fixture transcript'")).firstMatch,
              "reselect Dictations row after Ask scope")
        assertHistoryCopy(equals: "QA fixture transcript שלום 👋")
    }

    func pillFlow() {
        for (name, text) in [("transcribing", "Cancel transcription"), ("confirmation", "Pasted"),
                             ("paste-failed", "Paste failed — click input and press Shift+F5"),
                             ("error", "QA fixture failure"), ("disconnected", "Disconnected")] {
            click(app.buttons["qa-fixture-\(name)"])
            receipt("fixture:" + name)
            step("assert actual pill \(name) content") {
                let pill = app.dialogs["VoiceBar QA Pill"]
                XCTAssertTrue(pill.exists)
                if name == "disconnected" {
                    attachJSON("UIE2E-DISCONNECTED", ["expected": text, "AX": pill.debugDescription])
                }
                let content = pill.descendants(matching: .any).matching(UIE2EAXText.predicate(text,
                    staticTextRole: XCUIElement.ElementType.staticText.rawValue)).firstMatch
                XCTAssertTrue(content.exists || content.waitForExistence(timeout: 4), pill.debugDescription)
            }
            if name == "error" { click(app.buttons["Dismiss error"]) }
        }
        let feedback = [("paste-not-inserted", "Not pasted\nIn History"),
                        ("paste-unverified", "Unverified\nIn History"),
                        ("paste-partial", "Part pasted\nHistory: full")]
        if !app.buttons["qa-fixture-paste-not-inserted"].exists { skipCapability("P1b #338 not in this build") }
        else {
            for (name, expected) in feedback {
                click(app.buttons["qa-fixture-\(name)"])
                step("assert P1b AX content only \(name)") {
                    let note = app.dialogs["VoiceBar QA Pill"].staticTexts
                        .matching(UIE2EAXText.predicate(expected, staticTextRole: XCUIElement.ElementType.staticText.rawValue)).firstMatch
                    XCTAssertTrue(note.exists)
                    if note.exists {
                        attachJSON("UIE2E-FEEDBACK-\(name)", ["expected": expected, "label": note.label,
                            "value": note.value as? String ?? "", "frame": NSStringFromRect(note.frame),
                            "visualReadability": "AX content only; separate P1e rendered-frame assertion follows"])
                    }
                }
                step("P1e normal visible feedback frame \(name)") {
                    let note = app.dialogs["VoiceBar QA Pill"].staticTexts
                        .matching(UIE2EAXText.predicate(expected, staticTextRole: XCUIElement.ElementType.staticText.rawValue)).firstMatch
                    guard note.exists else { XCTFail("Missing feedback text for visual frame measurement"); return }
                    let required = UIE2EFeedbackFrame.requiredSize(text: expected, width: note.frame.width)
                    attachJSON("UIE2E-FEEDBACK-FRAME-\(name)", ["text": expected, "frame": NSStringFromRect(note.frame),
                        "requiredTextSize": NSStringFromSize(required), "font": "system12medium", "packet": "P1e"])
                    XCTAssertTrue(UIE2EFeedbackFrame.isReadable(text: expected, frame: note.frame),
                        "[P1e] Full feedback does not fit its visible text frame: \(note.frame); required \(required)")
                }
            }
        }
        click(app.buttons["qa-fixture-idle"])
    }

    /// Silent production BarView/VoiceState probes. Missing/unsupported behavior
    /// fails a required surface; it is never reported as exercised by a fixture click.
    func notchRegressionFlow() {
        geometryFlow()
        func verify(_ name: String, expected issue: UIE2EKnownIssue? = nil, _ body: () -> Void) {
            let before = testRun?.failureCount ?? 0
            let surface = "notch:" + name
            step("required notch flow \(name)", expected: issue, surface: surface, body)
            guard (testRun?.failureCount ?? 0) == before else { return }
            if let issue, let expected = steps.last?["expectedFailure"] as? [String: Any],
               let descriptions = expected["descriptions"] as? [String] {
                XCTAssertTrue(ledger.recordExpected(surface: surface, issue: issue, descriptions: descriptions))
            } else {
                ledger.verifiedSurfaces.insert(surface)
            }
        }
        click(app.buttons["qa-fixture-speaking"])
        verify("replay-playing") {
            let replay = app.dialogs["VoiceBar QA Pill"].buttons["Replay"]
            guard replay.waitForExistence(timeout: 3), replay.isHittable else { XCTFail("Replay not reachable in silent speaking fixture"); return }
            let before = fixtureEvents().count
            replay.click() // Only this marked QA fixture; sendCommand is an in-memory sink.
            waitUntil { self.fixtureEvents().dropFirst(before).contains("command:replay") }
        }
        verify("seek-playing") {
            let word = app.dialogs["VoiceBar QA Pill"].buttons["Second"]
            guard word.waitForExistence(timeout: 3), word.isHittable else { XCTFail("Timed Second word is not seekable while playing"); return }
            let before = fixtureEvents().count
            word.click()
            waitUntil { self.fixtureEvents().dropFirst(before).contains("command:seek") }
            let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("commands.json"))) as? [String: Any]
            let messages = object?["messages"] as? [[String: Any]]
            XCTAssertEqual(messages?.last?["offset_ms"] as? Int, 3000)
        }
        verify("list-newlines", expected: .listNewlines) {
            let pill = app.dialogs["VoiceBar QA Pill"]
            let first = pill.buttons["First"], second = pill.buttons["Second"]
            guard first.exists, second.exists else { XCTFail("List words not rendered"); return }
            XCTAssertGreaterThan(second.frame.minY, first.frame.maxY, "[P14b] A list newline must create a new visual line")
        }
        click(app.buttons["qa-fixture-readback"])
        verify("seek-idle") {
            let pill = app.dialogs["VoiceBar QA Pill"]
            let content = pill.descendants(matching: .any).matching(UIE2EAXText.predicate("Second",
                staticTextRole: XCUIElement.ElementType.staticText.rawValue)).firstMatch
            guard pill.exists, content.exists else { XCTFail("Idle readback fixture content is missing"); return }
            let word = pill.buttons["Second"]
            guard word.exists, word.isEnabled else { XCTFail("[SEEK2] Idle readback words are not actionable seek controls"); return }
            guard word.isHittable else { XCTFail("Idle word exists but is unreachable in QA host"); return }
            let before = fixtureEvents().count
            word.click()
            let received = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.fixtureEvents().dropFirst(before).contains("command:seek") }, object: nil)], timeout: 3)
            XCTAssertEqual(received, .completed, "[SEEK2] Readback word did not dispatch seek")
            let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("commands.json"))) as? [String: Any]
            XCTAssertEqual((object?["messages"] as? [[String: Any]])?.last?["offset_ms"] as? Int, 3000)
        }
        click(app.buttons["qa-fixture-preparing"])
        step("assert real Preparing state and visible playback shell before selection probe") {
            let pill = app.dialogs["VoiceBar QA Pill"]
            // Movie evidence shows a shell/timeline/controls, without word text.
            // Model receipt establishes Preparing; visible controls establish reachability.
            do {
                let data = try Data(contentsOf: root.appendingPathComponent("preparing.json"))
                let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertEqual(state?["mode"] as? String, "speaking")
                XCTAssertEqual(state?["statusText"] as? String, "Preparing speech…")
                XCTAssertEqual(state?["durationGrowing"] as? Bool, true)
                XCTAssertEqual(state?["originalRequested"] as? Bool, true)
            } catch { XCTFail("Missing actual Preparing state receipt: \(error)") }
            XCTAssertTrue(pill.exists)
            for label in ["Replay", "Hide teleprompter", "Stop speaking"] {
                let control = pill.buttons[label]
                XCTAssertTrue(control.exists && control.isHittable, "Preparing shell control missing: " + label)
            }
            attachJSON("UIE2E-PREPARING-PRESENTATION", ["AX": pill.debugDescription,
                "scope": "Preparing model receipt plus visible shell controls; no word-text claim"])
        }
        let commandStart = fixtureEvents().count
        click(app.buttons["qa-fixture-selection-replace"], "invoke real selection method with synthetic replacement")
        verify("supersede-preparing") {
            let received = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.fixtureEvents().dropFirst(commandStart).contains("command:speak_text") }, object: nil)], timeout: 3)
            guard received == .completed else {
                XCTFail("[SEL1] Preparing selection method stopped without submitting the replacement speak_text")
                return
            }
            let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("commands.json"))) as? [String: Any]
            let messages = object?["messages"] as? [[String: Any]]
            XCTAssertEqual(messages?.last?["text"] as? String, "QA replacement selection",
                "[SEL1] Selection replacement payload must be exact")
            let text = app.dialogs["VoiceBar QA Pill"].descendants(matching: .any).matching(UIE2EAXText.predicate("replacement",
                staticTextRole: XCUIElement.ElementType.staticText.rawValue)).firstMatch
            XCTAssertTrue(text.exists || text.waitForExistence(timeout: 3), "[SEL1] Replacement text never reached the UI")
        }
        click(app.buttons["qa-fixture-idle"])
        step("idle fixture clears the Preparing and readback presentation") {
            waitUntil {
                let pill = self.app.dialogs["VoiceBar QA Pill"]
                let preparing = pill.descendants(matching: .any).matching(UIE2EAXText.predicate("Preparing speech…",
                    staticTextRole: XCUIElement.ElementType.staticText.rawValue)).firstMatch
                return !preparing.exists && !pill.buttons["Stop speaking"].exists &&
                    !pill.buttons["Dismiss teleprompter"].exists && !pill.staticTexts["Teleprompter hidden"].exists
            }
        }
    }

    /// Exact AX screen frames are attached per transition, including failures.
    /// Row means the tight envelope of the three native control frames.
    func captureGeometry(_ name: String, speaking: Bool) -> UIE2EControlGeometry? {
        var geometry: UIE2EControlGeometry?
        step("GEO0 capture " + name) {
            let pill = app.dialogs["VoiceBar QA Pill"]
            let replay = pill.buttons["Replay"], eye = pill.buttons["Hide teleprompter"]
            let terminal = pill.buttons[speaking ? "Stop speaking" : "Dismiss teleprompter"]
            guard replay.waitForExistence(timeout: 3), eye.exists, terminal.exists else {
                XCTFail("GEO0 missing controls for " + name); return
            }
            // Wait for SwiftUI's transition to settle rather than measure animation.
            var previous = terminal.frame
            let started = Date()
            waitUntil {
                let next = terminal.frame
                defer { previous = next }
                return Date().timeIntervalSince(started) > 0.5 && next == previous && !next.isEmpty
            }
            let frames = [replay.frame, eye.frame, terminal.frame]
            guard frames.allSatisfy({ !$0.isEmpty && !$0.isInfinite && !$0.isNull }) else {
                XCTFail("GEO0 empty/offscreen geometry for " + name); return
            }
            let value = UIE2EControlGeometry(replay: frames[0], eye: frames[1], terminal: frames[2],
                row: frames.dropFirst().reduce(frames[0]) { $0.union($1) })
            if let data = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data) {
                attachJSON("GEO0-" + name, ["state": name, "geometry": object, "rowDefinition": "AX three-control envelope"])
            }
            let screens = NSScreen.screens.compactMap { screen -> CGRect? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
                return CGDisplayBounds(id)
            }
            guard frames.allSatisfy({ frame in pill.frame.contains(frame) && screens.contains(where: { $0.contains(frame) }) }),
                  replay.isHittable, eye.isHittable, terminal.isHittable else {
                XCTFail("GEO0 QA host controls clipped/off-screen or unreachable: " + name); return
            }
            geometry = value
        }
        return geometry
    }

    func geometryFlow() {
        click(app.buttons["qa-fixture-speaking"])
        guard captureGeometry("speaking-before-stop", speaking: true) != nil else { return }
        // Stop clears readback in production. Capture that actual outcome rather
        // than inventing X; completion is the transition that retains the text.
        click(app.dialogs["VoiceBar QA Pill"].buttons["Stop speaking"])
        step("GEO0 capture actual post-Stop idle") {
            let pill = app.dialogs["VoiceBar QA Pill"]
            waitUntil { !pill.buttons["Replay"].exists && !pill.buttons["Stop speaking"].exists &&
                !pill.buttons["Dismiss teleprompter"].exists }
            XCTAssertTrue(pill.exists)
            attachJSON("GEO0-actual-post-stop-idle", ["state": "actual-post-stop-idle", "panelFrame": NSStringFromRect(pill.frame),
                "controls": ["Replay": pill.buttons["Replay"].exists, "Eye": pill.buttons["Hide teleprompter"].exists,
                    "Stop": pill.buttons["Stop speaking"].exists, "X": pill.buttons["Dismiss teleprompter"].exists],
                "AX": pill.debugDescription, "comparison": "No control frames exist after Stop; no no-shift claim"])
        }
        click(app.buttons["qa-fixture-speaking"], "start silent playback before natural completion")
        guard let beforeFinish = captureGeometry("speaking-before-natural-completion", speaking: true) else { return }
        click(app.buttons["qa-fixture-finish"], "deliver natural playback-completion event")
        guard let initialReadback = captureGeometry("readback-after-natural-completion", speaking: false) else { return }
        step("GEO0 natural completion to readback stable") {
            XCTAssertTrue(initialReadback.differences(from: beforeFinish).isEmpty,
                "PRODUCT GEO0 natural completion→readback shift: " + initialReadback.differences(from: beforeFinish).joined(separator: ", "))
        }
        for index in 1...3 {
            guard let before = captureGeometry("readback-before-replay-\(index)", speaking: false) else { return }
            step("GEO0 replay readback \(index)") {
                let replay = app.dialogs["VoiceBar QA Pill"].buttons["Replay"]
                guard replay.exists, replay.isHittable else { XCTFail("GEO0 Replay unavailable"); return }
                let count = fixtureEvents().count
                replay.click() // Marked silent QA sink only.
                waitUntil { self.fixtureEvents().dropFirst(count).contains("command:replay") }
            }
            let after = captureGeometry("speaking-after-replay-\(index)", speaking: true)
            if let after {
                step("GEO0 readback to speaking stable \(index)") { XCTAssertTrue(after.differences(from: before).isEmpty,
                    "PRODUCT GEO0 readback→Replay→speaking shift: " + after.differences(from: before).joined(separator: ", ")) }
            }
            click(app.buttons["qa-fixture-finish"], "synthetic playback finish \(index)")
            if let finished = captureGeometry("readback-after-finish-\(index)", speaking: false) {
                step("GEO0 finish and repeated replay stable \(index)") {
                    if let after { XCTAssertTrue(finished.differences(from: after).isEmpty,
                        "PRODUCT GEO0 speaking→finish→readback shift: " + finished.differences(from: after).joined(separator: ", ")) }
                    XCTAssertTrue(finished.differences(from: before).isEmpty,
                        "PRODUCT GEO0 repeated readback shift: " + finished.differences(from: before).joined(separator: ", "))
                }
            }
        }
        click(app.dialogs["VoiceBar QA Pill"].buttons["Hide teleprompter"])
        step("assert Eye really hides the teleprompter") {
            XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].staticTexts["Teleprompter hidden"].waitForExistence(timeout: 3))
        }
        click(app.dialogs["VoiceBar QA Pill"].buttons["Show teleprompter"])
        step("assert Eye restores teleprompter content") {
            let pill = app.dialogs["VoiceBar QA Pill"]
            XCTAssertFalse(pill.staticTexts["Teleprompter hidden"].exists)
            XCTAssertTrue(pill.staticTexts["First"].exists || pill.buttons["First"].exists)
        }
        click(app.dialogs["VoiceBar QA Pill"].buttons["Dismiss teleprompter"])
        step("assert terminal X dismisses retained readback") {
            waitUntil { !self.app.dialogs["VoiceBar QA Pill"].buttons["Dismiss teleprompter"].exists }
        }
        // HIDE0 verifies the same panel in expanded playback and retained readback.
        for fixture in ["speaking", "readback"] {
            click(app.buttons["qa-fixture-" + fixture])
            tab("General")
            step("HIDE0 \(fixture) starts visible") { XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].exists) }
            click(app.buttons["Hide VoiceBar for 1 hour"])
            step("HIDE0 Settings hides \(fixture)") { waitUntil { !self.app.dialogs["VoiceBar QA Pill"].exists } }
            click(app.buttons["Show VoiceBar"])
            step("HIDE0 Settings restores \(fixture)") { XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].waitForExistence(timeout: 3)) }
            openContextMenu(); click(app.menuItems["Hide for 1 hour"], "HIDE0 context Hide for 1 hour " + fixture)
            receipt("menu-hide")
            step("HIDE0 context hides \(fixture)") { waitUntil { !self.app.dialogs["VoiceBar QA Pill"].exists } }
            openContextMenu(); click(app.menuItems["Show VoiceBar"], "HIDE0 context Show VoiceBar " + fixture)
            receipt("menu-show")
            step("HIDE0 context restores \(fixture)") { XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].waitForExistence(timeout: 3)) }
        }
        click(app.buttons["qa-fixture-idle"])
    }

    @discardableResult
    func openContextMenu() -> Bool {
        var opened = false
        if app.menuItems["Settings…"].exists, app.menuItems["Settings…"].isHittable {
            step("reuse the still-open QA context menu") { opened = true }
            return opened
        }
        step("right-click actual pill") {
            let pill = app.dialogs["VoiceBar QA Pill"]
            if pill.exists {
                pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
            } else {
                let hiddenMenu = app.buttons["qa-fixture-hidden-menu"]
                guard hiddenMenu.exists else { XCTFail("Neither pill nor isolated hidden-menu fixture is reachable"); return }
                hiddenMenu.click() // Real controller's Show action when the actual panel is hidden.
            }
            let marker = app.menuItems["Settings…"]
            guard marker.exists || marker.waitForExistence(timeout: 3), marker.isHittable else {
                XCTFail("QA context menu did not remain open and reachable; refusing stale/foreign menu controls")
                return
            }
            opened = true
        }
        return opened
    }

    /// The tripwire appends one install marker per process start, so each launch gets a fresh
    /// receipt. Launch 1 keeps the path the supervisor watches; relaunches never reuse a log.
    func guardReceipt(_ launch: Int) -> URL {
        root.appendingPathComponent(launch == 1 ? "no-device-guard.log" : "no-device-guard-launch-\(launch).log")
    }

    func guardReceiptIsClean(_ launch: Int) -> Bool {
        (try? String(contentsOf: guardReceipt(launch))) == "voicebar-no-device-guard-v1:installed\n"
    }

    /// The one QA launcher: the first launch and every relaunch go through here.
    func launchQA() {
        if guardRequired {
            guardLaunches += 1
            let receipt = guardReceipt(guardLaunches)
            XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path), "Guard receipt reused: \(receipt.lastPathComponent)")
            app.launchEnvironment["VOICEBAR_UIE2E_GUARD_RECEIPT"] = receipt.path
        }
        app.launch()
    }

    /// Recorded after (never inside) the launch step, so step numbering stays sequential.
    var launchEvidenceContract: String { ["hide1", "gate2246"].contains(scenario) ? "hidden-alive" : "visible" }
    func recordGuardedLaunch() {
        guard guardRequired, guardLaunches > 0 else { return }
        step("GUARD launch \(guardLaunches) installed", evidenceContract: launchEvidenceContract) {
            XCTAssertTrue(guardReceiptIsClean(guardLaunches), "Launch \(guardLaunches) lacks exactly one install marker")
        }
    }

    /// Called once the current QA process is stopped (before a relaunch, and in teardown).
    func finishGuardedLaunch() {
        guard guardRequired, guardLaunches > 0, app.state == .notRunning || app.wait(for: .notRunning, timeout: 5) else {
            if guardRequired, guardLaunches > 0 { XCTFail("QA app still running; guard launch \(guardLaunches) not finalized") }
            return
        }
        step("GUARD launch \(guardLaunches) no tripwire", evidenceContract: "terminated") {
            XCTAssertTrue(guardReceiptIsClean(guardLaunches), "Device tripwire or extra install on launch \(guardLaunches)")
        }
    }

    func relaunchQA() {
        finishGuardedLaunch()
        step("relaunch isolated QA app", evidenceContract: launchEvidenceContract) {
            launchQA()
            if ["hide1", "gate2246"].contains(scenario) {
                XCTAssertTrue(app.menuBars.menuBarItems["HIDE1VIS"].waitForExistence(timeout: 15))
            } else { XCTAssertTrue(app.windows["VoiceBar QA Settings"].waitForExistence(timeout: 15)) }
            activePage = "General"; activeHistoryScope = "Dictations"; selectedHistoryRow = "qa-recording"
        }
        recordGuardedLaunch()
    }

    func menuBarFlow() {
        defer {
            if app.state != .notRunning, app.buttons["popover-settings"].exists {
                step("dismiss remaining QA popover with Escape") { app.typeKey(.escape, modifierFlags: []) }
            }
        }
        guard openQAPopover() else { return }
        assertCopy("Copy last transcript", equals: "QA fixture transcript שלום 👋")
        guard click(app.buttons["popover-settings"]) else { return }
        receipt("popover-settings")
        guard openQAPopover() else { return }
        // Native AX collapses the inner Change identifier into its mic row.
        guard click(app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "popover-microphone", "Change default microphone in Settings")).firstMatch) else { return }
        receipt("popover-microphone")
        guard openQAPopover(), click(app.descendants(matching: .any).matching(identifier: "popover-setup").firstMatch,
            "popover Run setup") else { return }
        receipt("popover-setup")
        wizardFlow()
        guard openQAPopover(), click(app.buttons["popover-quit"], evidenceContract: "terminated") else { return }
        step("assert QA popover Quit", evidenceContract: "terminated") { XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)) }
        receipt("popover-quit", evidenceContract: "terminated")
        if app.state == .notRunning { relaunchQA() }
    }

    func openQAPopover() -> Bool {
        let marker = app.buttons["popover-settings"]
        if !marker.exists {
            guard click(app.statusItems["uie2e-status-item"], "open QA menu-bar item") else { return false }
        }
        var opened = false
        step("assert QA popover is open") {
            opened = (marker.exists || marker.waitForExistence(timeout: 3)) && marker.isHittable
            XCTAssertTrue(opened, "QA popover did not open; no further popover control will be targeted")
        }
        return opened
    }

    func contextMenuFlow() {
        defer {
            if app.state != .notRunning {
                let events = fixtureEvents()
                if let opened = events.lastIndex(of: "qa-menu-open"),
                   opened > (events.lastIndex(of: "qa-menu-close") ?? -1) {
                    step("dismiss remaining QA context menu with Escape") { app.typeKey(.escape, modifierFlags: []) }
                }
            }
        }
        for (label, intent) in [("Settings…", "menu-settings"), ("Hide for 1 hour", "menu-hide"),
                                ("Show VoiceBar", "menu-show"), ("Paste Last Transcript", "menu-paste-last"),
                                ("Re-transcribe latest", "menu-retranscribe")] {
            if intent == "menu-hide" {
                step("assert context Hide starts with visible panel") { XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].exists) }
            }
            guard openContextMenu() else { return }
            click(app.menuItems[label], "context " + label); receipt(intent)
            if intent == "menu-hide" { step("assert context Hide removes panel") { waitUntil { !self.app.dialogs["VoiceBar QA Pill"].exists } } }
            if intent == "menu-show" { step("assert context Show restores panel") { XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].waitForExistence(timeout: 3)) } }
        }
        guard openContextMenu() else { return }
        assertCopy("Copy Last Transcript", equals: "QA fixture transcript שלום 👋")
        guard openContextMenu(), openQASubmenu("Recent Transcriptions") else { return }
        click(app.menuItems["uie2e-recent-qa-recording"], "paste Recent QA fixture transcript")
        receipt("menu-paste-recent:QA fixture transcript שלום 👋")
        guard openContextMenu(), openQASubmenu("Microphone") else { return }
        step("assert read-only microphone default") {
            XCTAssertTrue(app.menuItems["uie2e-microphone-default"].exists)
            XCTAssertFalse(app.menuItems["uie2e-microphone-default"].isEnabled)
        }
        click(app.menuItems["uie2e-microphone-change"], "context Change default microphone in Settings")
        receipt("menu-microphone")
        guard openContextMenu() else { return }
        click(app.menuItems["Quit VoiceBar"], "context Quit VoiceBar", evidenceContract: "terminated")
        step("assert QA quit, no resident process targeted", evidenceContract: "terminated") { XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)) }
        receipt("menu-quit", evidenceContract: "terminated")
        attachJSON("UIE2E-MENU-LIFECYCLE", fixtureEvents())
    }

    func openQASubmenu(_ title: String) -> Bool {
        var opened = false
        step("open \(title) submenu") {
            let submenu = app.menuItems[title == "Microphone" ? "uie2e-microphone-menu" : title]
            guard submenu.exists, submenu.isHittable else {
                XCTFail("QA context submenu \(title) disappeared or is unreachable; no foreign control touched")
                return
            }
            attachJSON("UIE2E-SUBMENU-\(title)", ["frame": NSStringFromRect(submenu.frame), "AX": submenu.debugDescription])
            // Native RED: hover only highlighted the parent, then lost tracking.
            // Click the real submenu parent and require its exposed child before credit.
            submenu.click()
            let child = app.menuItems[title == "Recent Transcriptions"
                ? "uie2e-recent-qa-recording" : "uie2e-microphone-change"]
            opened = (child.exists || child.waitForExistence(timeout: 3)) && child.isHittable
            XCTAssertTrue(opened, "QA \(title) submenu child did not appear after parent activation")
        }
        return opened
    }
}
