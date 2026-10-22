import AppKit
import XCTest

extension VoiceBarFlowTests {
    static let focused338Text = [
        "paste-not-inserted": "Not pasted\nIn History",
        "paste-unverified": "Unverified\nIn History",
        "paste-partial": "Part pasted\nHistory: full",
        "terminal-confirmation": "QA terminal transcript שלום 👋",
        "busy-recording": "Busy recording. Selection not read",
        "busy-transcribing": "Busy transcribing. Selection not read",
        "busy-f5-preview": "Busy with F5. Selection not read",
        "selection-clipboard-changed": "Clipboard\nReselect",
        "selection-copy-timeout": "Timed out\nReselect",
        "selection-copy-empty": "No text\nReselect",
        "selection-copy-failed": "Can't copy\nCheck A11y",
    ]
    static let focused338Families = ["paste-feedback", "terminal", "busy", "selection-error"]

    func gallerySnapshot() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("gallery.json"))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(snapshot["scenario"] as? String, "focused-338")
        return snapshot
    }

    func galleryStates(_ snapshot: [String: Any]) throws -> [[String: Any]] {
        let states = try XCTUnwrap(snapshot["states"] as? [[String: Any]])
        let ids = states.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids.count, Self.focused338Text.count)
        XCTAssertEqual(Set(ids), Set(Self.focused338Text.keys), "Gallery may not omit a required variant")
        for state in states {
            let id = try XCTUnwrap(state["id"] as? String)
            XCTAssertEqual(state["expectedText"] as? String, Self.focused338Text[id])
        }
        return states
    }

    // BEGIN UIE2E GALLERY CLICK
    func galleryClick(_ identifier: String) throws {
        try mutate { app.activate() }
        let window = app.windows["VoiceBar QA Settings"]
        guard window.waitForExistence(timeout: 3), window.isHittable, !window.frame.isEmpty else {
            throw NSError(domain: "QA gallery controls are not foreground/on-screen", code: 1)
        }
        let element = window.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard element.waitForExistence(timeout: 3), element.isEnabled, element.isHittable else {
            throw NSError(domain: "Missing/unreachable focused control: " + identifier, code: 1)
        }
        try mutate { element.click() }
    }

    // END UIE2E GALLERY CLICK

    // BEGIN UIE2E GALLERY OBSERVE
    func galleryObserve() throws -> [String: Any] {
        let before = try gallerySnapshot()["observationGeneration"] as? Int ?? -1
        try galleryClick("qa-gallery-observe")
        let fresh = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let snapshot = try? self.gallerySnapshot(),
                  let generation = snapshot["observationGeneration"] as? Int else { return false }
            return generation > before && snapshot["reason"] as? String == "read-current"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fresh], timeout: 3), .completed, "Fresh observation required")
        return try gallerySnapshot()
    }

    // END UIE2E GALLERY OBSERVE

    func galleryPanel(_ title: String) -> XCUIElement {
        let dialog = app.dialogs[title]
        return dialog.exists ? dialog : app.windows[title]
    }

    func galleryText(_ text: String, in panel: XCUIElement) -> XCUIElement? {
        var candidates = panel.descendants(matching: .any).matching(UIE2EAXText.predicate(text,
            staticTextRole: XCUIElement.ElementType.staticText.rawValue,
            additionalTextRoles: [XCUIElement.ElementType.textView.rawValue])).allElementsBoundByIndex
        if [.staticText, .textView].contains(panel.elementType),
           panel.label.contains(text) || (panel.value as? String)?.contains(text) == true {
            candidates.append(panel)
        }
        return candidates
            .filter { [.staticText, .textView].contains($0.elementType) && $0.exists && !$0.frame.isEmpty }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    func focusedStep(_ name: String, _ body: () throws -> Void) {
        step(name, body)
    }

    func verifyGalleryFrames(ids: [String], snapshot: [String: Any], family: Bool = false) throws {
        let bounds = NSRectFromString(try XCTUnwrap(snapshot["screenAXBounds"] as? String))
        var panels: [String: CGRect] = [:], texts: [String: CGRect] = [:], expected: [String: String] = [:]
        for id in ids {
            let panel = galleryPanel(family ? "VoiceBar QA Pill" : "VoiceBar QA Gallery " + id)
            XCTAssertTrue(panel.exists, "Missing real production-view panel: " + id)
            guard panel.exists else { continue }
            panels[id] = panel.frame
            if !family { XCTAssertGreaterThanOrEqual(panel.frame.minY, bounds.minY + 150,
                "Gallery must remain below the reserved OS notification band") }
            let full = try XCTUnwrap(Self.focused338Text[id])
            expected[id] = full
            let bar = panel.descendants(matching: .any).matching(identifier: "qa-gallery-bar-" + id).firstMatch
            XCTAssertTrue(bar.exists, "Missing production BarView scope: " + id)
            if bar.exists, let note = galleryText(full, in: bar) { texts[id] = note.frame }
            else { XCTFail("Full rendered BarView text missing in " + id + ": " + panel.debugDescription) }
        }
        var feedbackExpected = expected
        if let terminal = feedbackExpected["terminal-confirmation"] { feedbackExpected["terminal-confirmation"] = String(terminal.prefix(2)) }
        let problems = feedbackExpected.isEmpty ? [] : UIE2EGalleryFrames.problems(
            panels: panels, texts: texts, expected: feedbackExpected, bounds: bounds)
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "; "))
        if ids.contains("terminal-confirmation"), let previewFrame = texts["terminal-confirmation"],
           let panelFrame = panels["terminal-confirmation"] {
            XCTAssertTrue(!previewFrame.isEmpty && panelFrame.contains(previewFrame), "Terminal preview must remain visible")
            if !family {
                let panel = galleryPanel("VoiceBar QA Gallery terminal-confirmation")
                let full = Self.focused338Text["terminal-confirmation"]!
                let card = panel.descendants(matching: .any).matching(identifier: "qa-gallery-card-terminal-confirmation")
                    .matching(UIE2EAXText.predicate(full, staticTextRole: XCUIElement.ElementType.staticText.rawValue,
                        additionalTextRoles: [XCUIElement.ElementType.textView.rawValue])).firstMatch
                let payload = card.exists ? galleryText(full, in: card) : nil
                attachJSON("UIE2E-TERMINAL-FULLTEXT", ["cardExists": card.exists,
                    "cardAX": card.exists ? card.debugDescription : "missing",
                    "payloadRole": payload?.elementType.rawValue ?? 0,
                    "payloadLabel": payload?.label ?? "", "payloadValue": payload?.value as? String ?? "",
                    "payloadFrame": payload.map { NSStringFromRect($0.frame) } ?? "missing",
                    "previewFrame": NSStringFromRect(previewFrame), "panelFrame": NSStringFromRect(panelFrame)])
                if let payload {
                    XCTAssertTrue(payload.label == full || payload.value as? String == full, "Exact full terminal payload in card")
                    terminalFullTextProven = UIE2ETerminalPreview.isProven(fullText: full,
                        previewFrame: previewFrame, fullFrame: payload.frame, panel: panelFrame)
                }
            }
            XCTAssertTrue(terminalFullTextProven, "Terminal preview needs full text visibly available in the actual DictationCard")
            if terminalFullTextProven { ledger.verifiedSurfaces.insert("338:static:terminal-confirmation") }
        }
        attachJSON("UIE2E-FOCUSED-FRAMES", ["ids": ids, "family": family,
            "panels": panels.mapValues(NSStringFromRect), "textFrames": texts.mapValues(NSStringFromRect),
            "expectedText": expected, "problems": problems, "oracle": "full text, actual AX frame, screen containment, sibling overlap; system12medium"])
        for id in UIE2EGalleryFrames.verifiedIDs(panels: panels, texts: texts, expected: feedbackExpected, bounds: bounds) {
            if id != "terminal-confirmation" { ledger.verifiedSurfaces.insert("338:static:" + id) }
        }
        if family, let actual = panels.values.first {
            let planned = try XCTUnwrap(UIE2EGalleryFrames.expectedFamilyAX(snapshot,
                primaryTop: try XCTUnwrap(NSScreen.screens.first).frame.maxY))
            for (a, b) in zip([actual.minX, actual.minY, actual.width, actual.height],
                              [planned.minX, planned.minY, planned.width, planned.height]) {
                XCTAssertEqual(a, b, accuracy: 1, "Actual notch panel must match production placement")
            }
        }
    }

    func runFocused338StateGallery() throws {
        guard scenario == "focused-338" else { throw NSError(domain: "Focused test selected outside focused scenario", code: 1) }
        ledger.requiredScope = Set(Self.focused338Text.keys.map { "338:static:" + $0 })
            .union(Self.focused338Families.map { "338:notch:" + $0 })
            .union(["338:expiry", "338:session-end", "338:copy"])
        focusedStep("#338 gallery reserves top150pt for OS banners; no foreign controls clicked") {
            let snapshot = try gallerySnapshot()
            XCTAssertTrue(snapshot["pinned"] as? Bool == true)
            attachJSON("UIE2E-GALLERY-EXCLUSION", ["topPoints": 150, "familyUsesProductionPlacement": true])
        }
        let initial = try gallerySnapshot()
        _ = try galleryStates(initial)
        let pages = try XCTUnwrap(initial["pages"] as? [[String: Any]])
        XCTAssertFalse(pages.isEmpty)
        let pageIDs = pages.flatMap { $0["states"] as? [String] ?? [] }
        XCTAssertEqual(pageIDs.count, Self.focused338Text.count)
        XCTAssertEqual(Set(pageIDs), Set(Self.focused338Text.keys))
        // Each page's navigation, fresh observation and all variant assertions share ONE screenshot.
        for page in pages {
            let index = try XCTUnwrap(page["index"] as? Int)
            let ids = try XCTUnwrap(page["states"] as? [String])
            focusedStep("#338 gallery page \(index): feedback fits, terminal preview has full card, panels separate") {
                try mutate { app.activate() }
                try galleryClick("qa-gallery-page-\(index)")
                let snapshot = try galleryObserve()
                XCTAssertEqual(snapshot["page"] as? Int, index)
                XCTAssertEqual(snapshot["pinned"] as? Bool, true)
                try verifyGalleryFrames(ids: ids, snapshot: snapshot)
            }
        }
        for family in Self.focused338Families {
            let before = testRun?.failureCount ?? 0
            focusedStep("#338 production notch placement: " + family) {
                try galleryClick("qa-gallery-family-" + family)
                let snapshot = try galleryObserve()
                let id = try XCTUnwrap(snapshot["familyState"] as? String)
                let state = try XCTUnwrap(try galleryStates(snapshot).first { $0["id"] as? String == id })
                XCTAssertEqual(state["family"] as? String, family)
                try verifyGalleryFrames(ids: [id], snapshot: snapshot, family: true)
            }
            if (testRun?.failureCount ?? 0) == before { ledger.verifiedSurfaces.insert("338:notch:" + family) }
        }
        let beforeCopy = testRun?.failureCount ?? 0
        focusedStep("#338 representative production Copy: exact clipboard payload") {
            try galleryClick("qa-gallery-page-0")
            let snapshot = try galleryObserve()
            let stateID = try XCTUnwrap(snapshot["copyStateID"] as? String)
            let expected = try XCTUnwrap(snapshot["copyExpectedText"] as? String)
            XCTAssertEqual(expected, Self.focused338Text["terminal-confirmation"])
            let label = try XCTUnwrap(snapshot["copyControlLabel"] as? String)
            let button = galleryPanel("VoiceBar QA Gallery " + stateID).buttons[label].firstMatch
            XCTAssertTrue(button.exists && button.isHittable)
            try mutate { NSPasteboard.general.clearContents() }
            try mutate { NSPasteboard.general.setString("UIE2E focused sentinel", forType: .string) }
            if button.exists && button.isHittable { try mutate { button.click() } }
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
        }
        if (testRun?.failureCount ?? 0) == beforeCopy { ledger.verifiedSurfaces.insert("338:copy") }
        var clockSnapshot: [String: Any] = [:]
        focusedStep("#338 start all production expiry clocks together") {
            try galleryClick("qa-gallery-start-clocks")
            clockSnapshot = try galleryObserve()
            XCTAssertEqual(clockSnapshot["pinned"] as? Bool, false)
            let generation = try XCTUnwrap(clockSnapshot["clockGeneration"] as? Int)
            XCTAssertGreaterThan(generation, 0)
            let origin = try XCTUnwrap(clockSnapshot["clockOrigin"] as? Double)
            for state in try galleryStates(clockSnapshot) {
                XCTAssertEqual(state["clockGeneration"] as? Int, generation)
                XCTAssertEqual(state["clockOrigin"] as? Double, origin)
            }
        }
        let beforeExpiry = testRun?.failureCount ?? 0
        focusedStep("#338 longest expiry wait ONCE; all variants clear without writes") {
            let states = try galleryStates(clockSnapshot)
            let longest = try XCTUnwrap(states.compactMap { $0["expirySeconds"] as? Double }.max())
            XCTAssertLessThanOrEqual(longest, 30, "Focused gate is bounded")
            guard longest <= 30 else { return }
            let origin = try XCTUnwrap(clockSnapshot["clockOrigin"] as? Double)
            let deadline = origin + longest + 0.35
            let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date().timeIntervalSince1970 >= deadline }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: longest + 2), .completed)
            let snapshot = try galleryObserve()
            for state in try galleryStates(snapshot) {
                let id = try XCTUnwrap(state["id"] as? String)
                XCTAssertTrue(state["note"] is NSNull, id + ": busy note did not expire")
                XCTAssertTrue(state["confirmation"] is NSNull, id + ": feedback did not expire")
                if id.hasPrefix("busy-") {
                    let effects = try XCTUnwrap(state["effects"] as? [String: Any])
                    for key in ["selectionCaptures", "commandCount", "typedCount", "clipboardWrites", "pasteShortcuts"] {
                        XCTAssertEqual(effects[key] as? Int, 0, id + ": " + key) }
                    XCTAssertEqual(state["mode"] as? String,
                        id == "busy-recording" ? "recording" : id == "busy-transcribing" ? "transcribing" : "idle",
                        "Busy expiry must preserve the original active synthetic session")
                }
            }
            attachJSON("UIE2E-FOCUSED-EXPIRY", snapshot)
        }
        // Observe the real renderers after the common wait; persisted DictationCard text is excluded.
        for page in pages {
            let index = try XCTUnwrap(page["index"] as? Int)
            let ids = try XCTUnwrap(page["states"] as? [String])
            focusedStep("#338 expiry gallery page \(index): feedback absent from actual BarViews") {
                try galleryClick("qa-gallery-page-\(index)")
                let snapshot = try galleryObserve()
                XCTAssertEqual(snapshot["pinned"] as? Bool, false)
                for id in ids {
                    let panel = galleryPanel("VoiceBar QA Gallery " + id)
                    let bar = panel.descendants(matching: .any).matching(identifier: "qa-gallery-bar-" + id).firstMatch
                    XCTAssertTrue(panel.exists, "Expired instance panel must remain inspectable: " + id)
                    XCTAssertTrue(UIE2EGalleryFrames.expired(renderer: bar.exists ? bar.frame : nil,
                        feedbackPresent: bar.exists && galleryText(Self.focused338Text[id]!, in: bar) != nil), id + ": missing renderer or stale visible feedback")
                }
            }
        }
        if (testRun?.failureCount ?? 0) == beforeExpiry { ledger.verifiedSurfaces.insert("338:expiry") }
        let beforeEnd = testRun?.failureCount ?? 0
        focusedStep("#338 busy session-end clearing across all busy modes") {
            try galleryClick("qa-gallery-end-sessions")
            let ended = try galleryObserve()
            let beforeNotes = try XCTUnwrap(ended["sessionEndBefore"] as? [String: String])
            for id in ["busy-recording", "busy-transcribing", "busy-f5-preview"] {
                XCTAssertEqual(beforeNotes[id], Self.focused338Text[id], "Actual note required immediately before session end")
            }
            for state in try galleryStates(ended) where (state["id"] as? String)?.hasPrefix("busy-") == true {
                XCTAssertEqual(state["mode"] as? String, "idle")
                XCTAssertTrue(state["note"] is NSNull)
            }
            attachJSON("UIE2E-FOCUSED-SESSION-END", ended)
        }
        if (testRun?.failureCount ?? 0) == beforeEnd { ledger.verifiedSurfaces.insert("338:session-end") }
        step("#338 focused scope complete; P1e/P1f readability are NORMAL assertions") {
            XCTAssertTrue(ledger.missingSurfaces.isEmpty, "Unproven #338 surfaces: \(ledger.missingSurfaces.sorted())")
            XCTAssertTrue(steps.allSatisfy { $0["skipped"] == nil && $0["expectedFailure"] == nil }, "Post-P1f focused gate permits no skips or expected-failure waivers")
        }
        completed = true
    }
}
