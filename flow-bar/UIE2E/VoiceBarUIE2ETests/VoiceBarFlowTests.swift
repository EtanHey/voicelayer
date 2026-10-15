import AppKit
import XCTest

/// The one serial UI test runs only through voicebar-ui-e2e.sh on an unoccupied Mac.
@MainActor
final class VoiceBarFlowTests: XCTestCase {
    var app: XCUIApplication!
    var root: URL!
    var steps: [[String: Any]] = []
    var ledger = UIE2ECoverageLedger()
    var observed: Set<String> { get { ledger.observed } set { ledger.observed = newValue } }
    var exercised: Set<String> { get { ledger.exercised } set { ledger.exercised = newValue } }
    var activePage = "General"
    var activeHistoryScope = "Dictations"
    var selectedHistoryRow = "qa-recording"
    var editingDictionaryRow: String?
    var pasteboardSaved = false
    var pasteboardItems: [[NSPasteboard.PasteboardType: Data]] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
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
        app.launchEnvironment = ["VOICEBAR_UIE2E": "1", "VOICEBAR_UIE2E_ROOT": root.path,
            "HOME": root.appendingPathComponent("home").path, "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
            "VOICEBAR_USER_DEFAULTS_SUITE": "com.voicelayer.uie2e.\(root.lastPathComponent)",
            "VOICELAYER_SOCKET_PATH": root.appendingPathComponent("v.sock").path,
            "VOICELAYER_MCP_SOCKET_PATH": root.appendingPathComponent("m.sock").path]
        step("launch isolated QA app") {
            app.launch()
            XCTAssertTrue(app.windows["VoiceBar QA Settings"].waitForExistence(timeout: 15))
        }
    }

    override func tearDownWithError() throws {
        if app != nil, app.state != .notRunning { step("terminate QA app") { app.terminate() } }
        guard pasteboardSaved else { return }
        NSPasteboard.general.clearContents()
        let restored = pasteboardItems.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { XCTAssertTrue(NSPasteboard.general.writeObjects(restored)) }
        try saveSteps()
    }

    func saveSteps() throws {
        guard root != nil else { return }
        try JSONSerialization.data(withJSONObject: steps, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("steps.json"), options: .atomic)
    }

    /// All input operations go through this wrapper, including scrolling, typing and menu dismissal.
    /// A failed assertion/action still produces a keepAlways attachment and a FAIL receipt.
    func step(_ name: String, _ body: () -> Void) {
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
        steps.append(["number": number, "name": name, "attachment": attachment, "passed": passed])
        print("UIE2E \(passed ? "PASS" : "FAIL") \(number) \(name)")
        do { try saveSteps() } catch { XCTFail("Cannot save action receipt: \(error)") }
    }

    @discardableResult
    func click(_ element: XCUIElement, _ name: String? = nil) -> Bool {
        var clicked = false
        if !element.isHittable, app.menus.count == 0 { reveal(element) }
        step(name ?? "click \(element.label)") {
            guard element.waitForExistence(timeout: 4), element.isEnabled, element.isHittable else {
                XCTFail("Missing, disabled or unreachable: \(element.debugDescription)"); return
            }
            let forbidden = ["preview", "play", "replay", "speak", "ask", "start voice recording"]
            let audioLabel = element.label.lowercased()
            let audioAction = forbidden.contains(audioLabel) || ["play ", "preview ", "replay ", "speak ", "ask "].contains { audioLabel.hasPrefix($0) }
            guard !(audioAction && element.elementType != .radioButton) else { XCTFail("Forbidden audio action"); return }
            let key = controlKey(element)
            let label = element.label
            let type = element.elementType
            element.click(); exercised.insert(key); clicked = true
            didActivate(label: label, type: type)
        }
        return clicked
    }

    func replace(_ field: XCUIElement, _ value: String) {
        guard click(field, "focus \(field.label)") else { return }
        step("select field contents") { field.typeKey("a", modifierFlags: .command) }
        step("type \(value)") { field.typeText(value) }
    }

    func tab(_ name: String) {
        click(app.windows["VoiceBar QA Settings"].staticTexts[name].firstMatch, "open \(name) tab")
        step("assert \(name) tab") { XCTAssertTrue(app.windows["VoiceBar QA Settings"].exists) }
    }

    func scroll(_ direction: CGFloat, times: Int = 6) {
        let area = app.windows["VoiceBar QA Settings"].scrollViews.allElementsBoundByIndex.last
        for index in 1...times {
            step("scroll \(direction > 0 ? "up" : "down") \(index)") {
                guard let area else { XCTFail("Missing Settings scroll view"); return }
                area.scroll(byDeltaX: 0, deltaY: direction * 420)
                observeControls()
            }
        }
    }

    func assertCopy(_ label: String, equals expected: String? = nil, contains required: String? = nil, target: XCUIElement? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("UIE2E clipboard sentinel", forType: .string)
        let element = target ?? (app.menuItems[label].exists ? app.menuItems[label] : app.buttons[label].firstMatch)
        guard click(element) else { return }
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
            let ledger = ["observed": observed.sorted(), "exercised": exercised.sorted(), "missing": missing]
            do { try JSONSerialization.data(withJSONObject: ledger, options: .prettyPrinted)
                .write(to: root.appendingPathComponent("coverage.json"), options: .atomic) }
            catch { XCTFail("Cannot write coverage ledger: \(error)") }
        }
        try Data("complete\n".utf8).write(to: root.appendingPathComponent("completed"), options: .atomic)
    }
}

extension VoiceBarFlowTests {
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

    func reveal(_ element: XCUIElement) {
        for direction: CGFloat in [-1, 1] {
            for _ in 0..<7 {
                if element.exists && element.isHittable { return }
                scroll(direction, times: 1)
            }
        }
    }

    func walk(_ name: String) {
        tab(name)
        step("inventory \(name) controls") { observeControls() }
        scrollFully(-1)
        scrollFully(1)
    }

    func scrollFully(_ direction: CGFloat) {
        let area = app.windows["VoiceBar QA Settings"].scrollViews.allElementsBoundByIndex.last
        func signature() -> [String] {
            area?.descendants(matching: .any).allElementsBoundByIndex.map {
                "\($0.elementType.rawValue)|\($0.label)|\($0.frame)|\(String(describing: $0.value))"
            } ?? []
        }
        var before = signature()
        var stable = 0
        for _ in 0..<16 {
            scroll(direction, times: 1)
            let after = signature()
            stable = before == after ? stable + 1 : 0
            if stable >= 2 { return }
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
        click(app.buttons["Hide VoiceBar for 1 hour"])
        receipt("hide")
        click(app.buttons["Show VoiceBar"])
        receipt("show")
        click(app.buttons["Make default"].firstMatch)
        receipt("microphone-order")
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
        click(app.buttons["View history →"])
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
        let disclosure = app.disclosureTriangles.firstMatch
        click(disclosure, "expand recognizer details")
        step("historical effort is a fact, no effort picker") {
            XCTAssertTrue(app.staticTexts["Configured effort"].exists)
            XCTAssertFalse(app.popUpButtons["models-effort-picker"].exists)
        }
        click(disclosure, "collapse recognizer details")
        for key in ["model_polish", "outro_gate", "smart_chunks", "smart_boundaries"] {
            let toggle = app.checkBoxes["models-processing-\(key)"]
            let before = toggle.value as? String
            click(toggle, "toggle \(key)")
            step("assert \(key) changed") { XCTAssertNotEqual(toggle.value as? String, before) }
            click(toggle, "restore \(key)")
            step("assert \(key) restored") { XCTAssertEqual(toggle.value as? String, before) }
        }
        assertCopy("Copy recognizer error", equals: "QA recognizer failure\nSecond line")
    }

    func dictionaryEntries() -> [[String: Any]] {
        do { return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("dictionary.json"))) as? [[String: Any]] ?? [] }
        catch { XCTFail("Missing fixture dictionary: \(error)"); return [] }
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
        click(app.buttons["Cancel"])
        click(app.buttons["Delete term QA initial"])
        click(app.buttons["Cancel"])
        click(app.buttons["Add term"])
        replace(app.textFields["Correct spelling"], "QA new term")
        replace(app.textFields["Misheard as"], "qa misheard")
        click(app.buttons["Swap correct and misheard text"])
        click(app.buttons["Swap correct and misheard text"])
        click(app.buttons["Add"])
        assertTerm("QA new term", variants: ["qa misheard"])
        assertCopy("Copy term QA new term", equals: "QA new term")
        click(app.buttons["Edit term QA new term"])
        replace(app.textFields["Misheard as"], "qa second variant")
        click(app.buttons["Save"])
        assertTerm("QA new term", variants: ["qa misheard", "qa second variant"])
        click(app.buttons["Edit term QA new term"])
        replace(app.textFields["Correct spelling"], "QA cancelled rename")
        click(app.buttons["Cancel"])
        assertTerm("QA new term", variants: ["qa misheard", "qa second variant"])
        click(app.buttons["Edit term QA new term"])
        replace(app.textFields["Correct spelling"], "QA renamed term")
        click(app.buttons["Save"])
        assertTerm("QA renamed term", variants: ["qa misheard", "qa second variant"])
        assertTerm("QA new term", variants: nil, exists: false)
        click(app.buttons["Edit term QA renamed term"])
        click(app.buttons["Remove misheard spelling qa misheard"])
        click(app.buttons["Save"])
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
        click(app.buttons["Delete term QA renamed term"])
        click(app.buttons["Cancel"])
        assertTerm("QA renamed term", variants: ["qa second variant"])
        click(app.buttons["Delete term QA renamed term"])
        click(app.buttons["Delete?"])
        assertTerm("QA renamed term", variants: nil, exists: false)
        click(app.buttons["Add term"])
        click(app.buttons["Cancel"])
    }

    func speechFlow() {
        walk("Speech")
        for index in 0..<2 {
            let picker = app.popUpButtons.element(boundBy: index)
            click(picker, "open grouped voice list \(index)")
            step("Fast and Cloned groups with Theo and fixture-ready Ben") {
                XCTAssertTrue(app.menuItems["Fast"].exists)
                XCTAssertTrue(app.menuItems["Cloned"].exists)
                XCTAssertTrue(app.menuItems["Theo"].exists)
                XCTAssertTrue(app.menuItems["Ben"].exists)
            }
            click(app.menuItems["Ben"], "select ready Ben fixture \(index)")
            step("assert Ben selection \(index)") { XCTAssertTrue(picker.value as? String == "Ben" || picker.label.contains("Ben")) }
            let slider = app.sliders.element(boundBy: index)
            reveal(slider)
            step("change speech rate \(index)") {
                guard slider.exists, slider.isHittable else { XCTFail("Missing speech rate slider"); return }
                slider.adjust(toNormalizedSliderPosition: 0.75)
                exercised.insert(controlKey(slider))
            }
        }
        let threshold = app.textFields["Long-read threshold in characters"]
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
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'fast voice (fallback)' ")).firstMatch.exists)
            for kind in ["short", "long"] { XCTAssertFalse(app.buttons["speech-\(kind)-preview"].isEnabled) }
        }
        speechCopyFlow()
    }

    func skipCapability(_ reason: String) {
        step(reason) {}
        steps[steps.count - 1]["skipped"] = reason
        print("UIE2E SKIP: \(reason)")
        do { try saveSteps() } catch { XCTFail("Cannot save capability skip") }
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

    func assertHistoryPaste(_ expected: String) {
        var before = 0
        step("snapshot paste sink before \(activeHistoryScope) paste") {
            do { before = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("events.json"))).count }
            catch { XCTFail("Cannot read paste sink: \(error)") }
        }
        guard click(app.buttons["Paste transcript"], "paste \(activeHistoryScope) \(selectedHistoryRow)") else { return }
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
        assertCopy("Copy transcript", equals: "QA fixture transcript שלום 👋")
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA older transcript'")).firstMatch, "select specific older row")
        assertCopy("Copy transcript", equals: "QA older transcript")
        assertHistoryPaste("QA older transcript")
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA fixture transcript'")).firstMatch, "restore latest row before metadata assertions")
        assertHistoryPaste("QA fixture transcript שלום 👋")
        click(app.buttons["Re-transcribe stored audio"])
        receipt("history-retranscribe")
        click(app.buttons["Open stored audio in Finder"])
        receipt("history-finder")
        assertCopy("Copy recording details", contains: "Model: QA recognizer\nEffort: accurate")
        click(app.buttons["Load more"])
        click(app.buttons["Refresh history"])
        click(app.buttons["Jump to latest"])
        replace(app.textFields["Search transcripts"], "no-match-uie2e")
        step("recording history search empty state") { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: app.buttons["Copy transcript"])], timeout: 4), .completed) }
        click(app.buttons["Clear search"].firstMatch)
        // This is the history scope selector, never an audio Ask operation.
        click(app.radioButtons["Ask"], "open Ask history scope")
        step("inventory Ask response controls") { observeControls() }
        assertCopy("Copy transcript", equals: "QA response")
        assertHistoryPaste("QA response")
        click(app.buttons["Load older ask history"])
        click(app.buttons["Refresh ask history"])
        replace(app.textFields["Search questions and answers"], "no-match-uie2e")
        step("ask history search empty state") { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: app.buttons["Copy transcript"])], timeout: 4), .completed) }
        click(app.buttons["Clear search"].firstMatch)
        click(app.radioButtons["Dictations"])
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
            for (name, expected) in feedback {
                click(app.buttons["qa-fixture-\(name)"])
                step("assert P1b paste feedback \(name)") {
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
