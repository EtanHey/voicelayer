import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C7 L3 V10 (Etan's candidate-6 recording, 59/62/64 s): during play/pause the player showed a blank blur rectangle
/// with SQUARE lower corners. The collapse from the teleprompter to the reading wing resized the canvas (and the
/// window sized from it) at once, unanimated, while the shell was still springing down: everything below the new
/// canvas edge was cut flat. A read's compact state now keeps the teleprompter's canvas.
@MainActor
final class ReadingCanvasL3Tests: XCTestCase {
    /// Etan had the teleprompter at eight lines in the recording; the cut only shows on a body taller than the
    /// compact canvas.
    private func presentation(mode: VoiceMode, dismissed: Bool, paused: Bool = false,
                              confirmation: String? = nil, lines: Int = 8) -> VoiceBarNotchPresentation {
        var input = VoiceBarNotchOperationalInput(
            mode: mode, hasTeleprompterText: mode == .speaking, isTeleprompterDismissed: dismissed,
            isPlaybackPaused: paused, readQueueLeadingSlotCount: mode == .speaking ? 4 : 1,
            confirmationText: confirmation, isHovered: confirmation != nil, isCollapsed: false)
        input.teleprompterLines = lines
        return VoiceBarPresentation.notchPresentation(from: input)
    }

    private func canvas(_ presentation: VoiceBarNotchPresentation) -> VoiceBarNotchGeometry {
        VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry
    }

    func testAReadsCompactStateKeepsTheTeleprompterCanvas() {
        let open = presentation(mode: .speaking, dismissed: false)
        let hidden = presentation(mode: .speaking, dismissed: true)
        let pausedHidden = presentation(mode: .speaking, dismissed: true, paused: true)
        XCTAssertEqual(open.visualState, .teleprompter)
        XCTAssertEqual(hidden.visualState, .compactStatus)
        XCTAssertEqual(canvas(hidden).totalHeight, canvas(open).totalHeight, "Hide keeps the read's canvas")
        XCTAssertEqual(canvas(pausedHidden).totalHeight, canvas(open).totalHeight)
        XCTAssertEqual(VoiceBarPanelLayout.make(presentation: hidden, canvasGeometry: canvas(hidden)).panelSize,
                       VoiceBarPanelLayout.make(presentation: open, canvasGeometry: canvas(open)).panelSize,
                       "the window never resizes between a read's states")
    }

    /// Frame probe: every interpolated shell frame of the collapse fits the destination canvas, so none is clipped.
    func testEveryCollapseFrameFitsTheCanvasItIsDrawnIn() {
        let open = presentation(mode: .speaking, dismissed: false).geometry
        let destination = presentation(mode: .speaking, dismissed: true)
        let room = canvas(destination).totalHeight
        for step in 0 ... 20 {
            let t = CGFloat(step) / 20
            let height = open.topHeight + open.lowerSurfaceHeight * (1 - t)
                + destination.geometry.lowerSurfaceHeight * t
            XCTAssertLessThanOrEqual(height, room + 0.5,
                                     "frame \(step): shell \(height) pt tall in a \(room) pt canvas is cut flat")
        }
    }

    func testOtherCompactStatesKeepTheirOwnCanvas() {
        let note = presentation(mode: .idle, dismissed: false, confirmation: "Typed")
        XCTAssertFalse(note.holdsReadingCanvas)
        XCTAssertLessThan(canvas(note).totalHeight, canvas(presentation(mode: .speaking, dismissed: false)).totalHeight,
                          "only a read reserves the teleprompter's height")
    }
}
