import CoreGraphics
@testable import VoiceBarUI
import XCTest

/// Etan's approved spec §4 + his words (findings.md:30): the History panel "should utilize the same type of
/// popover as the teleprompter of the voice ask and voice speak just maybe be narrower and taller".
/// So History is a notch visual state that drops the same shell the teleprompter uses, not an NSPopover.
final class NotchHistoryPanelTests: XCTestCase {
    private func resolve(history: Bool, teleprompter: Bool = false, recording: Bool = false,
                         compact: Bool = false, hovered: Bool = true) -> VoiceBarNotchPresentation {
        VoiceBarNotchPresentation.resolve(
            hasTeleprompter: teleprompter, isRecording: recording, hasCompactStatus: compact,
            hasHistoryPanel: history, isHovered: hovered, isKeyboardFocused: false
        )
    }

    func testHistoryIsNarrowerAndTallerThanTheTeleprompterAndKeepsTheLauncherWings() {
        let history = VoiceBarNotchContract.geometry(for: .history)
        let teleprompter = VoiceBarNotchContract.geometry(for: .teleprompter)
        let launcher = VoiceBarNotchContract.geometry(for: .hoverLauncher)

        XCTAssertLessThan(history.bodyWidth, teleprompter.bodyWidth, "narrower")
        XCTAssertGreaterThan(history.lowerSurfaceHeight, teleprompter.lowerSurfaceHeight, "taller")
        XCTAssertGreaterThanOrEqual(history.bodyWidth, history.topWidth, "the body is at least as wide as the wings")
        XCTAssertEqual(history.leadingWingWidth, launcher.leadingWingWidth)
        XCTAssertEqual(history.trailingWingWidth, launcher.trailingWingWidth)
        XCTAssertEqual(history.topHeight, teleprompter.topHeight)
    }

    func testHistoryYieldsToTheTeleprompterAndRecordingButBeatsStatusAndHover() {
        XCTAssertEqual(resolve(history: true).visualState, .history)
        XCTAssertEqual(resolve(history: true, compact: true).visualState, .history)
        XCTAssertEqual(resolve(history: true, recording: true).visualState, .recording)
        XCTAssertEqual(resolve(history: true, teleprompter: true).visualState, .teleprompter)
        XCTAssertEqual(resolve(history: false).visualState, .hoverLauncher)
        XCTAssertEqual(resolve(history: true).accessibilityLabel, "VoiceBar history")
    }

    func testOperationalInputOpensHistoryOnlyWhileIdle() {
        var input = VoiceBarNotchOperationalInput(mode: .idle, isHovered: true)
        input.isHistoryPanelOpen = true
        XCTAssertEqual(VoiceBarPresentation.notchPresentation(from: input).visualState, .history)
        input.mode = .recording
        XCTAssertEqual(VoiceBarPresentation.notchPresentation(from: input).visualState, .recording)
    }

    func testPresentationModelOpensAndClosesTheHistoryPanel() {
        let model = VoiceBarNotchPresentationModel()
        model.setHovered(true)
        model.setHistoryPanelOpen(true)
        XCTAssertEqual(model.presentation.visualState, .history)
        model.setHistoryPanelOpen(false)
        XCTAssertEqual(model.presentation.visualState, .hoverLauncher)
    }

    func testTheWholePanelBodyTakesClicksAndTheLauncherButtonsStayLive() {
        let presentation = resolve(history: true)
        let geometry = presentation.geometry
        let region = VoiceBarNotchHitRegion(
            geometry: geometry,
            configuration: .fallback(for: presentation)
        )
        XCTAssertTrue(region.contains(CGPoint(x: geometry.totalWidth / 2, y: geometry.lowerSurfaceHeight / 2)),
                      "rows scroll and hover, so the body is interactive")
        XCTAssertTrue(region.contains(CGPoint(x: geometry.bodyOriginX + 2, y: 2)), "down to the footer")
        let historyButton = CGPoint(
            x: geometry.coreOriginX + geometry.coreWidth + VoiceBarNotchContract.compactCoreContentInset + 2,
            y: geometry.lowerSurfaceHeight + geometry.topHeight / 2
        )
        XCTAssertTrue(region.contains(historyButton), "the History button closes the panel again")
    }

    func testSameShellMaterialAndCanvasAsTheTeleprompter() {
        XCTAssertEqual(VoiceBarNotchMaterialDescriptor.resolve(for: .history),
                       VoiceBarNotchMaterialDescriptor.resolve(for: .teleprompter))
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: resolve(history: true))
        let teleprompterCanvas = VoiceBarNotchMorphCanvasLayout.resolve(for: resolve(
            history: false,
            teleprompter: true
        ))
        XCTAssertEqual(canvas.canvasGeometry.totalWidth, teleprompterCanvas.canvasGeometry.totalWidth,
                       "one fixed canvas width, so the shell morphs instead of the window jumping")
        XCTAssertEqual(canvas.canvasGeometry.totalHeight, resolve(history: true).geometry.totalHeight)
    }

    func testRowsShowFirstWordsOnOneFlattenedLine() {
        XCTAssertEqual(NotchHistoryPresentation.firstWords("Line one\nline  two"), "Line one line two")
        let long = String(repeating: "word ", count: 60)
        let words = NotchHistoryPresentation.firstWords(long)
        XCTAssertLessThanOrEqual(words.count, NotchHistoryPresentation.firstWordsLimit)
        XCTAssertTrue(words.hasSuffix("…"))
    }

    func testRowActionsAreLabelledIconButtons() {
        XCTAssertEqual(NotchHistoryPresentation.rowActions.map(\.symbol),
                       ["doc.on.doc", "doc.on.clipboard", "arrow.clockwise"])
        XCTAssertEqual(NotchHistoryPresentation.rowActions.map(\.label),
                       ["Copy", "Paste into the app you were using", "Re-transcribe"])
        XCTAssertGreaterThanOrEqual(NotchHistoryPresentation.rowActionSize, 24)
    }
}
