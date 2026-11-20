import VoiceBarUI
import XCTest

/// T27 pure rules. All text is synthetic.
final class SelectionStructureRepairTests: XCTestCase {
    private typealias Repair = SelectionStructureRepair

    private static let lead = "A short note about the weekend plans for the family garden. "

    func testLooksFlattenedNeedsNoLineBreakEnoughLengthAndASignal() {
        let bullets = Self.lead + "• Water the beds. • Sweep the path."
        XCTAssertTrue(Repair.looksFlattened(bullets))
        XCTAssertFalse(Repair.looksFlattened("Intro. • One. • Two."), "under the length floor")
        XCTAssertFalse(Repair.looksFlattened(bullets.replacingOccurrences(of: " • Sweep", with: "\n• Sweep")))
        XCTAssertFalse(Repair.looksFlattened(Self.lead + Self.lead), "plain prose")
        XCTAssertTrue(Repair.looksFlattened(Self.lead + "\u{FFFC} and more words after the object."))
        XCTAssertFalse(Repair.looksFlattened(Self.lead + "Then • one stray bullet."), "a single marker is no list")
    }

    func testSplitTurnsOnlyTheSpaceBeforeEachMarkerIntoALineBreak() {
        let fixtures = [
            Self.lead + "• Water the beds. • Sweep the path. • Close the gate.",
            Self.lead + "- Water the beds. - Sweep the path.",
            Self.lead + "Steps: 1. Water the beds. 2. Sweep the path. 3. Close the gate.",
            "• Opening item about the beds. • Second item about the path.",
            Self.lead + "“Quoted end.” – Next item here. – And one more.",
            Self.lead + "Steps: 1) Water the beds. 2) Sweep \u{FFFC} the path.",
        ]
        for text in fixtures {
            let split = Repair.split(text)
            XCTAssertNotEqual(split, text, text)
            XCTAssertEqual(split.replacingOccurrences(of: "\n", with: " "), text, "never delete or change a word")
            XCTAssertFalse(split.hasPrefix("\n"))
        }
        XCTAssertEqual(Repair.split(Self.lead + "• Water the beds. • Sweep the path."),
                       String(Self.lead.dropLast()) + "\n• Water the beds.\n• Sweep the path.")
    }

    func testSplitNeverMintsItemsFromProse() {
        let prose = [
            Self.lead + "The well-known route runs north-east - mostly - past the mill.",
            Self.lead + "The score was 5 - 3 and then 7 - 4 by the end.",
            Self.lead + "Read chapter 3. 4. is optional.",
            "The reading guide explains the optional chapters in the old edition. Read chapter 3. 4. is optional; see chapter 4. 5. follows it.",
            Self.lead + "Read section 3. 4. is optional; page 4. 5. follows it.",
            Self.lead + "Check step 3. 4. is optional; version 4. 5. follows it.",
            Self.lead + "First. 1. Second. 3. Third. 7. Done.",
            Self.lead + "Done. 2024. was a long year. 2025. will be shorter.",
            Self.lead + "Only one. - dash item here.",
            Self.lead + "The plan—water, sweep—is simple. Use C++ and x*y in the notes.",
        ]
        for text in prose {
            XCTAssertEqual(Repair.split(text), text, text)
            XCTAssertFalse(Repair.looksFlattened(text), text)
        }
    }

    func testSplitLeavesTextWithLineBreaksAlone() {
        let text = Self.lead + "• Water the beds.\n• Sweep the path. • Close the gate."
        XCTAssertEqual(Repair.split(text), text)
    }

    func testCopyKeepsStructureNeedsLineBreaksAndTheSameContent() {
        let ax = Self.lead + "• Water the beds. \u{FFFC} • Sweep the path."
        XCTAssertTrue(Repair.copyKeepsStructure(ax: ax, copy: Self.lead + "\n- Water the beds.\n- Sweep the path."))
        XCTAssertTrue(Repair.copyKeepsStructure(ax: ax, copy: Self.lead + "\n1. Water the beds.\r\n2. Sweep the path."))
        XCTAssertFalse(Repair.copyKeepsStructure(ax: ax, copy: ax), "no line break")
        XCTAssertFalse(Repair.copyKeepsStructure(ax: ax, copy: Self.lead + "\n- Water the beds."), "letters missing")
        XCTAssertFalse(Repair.copyKeepsStructure(ax: ax, copy: "Something else.\n- Entirely."))
    }

    func testCopyRejectsChangedQuantitiesAndMeaningfulPunctuation() {
        let ax = "Here is the plan for the garden weekend. • Buy 10 pots before noon. • Reserve 20 bags of soil for tomorrow."
        let unchanged = "Here is the plan for the garden weekend.\n- Buy 10 pots before noon.\n- Reserve 20 bags of soil for tomorrow."
        XCTAssertTrue(Repair.copyKeepsStructure(ax: ax, copy: unchanged))
        XCTAssertFalse(Repair.copyKeepsStructure(ax: ax,
            copy: unchanged.replacingOccurrences(of: "10 pots", with: "100 pots")
                .replacingOccurrences(of: "20 bags", with: "200 bags")))
        XCTAssertFalse(Repair.copyKeepsStructure(ax: ax,
            copy: unchanged.replacingOccurrences(of: "noon.", with: "noon?")))
        XCTAssertFalse(Repair.copyKeepsStructure(ax: ax,
            copy: unchanged.replacingOccurrences(of: "10 pots", with: "-10 pots")))
    }

    func testDiagnosticsCarryTheDecisionOnlyWhenEvaluated() {
        XCTAssertNil(SelectionCaptureResult.completed("x").diagnosticDetails["structure_repair"])
        XCTAssertEqual(SelectionCaptureResult.completed("x").withStructureRepair(.split)
            .diagnosticDetails["structure_repair"], "split")
    }
}
