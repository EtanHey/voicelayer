import AppKit
import XCTest

/// 2.3 lane U2, native UIE2E scenario `wings-u2` (STATUS: native run pending on the M1 test rig, 2.3 release
/// window). The isolated QA app renders the real BarView in the real FloatingPillPanel with silent fixtures: no
/// daemon, no device, no audio. Each wing state of the 3-wings mock is checked for its controls and the fixed
/// 73.5 pt wings; the chevron opens the microphone list; the badged gear opens Settings at Permissions; and a first
/// click on the pill while another app is frontmost acts without making the pill key or activating VoiceBar.
///
/// Run: bash scripts/voicebar-ui-e2e.sh --scenario wings-u2 --output "$PWD/.build.noindex/ui-e2e-wings-u2-$(date +%s)"
extension VoiceBarFlowTests {
    static let wingsU2Required = ["launcher", "chevron-list", "setup-error", "recording", "transcribing",
                                  "speaking-collapsed", "first-click", "first-click-chevron", "queued-cancel"].map { "WINGS-U2 " + $0 }

    var qaPill: XCUIElement { app.dialogs["VoiceBar QA Pill"] }

    func wingsReceipt() -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("wings.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Both wings at the fixed width the production presentation resolved for this fixture.
    func assertFixedWings(_ fixture: String) {
        let receipt = wingsReceipt()
        XCTAssertEqual(receipt?["fixture"] as? String, fixture)
        let fixed = receipt?["fixedWingWidth"] as? Double ?? -1
        XCTAssertEqual(fixed, 73.5, accuracy: 0.001)
        XCTAssertEqual(receipt?["leadingWingWidth"] as? Double ?? -1, fixed, accuracy: 0.001, "\(fixture) left wing")
        XCTAssertEqual(receipt?["trailingWingWidth"] as? Double ?? -1, fixed, accuracy: 0.001, "\(fixture) right wing")
    }

    /// Buttons in the pill's top row, split by the pill's horizontal centre (the core). One AX snapshot per call:
    /// the native 8a36d965 run spent ~1 s per element-by-element pass (13 queries x ~90 ms, twice per poll), so
    /// the 3 s wait timed out although the very next read matched (AX dump: the wings sit inside the pill dialog).
    func wingButtons() -> (left: [String], right: [String]) {
        guard let pill = try? qaPill.snapshot() else { return ([], []) }
        var buttons: [XCUIElementSnapshot] = []
        func collect(_ node: XCUIElementSnapshot) {
            if node.elementType == .button { buttons.append(node) }
            node.children.forEach(collect)
        }
        pill.children.forEach(collect)
        let row = buttons.filter { $0.frame.height > 0 && $0.frame.midY < pill.frame.minY + 40 }
        return (row.filter { $0.frame.midX < pill.frame.midX }.map(\.label),
                row.filter { $0.frame.midX > pill.frame.midX }.map(\.label))
    }

    func assertWing(_ fixture: String, left: [String], right: [String]) {
        XCTAssertTrue(qaPill.waitForExistence(timeout: 3), "QA pill")
        waitUntil({
            let wings = self.wingButtons()
            return Set(wings.left).isSuperset(of: left) && Set(wings.right).isSuperset(of: right)
        }, timeout: 10)
        let wings = wingButtons()
        for label in left { XCTAssertTrue(wings.left.contains(label), "\(fixture): \(label) on the left; got \(wings.left)") }
        for label in right { XCTAssertTrue(wings.right.contains(label), "\(fixture): \(label) on the right; got \(wings.right)") }
        XCTAssertLessThanOrEqual(wings.right.count, 2, "\(fixture): never a third right-wing control: \(wings.right)")
        assertFixedWings(fixture)
    }

    func firstClickReceipts() -> [[String: Any]] { uie2eFirstClickReceipts(root) }

    func assertFirstClickInactive(_ records: [[String: Any]], _ control: String) {
        XCTAssertFalse(records.isEmpty, "\(control): the host recorded the mouse-down on the pill")
        for record in records {
            XCTAssertEqual(record["appActive"] as? Bool, false, "\(control): VoiceBar was not active at click time: \(record)")
            XCTAssertEqual(record["pillKey"] as? Bool, false, "\(control): the pill was not key at click time: \(record)")
        }
    }

    func testWingsU2Flow() throws {
        guard scenario == "wings-u2" else { throw NSError(domain: "UIE2E wings-u2 test selected outside its scenario", code: 1) }
        limitations = ["Silent fixtures drive VoiceState; the mic button is located but never pressed (the harness forbids audio actions).",
                       "The QA pill sits top-right (isolated capture placement), not in the notch; the wing widths come from the production presentation (wings.json)."]
        // A focused scenario: scope the ledger to U2 (not the full flow's surfaces), and on a GATE2245 build carry the
        // same no-device guard receipts as every other gate run (voicebar-ui-e2e-results.py guard_receipt_steps).
        ledger.requiredScope = ["wings:U2"]
        if gate2245Enabled {
            step("GATE2245 no-device guard installed before fixtures") { XCTAssertTrue(guardReceiptIsClean(guardLaunches)) }
        }

        click(app.buttons["qa-fixture-launcher"])
        step("WINGS-U2 launcher") {
            assertWing("launcher", left: ["Start voice recording", "Choose microphone"], right: ["History", "Settings"])
        }

        let beforeList = fixtureEvents().count
        click(qaPill.buttons["Choose microphone"], "open the microphone list from the chevron")
        step("WINGS-U2 chevron-list") {
            waitUntil { self.fixtureEvents().dropFirst(beforeList).contains("microphone-list-open") }
            XCTAssertTrue(app.menuItems["Microphone priority…"].waitForExistence(timeout: 3), "list footer")
            XCTAssertTrue(app.menuItems["QA microphone A"].exists, "priority rows listed")
            XCTAssertTrue(app.menuItems["QA microphone B"].exists, "priority rows listed")
        }
        let beforePriority = fixtureEvents().count
        click(app.menuItems["Microphone priority…"], "Microphone priority… opens Settings")
        step("assert Microphone priority… routes to Settings, never a write") {
            waitUntil { self.fixtureEvents().dropFirst(beforePriority).contains("menu-microphone") }
            XCTAssertFalse(fixtureEvents().dropFirst(beforePriority).contains("microphone-order"))
        }

        click(app.buttons["qa-fixture-setup-error"])
        step("WINGS-U2 setup-error") {
            let gear = qaPill.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Settings. Accessibility is off")).firstMatch
            XCTAssertTrue(gear.waitForExistence(timeout: 3), "the gear names the problem")
            XCTAssertEqual(wingsReceipt()?["setupNeedsAttention"] as? Bool, true)
            assertWing("setup-error", left: ["Start voice recording", "Choose microphone"], right: ["History", gear.label])
        }
        let beforeSetup = fixtureEvents().count
        click(qaPill.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Settings. ")).firstMatch,
              "badged gear opens the setup spot")
        step("assert Settings › General at Permissions") {
            waitUntil { self.fixtureEvents().dropFirst(beforeSetup).contains("setup-settings") }
            // General's permission rows sit under "Finish setup" while one is broken (SettingsGeneralSetup.header);
            // there is no "Permissions" heading. The broken row the gear named must be on screen and reachable.
            let settings = app.windows["VoiceBar QA Settings"]
            XCTAssertTrue(settings.staticTexts["Finish setup"].waitForExistence(timeout: 3), "the setup section heads General")
            let broken = settings.buttons["Open System Settings: Accessibility"]
            XCTAssertTrue(broken.waitForExistence(timeout: 3), "the Accessibility row offers its fix")
            XCTAssertTrue(broken.isHittable, "scrolled to the broken rows")
            activePage = "General"
        }

        click(app.buttons["qa-fixture-recording"])
        step("WINGS-U2 recording") {
            assertWing("recording", left: ["Stop recording", "Cancel recording"], right: [])
        }
        let beforeCancel = fixtureEvents().count
        click(qaPill.buttons["Cancel recording"], "Cancel from the left wing")
        step("assert Cancel dispatched once") {
            waitUntil { self.fixtureEvents().dropFirst(beforeCancel).contains("command:cancel") }
        }

        click(app.buttons["qa-fixture-transcribing"])
        step("WINGS-U2 transcribing") {
            assertWing("transcribing", left: [], right: ["History", "Settings"])
            XCTAssertFalse(qaPill.buttons["Cancel transcription"].exists, "no third control while transcribing")
        }

        click(app.buttons["qa-fixture-speaking-collapsed"])
        step("WINGS-U2 speaking-collapsed") {
            assertWing("speaking-collapsed", left: ["Pause speech"], right: ["Show teleprompter", "Stop speaking"])
        }

        // First click while another app is frontmost (PILL1 + the U2 regression guard).
        click(app.buttons["qa-fixture-launcher"])
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        step("activate Finder so VoiceBar QA is not frontmost") {
            try mutate { finder.activate() }
            XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        }
        let beforeFirst = fixtureEvents().count
        step("WINGS-U2 first-click") {
            let history = qaPill.buttons["History"]
            XCTAssertTrue(history.waitForExistence(timeout: 3))
            let beforeClicks = firstClickReceipts().count
            try mutate { try XCTUnwrap(uie2eForegroundPoint(history, via: finder), "Finder anchor").click() }
            waitUntil { self.qaPill.buttons["Close history"].exists }
            XCTAssertTrue(qaPill.buttons["Close history"].exists, "the first click acted")
            assertFirstClickInactive(Array(firstClickReceipts().dropFirst(beforeClicks)), "History")
            XCTAssertEqual(finder.state, .runningForeground, "the first click left Finder frontmost")
            XCTAssertFalse(fixtureEvents().dropFirst(beforeFirst).contains("pill-became-key"),
                           "the first click did not make the pill key")
        }
        // The chevron's first click, from Finder, with History still open (U2 review R1: History is NOT closed by
        // the test). The production handoff closes History first, then shows the list once the view reports it.
        step("re-activate Finder before the chevron's first click, History open") {
            XCTAssertTrue(qaPill.buttons["Close history"].exists, "History is open")
            try mutate { finder.activate() }
            XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        }
        let beforeChevron = fixtureEvents().count
        step("WINGS-U2 first-click-chevron") {
            let chevron = qaPill.buttons["Choose microphone"]
            XCTAssertTrue(chevron.waitForExistence(timeout: 3))
            let beforeClicks = firstClickReceipts().count
            try mutate { try XCTUnwrap(uie2eForegroundPoint(chevron, via: finder), "Finder anchor").click() }
            waitUntil { self.fixtureEvents().dropFirst(beforeChevron).contains("microphone-list-open") }
            XCTAssertTrue(app.menuItems["Microphone priority…"].waitForExistence(timeout: 3), "the first click acted")
            XCTAssertFalse(qaPill.buttons["Close history"].exists, "History closed before the list showed")
            assertFirstClickInactive(Array(firstClickReceipts().dropFirst(beforeClicks)), "chevron")
            XCTAssertEqual(finder.state, .runningForeground, "opening the list left Finder frontmost")
            XCTAssertFalse(fixtureEvents().dropFirst(beforeChevron).contains("pill-became-key"),
                           "the first click did not make the pill key")
        }
        // The list was opened without activating VoiceBar QA. XCUIElement.click() would activate it first, which
        // dismisses the open menu before the click lands, so close it through the same Finder-anchored path.
        let beforeFooter = fixtureEvents().count
        step("close the list through its footer") {
            let footer = app.menuItems["Microphone priority…"]
            XCTAssertTrue(footer.waitForExistence(timeout: 3), "the list is still open")
            try mutate { try XCTUnwrap(uie2eForegroundPoint(footer, via: finder), "Finder anchor").click() }
            waitUntil { self.fixtureEvents().dropFirst(beforeFooter).contains("menu-microphone") }
            XCTAssertFalse(app.menuItems["Microphone priority…"].exists, "the list closed")
        }
        // The first-click cases left VoiceBar QA inactive on purpose. Restore the foreground state the remaining
        // ordinary clicks assume; otherwise XCUITest reports the app's own window-sharing dialog as an interruption.
        foregroundQA()

        // Queued-presentation cancellation through the production handoff: the scheduled presentation is held,
        // the user opens History in the gap, and the released block must show nothing.
        click(app.buttons["qa-fixture-launcher"])
        click(app.buttons["qa-fixture-hold-menu-queue"], "hold scheduled menu presentations")
        let beforeQueue = fixtureEvents().count
        click(qaPill.buttons["Choose microphone"], "request the list (presentation held)")
        step("assert the list is queued, not shown") {
            waitUntil { self.fixtureEvents().dropFirst(beforeQueue).contains("microphone-list-queued") }
            XCTAssertFalse(app.menuItems["Microphone priority…"].exists)
        }
        click(qaPill.buttons["History"], "open History in the gap")
        click(app.buttons["qa-fixture-release-menu-queue"], "release the held presentation")
        step("WINGS-U2 queued-cancel") {
            waitUntil { self.fixtureEvents().dropFirst(beforeQueue).contains("microphone-list-cancelled") }
            XCTAssertFalse(fixtureEvents().dropFirst(beforeQueue).contains("microphone-list-open"), "nothing showed")
            XCTAssertFalse(app.menuItems["Microphone priority…"].exists, "no list over History")
            XCTAssertTrue(qaPill.buttons["Close history"].exists, "History stayed open")
        }
        click(qaPill.buttons["Close history"], "close History")
        click(app.buttons["qa-fixture-idle"])
        if gate2245Enabled {
            step("GATE2245 no device-start or process tripwire invoked") { XCTAssertTrue(guardReceiptIsClean(guardLaunches)) }
        }
        if (testRun?.failureCount ?? 1) == 0 { ledger.verifiedSurfaces.insert("wings:U2") }
        completed = true
    }
}

/// The host's first-click receipts (UIE2EHost.installFirstClickReceipts): one record per mouse-down on the pill.
func uie2eFirstClickReceipts(_ root: URL) -> [[String: Any]] {
    guard let data = try? Data(contentsOf: root.appendingPathComponent("first-click.json")) else { return [] }
    return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
}

/// A point on `target`, addressed through the frontmost app's menu bar. XCUIElement.click() and hover() first
/// "Activate" the element's own application (8a36d965 test.log, step 33), which makes Finder's state and
/// NSApp.isActive useless as a first-click oracle. Anchored on Finder, XCUITest activates Finder (already
/// frontmost) and the synthesized event lands on whatever window is topmost at that point: the pill.
func uie2eForegroundPoint(_ target: XCUIElement, via frontmost: XCUIApplication) -> XCUICoordinate? {
    guard target.exists else { return nil }
    let frame = target.frame
    return uie2eForegroundPoint(CGPoint(x: frame.midX, y: frame.midY), via: frontmost)
}

/// A screen point addressed through the frontmost app's menu bar (see above).
func uie2eForegroundPoint(_ point: CGPoint, via frontmost: XCUIApplication) -> XCUICoordinate? {
    let anchor = frontmost.menuBars.firstMatch
    guard anchor.exists else { return nil }
    let anchorFrame = anchor.frame
    return anchor.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: point.x - anchorFrame.minX, dy: point.y - anchorFrame.minY))
}
