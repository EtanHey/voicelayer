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
                                  "speaking-collapsed", "first-click", "first-click-chevron"].map { "WINGS-U2 " + $0 }

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

    /// Buttons in the pill's top row, split by the pill's horizontal centre (the core).
    func wingButtons() -> (left: [String], right: [String]) {
        let pill = qaPill.frame
        let row = qaPill.buttons.allElementsBoundByIndex.filter {
            $0.exists && $0.frame.height > 0 && $0.frame.midY < pill.minY + 40
        }
        return (row.filter { $0.frame.midX < pill.midX }.map(\.label),
                row.filter { $0.frame.midX > pill.midX }.map(\.label))
    }

    func assertWing(_ fixture: String, left: [String], right: [String]) {
        XCTAssertTrue(qaPill.waitForExistence(timeout: 3), "QA pill")
        waitUntil { Set(self.wingButtons().left).isSuperset(of: left) && Set(self.wingButtons().right).isSuperset(of: right) }
        let wings = wingButtons()
        for label in left { XCTAssertTrue(wings.left.contains(label), "\(fixture): \(label) on the left; got \(wings.left)") }
        for label in right { XCTAssertTrue(wings.right.contains(label), "\(fixture): \(label) on the right; got \(wings.right)") }
        XCTAssertLessThanOrEqual(wings.right.count, 2, "\(fixture): never a third right-wing control: \(wings.right)")
        assertFixedWings(fixture)
    }

    func testWingsU2Flow() throws {
        guard scenario == "wings-u2" else { throw NSError(domain: "UIE2E wings-u2 test selected outside its scenario", code: 1) }
        limitations = ["Silent fixtures drive VoiceState; the mic button is located but never pressed (the harness forbids audio actions).",
                       "The QA pill sits top-right (isolated capture placement), not in the notch; the wing widths come from the production presentation (wings.json)."]

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
            let settings = app.windows["VoiceBar QA Settings"]
            XCTAssertTrue(settings.staticTexts["Permissions"].waitForExistence(timeout: 3))
            XCTAssertTrue(settings.staticTexts["Permissions"].isHittable, "scrolled to the broken rows")
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
            try mutate { history.click() }
            waitUntil { self.qaPill.buttons["Close history"].exists }
            XCTAssertTrue(qaPill.buttons["Close history"].exists, "the first click acted")
            XCTAssertEqual(finder.state, .runningForeground, "the first click left Finder frontmost")
            XCTAssertFalse(fixtureEvents().dropFirst(beforeFirst).contains("pill-became-key"),
                           "the first click did not make the pill key")
        }
        // The chevron's first click, again from Finder: the list opens without activating VoiceBar or keying the pill.
        click(qaPill.buttons["Close history"], "close History")
        step("re-activate Finder before the chevron's first click") {
            try mutate { finder.activate() }
            XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        }
        let beforeChevron = fixtureEvents().count
        step("WINGS-U2 first-click-chevron") {
            let chevron = qaPill.buttons["Choose microphone"]
            XCTAssertTrue(chevron.waitForExistence(timeout: 3))
            try mutate { chevron.click() }
            waitUntil { self.fixtureEvents().dropFirst(beforeChevron).contains("microphone-list-open") }
            XCTAssertTrue(app.menuItems["Microphone priority…"].waitForExistence(timeout: 3), "the first click acted")
            XCTAssertEqual(finder.state, .runningForeground, "opening the list left Finder frontmost")
            XCTAssertFalse(fixtureEvents().dropFirst(beforeChevron).contains("pill-became-key"),
                           "the first click did not make the pill key")
        }
        click(app.menuItems["Microphone priority…"], "close the list through its footer")
        click(app.buttons["qa-fixture-idle"])
    }
}
