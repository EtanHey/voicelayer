import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U5 follow-up guards: the live notch follows the Teleprompter A handle (formal/teleprompter-a-handle).
@MainActor
final class TeleprompterAHandleTests: XCTestCase {
    func testOnlyTheHandleStretchesPastThreeOrEightLines() {
        XCTAssertEqual(TeleprompterA.handleOvershoot(startLines: 5, translation: 30), 0)
        let past = TeleprompterA.handleOvershoot(startLines: 8, translation: 300)
        XCTAssertGreaterThan(past, 0)
        XCTAssertLessThan(past, TeleprompterA.lineHeight)
        let before = TeleprompterA.handleOvershoot(startLines: 3, translation: -300)
        XCTAssertLessThan(before, 0)
        XCTAssertGreaterThan(before, -TeleprompterA.lineHeight)
    }

    func testSurfaceHeightFollowsTheSettledLines() {
        XCTAssertEqual(VoiceBarNotchContract.teleprompterLowerSurfaceHeight(lines: 3), 196)
        XCTAssertEqual(VoiceBarNotchContract.teleprompterLowerSurfaceHeight(lines: 8), 316)
        XCTAssertEqual(VoiceBarNotchContract.teleprompterLowerSurfaceHeight(lines: 12), 316)
        XCTAssertEqual(VoiceBarNotchContract.geometry(for: .teleprompter).lowerSurfaceHeight, 196)
        let resolve = { (lines: Int) in
            VoiceBarNotchPresentation.resolve(hasTeleprompter: true, isRecording: false, hasCompactStatus: false,
                                              teleprompterLines: lines, isHovered: false, isKeyboardFocused: false)
        }
        XCTAssertEqual(resolve(3).geometry.lowerSurfaceHeight, 196)
        XCTAssertEqual(resolve(5).geometry.lowerSurfaceHeight, 244)
        XCTAssertEqual(resolve(8).geometry.lowerSurfaceHeight, 316)
        // Lines never leak into another surface.
        let history = VoiceBarNotchPresentation.resolve(hasTeleprompter: false, isRecording: false, hasCompactStatus: false,
                                                        hasHistoryPanel: true, teleprompterLines: 8,
                                                        isHovered: false, isKeyboardFocused: false)
        XCTAssertEqual(history.geometry.lowerSurfaceHeight,
                       VoiceBarNotchPresentation.resolve(hasTeleprompter: false, isRecording: false, hasCompactStatus: false,
                                                         hasHistoryPanel: true, isHovered: false, isKeyboardFocused: false)
                        .geometry.lowerSurfaceHeight)
    }

    /// The window always holds eight lines, so a handle drag never resizes it under the pointer.
    func testTheTeleprompterWindowNeverResizesWithTheHandle() {
        let heights = [3, 5, 8].map { lines -> CGFloat in
            let presentation = VoiceBarNotchPresentation.resolve(hasTeleprompter: true, isRecording: false,
                                                                 hasCompactStatus: false, teleprompterLines: lines,
                                                                 isHovered: false, isKeyboardFocused: false)
            return VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry.totalHeight
        }
        XCTAssertEqual(Set(heights).count, 1, "\(heights)")
    }

    func testPresentationModelTakesClampedLinesAtOnce() {
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false)
        model.setTeleprompterLines(6)
        XCTAssertEqual(model.teleprompterLines, 6)
        XCTAssertEqual(model.presentation.geometry.lowerSurfaceHeight, 268, "the hit region takes the lines synchronously")
        model.setTeleprompterLines(40)
        XCTAssertEqual(model.teleprompterLines, 8)
    }

    func testVoiceStateLinesDriveThePresentationInput() {
        let state = VoiceState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Handle", "playback_id": "h", "generation": 1])
        XCTAssertEqual(state.teleprompterVisibleLines, 3)
        state.teleprompterVisibleLines = 7
        var input = VoiceBarNotchOperationalInput(mode: .speaking, hasTeleprompterText: true, readQueueLeadingSlotCount: 1)
        input.teleprompterLines = state.teleprompterVisibleLines
        XCTAssertEqual(VoiceBarPresentation.notchPresentation(from: input).geometry.lowerSurfaceHeight, 292)
    }

    func testLowerRowHasNoStopAndTheHandleIsKeyboardOnlyFocusable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"), encoding: .utf8)
        let lower = try XCTUnwrap(bar.components(separatedBy: "private var notchTeleprompterControls").dropFirst().first)
            .components(separatedBy: "// MARK: - Error state")[0]
        XCTAssertFalse(lower.contains("stop.fill"), "the teleprompter's lower row carries no Stop")
        let view = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/TeleprompterAView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(view.contains(".focusable(interactions: .activate)"))
        XCTAssertFalse(view.contains(".focusable()"), "a click on the handle must not make the panel key")
    }
}
