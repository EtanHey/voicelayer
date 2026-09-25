import AppKit
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

    /// #166 review MUST-FIX 1: the History body was 320 pt symmetric, so on a 185–220 pt notch the
    /// History + Settings wing overhung the body by 6–23.5 pt. The teleprompter's body encloses its wings;
    /// every state with a lower surface must.
    func testEveryLowerSurfaceEnclosesItsWingsOnEveryNotchWidth() {
        for state in VoiceBarNotchVisualState.allCases {
            for core in [CGFloat(185), 200, 220] {
                let geometry = VoiceBarNotchContract.geometry(for: state, coreWidth: core)
                guard geometry.lowerSurfaceHeight > 0 else { continue }
                XCTAssertGreaterThanOrEqual(geometry.bodyLeadingExtent, geometry.leadingWingWidth, "\(state) @\(core)")
                XCTAssertGreaterThanOrEqual(
                    geometry.bodyTrailingExtent,
                    geometry.trailingWingWidth,
                    "\(state) @\(core)"
                )
                XCTAssertEqual(geometry.bodyLeadingExtent, geometry.bodyTrailingExtent, "symmetric about the core")
            }
        }
        for core in [CGFloat(185), 200, 220] {
            let history = VoiceBarNotchContract.geometry(for: .history, coreWidth: core)
            XCTAssertGreaterThanOrEqual(
                history.bodyTrailingExtent,
                history.trailingWingWidth + VoiceBarNotchContract.historyShoulderClearance,
                "a flush wing and body edge draws an S-hook; the body clears the wing like the teleprompter's"
            )
        }
        XCTAssertLessThan(VoiceBarNotchContract.geometry(for: .history).bodyWidth,
                          VoiceBarNotchContract.geometry(for: .teleprompter).bodyWidth, "still narrower")
    }

    private func key(_ code: UInt16, _ characters: String, in window: NSWindow?) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    /// #166 review MUST-FIX 2: the popover closed on any outside click; the panel must too, and on Esc.
    @MainActor
    func testTheOpenPanelClosesOnAnOutsideClickAndOnEscapeAimedAtIt() throws {
        var closes = 0
        let dismissal = NotchHistoryDismissal { closes += 1 }
        let panel = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        dismissal.panelWindow = panel

        dismissal.handleOutsideMouseDown()
        XCTAssertEqual(closes, 1, "a click in another app closes it")

        try dismissal.handleGlobalKeyDown(key(53, "\u{1B}", in: nil))
        XCTAssertEqual(closes, 2, "Esc going to another app closes it")

        XCTAssertTrue(try dismissal.handleLocalKeyDown(key(53, "\u{1B}", in: panel)), "Esc in the panel is consumed")
        XCTAssertEqual(closes, 3)

        XCTAssertFalse(try dismissal.handleLocalKeyDown(key(0, "a", in: panel)), "other keys pass through")
        try dismissal.handleGlobalKeyDown(key(0, "a", in: nil))
        XCTAssertEqual(closes, 3)
    }

    /// CodeRabbit (#166, 4100680970): the local monitor swallowed Esc in EVERY VoiceBar window while the panel
    /// was open, so Esc could not close a Settings sheet. Only Esc aimed at the panel is the panel's.
    @MainActor
    func testEscapeInAnotherVoiceBarWindowIsNotConsumed() throws {
        var closes = 0
        let dismissal = NotchHistoryDismissal { closes += 1 }
        let panel = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let settings = NSWindow(contentRect: NSRect(x: -20000, y: -19000, width: 10, height: 10),
                                styleMask: [.titled], backing: .buffered, defer: false)
        panel.orderFront(nil)
        settings.orderFront(nil)
        defer {
            panel.orderOut(nil)
            settings.orderOut(nil)
        }
        dismissal.panelWindow = panel

        XCTAssertFalse(try dismissal.handleLocalKeyDown(key(53, "\u{1B}", in: settings)),
                       "Esc belongs to the Settings window")
        XCTAssertEqual(closes, 0)
    }

    @MainActor
    func testDismissalMonitorsAreInstalledOnlyWhileOpen() {
        let dismissal = NotchHistoryDismissal {}
        XCTAssertFalse(dismissal.isMonitoring)
        dismissal.start()
        XCTAssertTrue(dismissal.isMonitoring)
        dismissal.start()
        XCTAssertTrue(dismissal.isMonitoring, "starting twice keeps one set of monitors")
        dismissal.stop()
        XCTAssertFalse(dismissal.isMonitoring)
    }

    /// Macroscope (#166): "Copied ✓" was keyed by row offset, so an entry inserted at 0 moved it.
    func testRowsAreKeyedByAStableIdentity() {
        let audio = RecentTranscriptionEntry(text: "same words", recordingPath: "/tmp/a/audio.wav")
        let edited = RecentTranscriptionEntry(text: "re-transcribed words", recordingPath: "/tmp/a/audio.wav")
        let ids = NotchHistoryPresentation.rowIDs(for: [audio])
        XCTAssertEqual(ids, NotchHistoryPresentation.rowIDs(for: [edited]), "a re-transcription keeps its row")
    }

    /// Macroscope (#166, 4100526855): two audio-less entries with the same text shared one id, so copying one
    /// marked both and they shared hover.
    func testIdenticalTextEntriesWithoutAudioGetDistinctRows() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for entries in [
            [RecentTranscriptionEntry(text: "okay"), RecentTranscriptionEntry(text: "okay")],
            [RecentTranscriptionEntry(text: "okay", createdAt: now),
             RecentTranscriptionEntry(text: "okay", createdAt: now.addingTimeInterval(-60))],
            [
                RecentTranscriptionEntry(text: "okay", createdAt: now),
                RecentTranscriptionEntry(text: "okay", createdAt: now),
            ],
        ] {
            let ids = NotchHistoryPresentation.rowIDs(for: entries)
            XCTAssertEqual(Set(ids).count, 2, "\(ids)")
            var feedback = NotchHistoryCopyFeedback()
            _ = feedback.copied(row: ids[0])
            XCTAssertTrue(feedback.isCopied(row: ids[0]))
            XCTAssertFalse(feedback.isCopied(row: ids[1]), "copying one marks only that row")
        }
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
