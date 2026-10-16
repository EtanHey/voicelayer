import AppKit
import XCTest

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
        guard ["full", "focused-338"].contains(scenario) else { throw NSError(domain: "UIE2E invalid scenario", code: 1) }
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
        app.launchEnvironment = ["VOICEBAR_UIE2E": "1", "VOICEBAR_UIE2E_SCENARIO": scenario, "VOICEBAR_UIE2E_ROOT": root.path,
            "HOME": root.appendingPathComponent("home").path, "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
            "VOICEBAR_USER_DEFAULTS_SUITE": "com.voicelayer.uie2e.\(root.lastPathComponent)",
            "VOICELAYER_SOCKET_PATH": root.appendingPathComponent("v.sock").path,
            "VOICELAYER_MCP_SOCKET_PATH": root.appendingPathComponent("m.sock").path]
        addUIInterruptionMonitor(withDescription: "Known benign foreign overlay; never grant permissions") { [unowned self] alert in
            switch UIE2EInterruptionPolicy.classify(alertDescription: alert.debugDescription) {
            case .permissionPrompt:
                XCTFail("BLOCKED permission prompt: \(alert.debugDescription)")
                return false
            case .qaOwnedInterruption:
                XCTFail("BLOCKED QA-owned modal interruption; resolve the scoped QA control instead of treating its sheet as foreign: \(alert.debugDescription)")
                return false
            case let .knownBenignForeign(owner):
                let foreign = XCUIApplication(bundleIdentifier: owner)
                let foreignState = foreign.state
                let processState: UIE2EInterruptionProcessState
                switch foreignState {
                case .runningForeground, .runningBackground: processState = .running
                case .notRunning: processState = .notRunning
                default: processState = .unknown
                }
                // The AX hierarchy is only queried inside this state-gated closure.
                // A stale XCUIApplication handle for an exited owner can fatally fail XCTest.
                guard let hasMatchingDialog = UIE2EInterruptionPolicy.queryHierarchyIfRunning(state: processState, {
                    foreign.dialogs.allElementsBoundByIndex.contains { $0.frame == alert.frame }
                }) else {
                    XCTFail("BLOCKED known overlay owner is not queryable (state: \(foreignState)): \(owner)")
                    return false
                }
                guard hasMatchingDialog else {
                    XCTFail("BLOCKED known overlay did not match the interruption frame: \(owner), \(alert.debugDescription)")
                    return false
                }
                self.app.activate() // Recover focus only; no foreign buttons, dismissal or permission action.
                let clear = self.app.state == .runningForeground && self.app.windows["VoiceBar QA Settings"].isHittable
                if !clear { XCTFail("BLOCKED benign foreign overlay persists after QA activation: \(owner)") }
                return clear
            case let .unknown(owner):
                XCTFail("BLOCKED unknown interruption owner \(owner ?? "(unavailable)"): \(alert.debugDescription)")
                return false
            }
        }
        step("launch isolated QA app") {
            app.launch()
            app.activate()
            XCTAssertTrue(app.windows["VoiceBar QA Settings"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.state, .runningForeground)
        }
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
        if app != nil, app.state != .notRunning { step("terminate QA app") { app.terminate() } }
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
    func step(_ name: String, skipped: String? = nil, _ body: () -> Void) {
        let number = steps.count + 1
        let attachment = String(format: "UIE2E-%04d", number)
        let before = testRun?.failureCount ?? 0
        XCTContext.runActivity(named: "\(attachment) \(name)") { activity in
            body()
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = attachment
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
        }
        let passed = (testRun?.failureCount ?? 0) == before
        var receipt: [String: Any] = ["number": number, "name": name, "attachment": attachment, "passed": passed]
        if let skipped { receipt["skipped"] = skipped }
        steps.append(receipt)
        print("UIE2E \(passed ? "PASS" : "FAIL") \(number) \(name)")
        // Individual receipts survive an aborted method; only the final ledger can complete a run.
        attachJSON(String(format: "UIE2E-RECEIPT-%04d", number), receipt)
    }

    @discardableResult
    func click(_ resolve: @autoclosure () -> XCUIElement, _ name: String? = nil,
               revealPolicy: UIE2EClickRevealPolicy = .automatic) -> Bool {
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
        step(name ?? "click \(label)") {
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
    func testFullUIOnlyFlow() throws {
        generalFlow()
        transcriptionFlow()
        dictionaryFlow()
        speechFlow()
        historyFlow()
        pillFlow()
        menuBarFlow()
        contextMenuFlow()
        step("all observed non-audio Settings controls exercised") {
            let missing = observed.subtracting(exercised).sorted()
            XCTAssertTrue(missing.isEmpty, "Unexercised controls: \(missing.joined(separator: ", "))")
        }
        completed = true
    }
}

extension VoiceBarFlowTests {
    func controlValue(_ element: XCUIElement) -> String? {
        if let number = element.value as? NSNumber { return number.stringValue }
        return element.value as? String
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
        if activePage == "History" {
            let selector = element.elementType == .radioButton && ["Ask", "Dictations"].contains(label)
            context.scope = selector ? "scope-selector" : activeHistoryScope
            if label.hasPrefix("QA fixture transcript") { context.row = "qa-recording" }
            else if label.hasPrefix("QA older transcript") { context.row = "qa-older" }
            else if ["Copy transcript", "Paste transcript", "Re-transcribe stored audio", "Open stored audio in Finder",
                     "Copy recording details", "Copied recording details"].contains(label) {
                context.row = activeHistoryScope == "Ask" ? "qa-ask-response" : selectedHistoryRow
            }
        }
        if activePage == "Dictionary" {
            for prefix in ["Edit term ", "Delete term ", "Copy term ", "Copied term "] where label.hasPrefix(prefix) {
                context.row = String(label.dropFirst(prefix.count))
            }
            if ["Cancel", "Save", "Delete?", "Correct spelling", "Misheard as"].contains(label) {
                context.row = editingDictionaryRow
            }
        }
        if activePage == "Speech", element.elementType == .popUpButton || element.elementType == .slider || label.contains("daemon command") {
            context.profile = speechProfile(element)
        }
        return ledger.key(role: String(element.elementType.rawValue), identity: identity, context: context)
    }

    func speechProfile(_ element: XCUIElement) -> String {
        let point = CGPoint(x: element.frame.midX, y: element.frame.midY)
        for kind in ["short", "long"] {
            for field in ["voice", "rate"] {
                let group = app.descendants(matching: .any)["speech-\(kind).\(field)"]
                if group.exists && group.frame.contains(point) { return kind }
            }
        }
        let long = app.staticTexts["Long reads"].firstMatch
        if long.exists && !long.frame.isEmpty && point.y >= long.frame.minY { return "long" }
        let short = app.staticTexts["Short speaks"].firstMatch
        if short.exists && !short.frame.isEmpty && point.y >= short.frame.minY { return "short" }
        XCTFail("Cannot resolve Speech profile for \(element.label); refusing a shared coverage identity")
        return "unresolved-profile"
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
        for type: XCUIElement.ElementType in [.button, .checkBox, .radioButton, .popUpButton, .slider, .textField, .disclosureTriangle] {
            for element in window.descendants(matching: type).allElementsBoundByIndex where element.isEnabled && element.isHittable {
                let label = element.label.lowercased()
                if element.identifier.hasPrefix("qa-fixture-") || label.hasPrefix("copied") { continue }
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
    func receipt(_ expected: String) {
        step("assert intent \(expected)") {
            do {
                let events = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("events.json")))
                XCTAssertTrue(events.contains(expected), "Missing fixture intent: \(expected)")
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
        for key in ["model_polish", "outro_gate", "smart_chunks", "smart_boundaries"] {
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
        let payload = activeHistoryScope == "Ask" ? "QA response" :
            selectedHistoryRow == "qa-older" ? "QA older transcript" : "QA fixture transcript שלום 👋"
        let missing = window.buttons["UIE2E-missing-\(activeHistoryScope)-\(selectedHistoryRow)-\(label)"]
        guard selector.exists, selector.isSelected || selector.value as? String == "1" else {
            XCTFail("History scope \(activeHistoryScope) is not selected"); return missing
        }
        // Dictations' list rows are buttons; only its detail has the static transcript.
        // Ask's matching response text scopes the response controls independently of Dictations.
        let anchor = NSPredicate(format: "elementType == %d AND label CONTAINS %@",
                                 XCUIElement.ElementType.staticText.rawValue, payload)
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
                XCTAssertEqual(Array(events.dropFirst(before)), ["history-paste:" + expected])
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
        click(app.buttons["Refresh history"])
        click(app.buttons["Jump to latest"])
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
        click(app.buttons["Refresh ask history"])
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
                             ("error", "QA fixture failure"), ("disconnected", "VoiceLayer")] {
            click(app.buttons["qa-fixture-\(name)"])
            receipt("fixture:" + name)
            step("assert actual pill \(name) content") {
                let pill = app.windows["VoiceBar QA Pill"]
                XCTAssertTrue(pill.exists)
                XCTAssertTrue(pill.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists,
                              pill.debugDescription)
            }
            if name == "error" { click(app.buttons["Dismiss error"]) }
        }
        let feedback = [("paste-not-inserted", "Not inserted — transcript kept in History. Click input and press Shift+F5, or Copy."),
                        ("paste-unverified", "Insertion unverified — transcript kept in History. Check the input before retrying or Copy."),
                        ("paste-partial", "Partially inserted — full transcript kept in History. Check the input before retrying or Copy.")]
        if !app.buttons["qa-fixture-paste-not-inserted"].exists { skipCapability("P1b #338 not in this build") }
        else {
            knownVisualGaps.append("P1b pill feedback visibly truncates despite full AX text (native walkthrough rc-2.2.44). AX assertions below check content only; full-text visual readability is NOT_PROVEN.")
            for (name, expected) in feedback {
                click(app.buttons["qa-fixture-\(name)"])
                step("assert P1b AX content only \(name)") {
                    XCTAssertTrue(app.windows["VoiceBar QA Pill"].descendants(matching: .any)
                        .matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch.exists)
                }
            }
        }
        click(app.buttons["qa-fixture-idle"])
    }

    func openContextMenu() {
        step("right-click actual pill") {
            let pill = app.windows["VoiceBar QA Pill"]
            XCTAssertTrue(pill.exists)
            pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
            XCTAssertTrue(app.menuItems["Settings…"].waitForExistence(timeout: 3))
        }
    }

    func menuBarFlow() {
        let status = app.menuBars.menuBarItems["VoiceBar QA"]
        click(status, "open QA menu-bar item")
        assertCopy("Copy last transcript", equals: "QA fixture transcript שלום 👋")
        click(app.buttons["popover-settings"])
        receipt("popover-settings")
        click(status, "reopen QA menu-bar item")
        click(app.buttons["popover-microphone-change"])
        receipt("popover-microphone")
        click(status, "reopen QA menu-bar item")
        click(app.buttons["Run setup…"])
        receipt("popover-setup")
        click(status, "reopen QA menu-bar item")
        click(app.buttons["popover-quit"])
        step("assert QA popover Quit") { XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)) }
        receipt("popover-quit")
        step("relaunch isolated QA app for context-menu flow") {
            app.launch()
            XCTAssertTrue(app.windows["VoiceBar QA Settings"].waitForExistence(timeout: 15))
        }
    }

    func contextMenuFlow() {
        for (label, intent) in [("Settings…", "menu-settings"), ("Hide for 1 hour", "menu-hide"),
                                ("Show VoiceBar", "menu-show"), ("Paste Last Transcript", "menu-paste-last"),
                                ("Re-transcribe latest", "menu-retranscribe")] {
            openContextMenu(); click(app.menuItems[label]); receipt(intent)
        }
        openContextMenu()
        assertCopy("Copy Last Transcript", equals: "QA fixture transcript שלום 👋")
        openContextMenu()
        step("open Recent Transcriptions submenu") { app.menuItems["Recent Transcriptions"].hover() }
        click(app.menuItems.matching(NSPredicate(format: "label CONTAINS 'QA fixture transcript'")).firstMatch)
        receipt("menu-paste-recent:QA fixture transcript שלום 👋")
        openContextMenu()
        step("open Microphone submenu") { app.menuItems["Microphone"].hover() }
        step("assert read-only microphone default") {
            XCTAssertTrue(app.menuItems["Default: QA microphone A"].exists)
            XCTAssertFalse(app.menuItems["Default: QA microphone A"].isEnabled)
        }
        click(app.menuItems["Change default microphone in Settings"])
        receipt("menu-microphone")
        openContextMenu()
        click(app.menuItems["Quit VoiceBar"])
        step("assert QA quit, no resident process targeted") { XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)) }
        receipt("menu-quit")
    }
}
