import CoreGraphics
@testable import VoiceBarUI
import XCTest

/// C6 L2c, Q-F48 ("pulls reaching the app behind"). The previous L2 worker's hypothesis: for 500 ms after a
/// same-size layout change the hit gate claims only the intersection of the old and new layouts, so a press on
/// drawer the old layout lacked passes through to the app underneath.
///
/// Confirmed for the drawer resizes a pointer makes. When a grip or handle is let go, or a pull is let go past open
/// into Settings, the drawer's rows change after the pointer has ALREADY drawn the shell there. The gate still
/// settled from the previous layout, so every row the drag drew below it refused clicks for half a second: a quick
/// second pull on the grip it had just moved went to the app behind (and "works after a wait", Q-F26).
final class NotchPullHitGateTests: XCTestCase {
    private func layout(rows: Int, note: String? = nil) -> VoiceBarPanelLayout {
        var input = VoiceBarNotchOperationalInput(mode: .idle, isHovered: true)
        input.isHistoryPanelOpen = true
        input.historyRows = rows
        input.transientNote = note
        let presentation = VoiceBarPresentation.notchPresentation(from: input)
        return VoiceBarPanelLayout.make(
            presentation: presentation,
            canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry
        )
    }

    /// The grip's centre at the bottom of `layout`'s drawer, in window space (bottom-up).
    private func grip(_ layout: VoiceBarPanelLayout) -> CGPoint {
        CGPoint(x: layout.visibleContentRect.midX,
                y: layout.visibleContentRect.minY + NotchHistoryMorph.handleBandHeight / 2)
    }

    /// The reproduction, on the API the base already had: History's handle let go at eight rows. The pointer drew
    /// the shell down to the grip; the gate refuses the grip for the whole settle window.
    func testQF48ReproducedARowsChangeAfterADragRefusesTheRowsTheDragDrew() {
        for (from, to) in [(6, 8), (8, NotchSettingsDrawerPresentation.maximumRows)] {
            let old = layout(rows: from), new = layout(rows: to)
            XCTAssertEqual(old.panelSize, new.panelSize, "a drawer resize is a same-size change")
            let point = grip(new)
            XCTAssertTrue(new.containsVisibleSurface(point))
            XCTAssertFalse(old.containsVisibleSurface(point))
            var gate = VoiceBarPanelHitGate(layout: old)
            gate.update(to: new, now: 100)
            for elapsed in [0.01, 0.1, 0.3, 0.45] {
                XCTAssertFalse(gate.containsVisibleSurface(point, now: 100 + elapsed),
                               "\(from)->\(to) rows at +\(elapsed) s: the plain update refuses the drawn grip")
            }
            XCTAssertTrue(gate.containsVisibleSurface(point, now: 100 + VoiceBarPanelHitGate.settleDuration))
        }
    }

    /// The fix: the gate settles from what the pointer drew, so the drawn rows (and the grip) take clicks at once.
    func testQF48ADrawnDrawerTakesItsClicksAtOnce() {
        for (from, to) in [(6, 8), (8, 10), (8, NotchSettingsDrawerPresentation.maximumRows), (11, 9)] {
            let old = layout(rows: from), new = layout(rows: to)
            var gate = VoiceBarPanelHitGate(layout: old)
            XCTAssertTrue(gate.settles(into: new))
            gate.update(to: new, now: 0,
                        drawnLowerSurfaceHeight: NotchHistoryMorph.lowerSurfaceHeight(rows: CGFloat(to)))
            XCTAssertTrue(gate.containsVisibleSurface(grip(new), now: 0.01), "\(from)->\(to): the grip is live")
            XCTAssertFalse(gate.containsVisibleSurface(grip(old), now: 0.01) && from > to,
                           "\(from)->\(to): a shrunk drawer stops claiming its old grip at once")
        }
    }

    /// Never claim what is not drawn: a grip let go at 7.3 rows snaps to eight, so the strip between 7.3 and eight
    /// rows waits for the settle; a pull stretched past open into Settings claims the drawer it already covers.
    /// Every point the gate claims is inside the shell at every progress from the drawn height to the destination.
    func testQF48EveryClaimedPointIsDrawnFromTheReleaseToTheRest() {
        let cases: [(String, Int, Int, CGFloat)] = [
            ("handle let go at 7.3 rows", 6, 8, NotchHistoryMorph.lowerSurfaceHeight(rows: 7.3)),
            ("grip let go at 10.6 rows", 8, 11, NotchHistoryMorph.lowerSurfaceHeight(rows: 10.6)),
            ("grip stretched past 11", 8, 11, NotchHistoryMorph.lowerSurfaceHeight(rows: 11.4)),
            ("grip pushed up to 8.6", 11, 9, NotchHistoryMorph.lowerSurfaceHeight(rows: 8.6)),
            ("pull past open into Settings", 6, 8, NotchHistoryMorph.lowerSurfaceHeight(rows: 6) * 1.3),
        ]
        for (name, from, to, drawn) in cases {
            let old = layout(rows: from), new = layout(rows: to)
            var gate = VoiceBarPanelHitGate(layout: old)
            gate.update(to: new, now: 0, drawnLowerSurfaceHeight: drawn)
            let rest = new.presentation.geometry.lowerSurfaceHeight
            let frames = stride(from: 0.0, through: 1.0, by: 0.1).map {
                new.withDrawnLowerSurface(drawn + (rest - drawn) * CGFloat($0))
            }
            var claimed = 0
            for x in stride(from: CGFloat(0.5), to: new.panelSize.width, by: 3) {
                for depth in stride(from: CGFloat(0.5), to: new.panelSize.height, by: 3) {
                    let point = CGPoint(x: x, y: new.panelSize.height - depth)
                    guard gate.containsVisibleSurface(point, now: 0.01) else { continue }
                    claimed += 1
                    if let index = frames.firstIndex(where: { !$0.containsVisibleSurface(point) }) {
                        XCTFail("\(name): \(point) claimed but not drawn at progress \(Double(index) / 10)")
                        break
                    }
                }
            }
            XCTAssertGreaterThan(claimed, 0, name)
        }
        // The pull past open covered the Settings drawer down to its grip's top.
        let old = layout(rows: 6), new = layout(rows: 8)
        var gate = VoiceBarPanelHitGate(layout: old)
        gate.update(to: new, now: 0, drawnLowerSurfaceHeight: NotchHistoryMorph.lowerSurfaceHeight(rows: 6) * 1.3)
        XCTAssertTrue(gate.containsVisibleSurface(CGPoint(x: grip(new).x, y: grip(new).y + 8), now: 0.01))
    }

    /// The drawn height is taken once, and only while the settle window is still open.
    func testTheDrawnHeightIsTakenOnceAndLapses() {
        let model = VoiceBarNotchPresentationModel()
        var now: TimeInterval = 10
        model.drawnHistoryClock = { now }
        XCTAssertNil(model.takeDrawnHistoryLowerSurface())
        model.noteDrawnHistoryLowerSurface(400)
        XCTAssertEqual(model.takeDrawnHistoryLowerSurface(), 400)
        XCTAssertNil(model.takeDrawnHistoryLowerSurface(), "taken once")
        model.noteDrawnHistoryLowerSurface(400)
        now += VoiceBarPanelHitGate.settleDuration
        XCTAssertNil(model.takeDrawnHistoryLowerSurface(), "a stale height never applies to a later change")
        model.noteDrawnHistoryLowerSurface(.nan)
        XCTAssertNil(model.takeDrawnHistoryLowerSurface())
    }

    /// A same-size change that a pointer did NOT draw (a note arriving) keeps the conservative intersection.
    func testAnAnimatedChangeStillSettlesFromThePreviousLayout() {
        let plain = layout(rows: 8), noted = layout(rows: 8, note: "Busy. Selection not read")
        var gate = VoiceBarPanelHitGate(layout: plain)
        gate.update(to: noted, now: 0)
        XCTAssertEqual(gate.settlingFrom, [plain])
    }
}
