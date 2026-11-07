import AppKit
import SwiftUI
import OffscreenTestSupport
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchStatusFeedbackTests: XCTestCase {
    private let long = "The speech model could not finish this transcription. Open History and select the retained recording to retry when the model is available."
    private func resolve(_ input: VoiceBarNotchOperationalInput) -> VoiceBarNotchPresentation {
        VoiceBarPresentation.notchPresentation(from: input)
    }
    private func mountedText(_ view: NSView, matching text: String) -> NSView? {
        if let label = view as? NSTextField, label.stringValue == text { return label }
        if let label = view as? NSTextView, label.string == text { return label }
        // macOS 27 uses AppKitTextInteractionView; older systems expose native
        // text fields/views. Keep the measured node's actual layout bounds.
        if view.accessibilityValue() as? String == text { return view }
        return view.subviews.compactMap { mountedText($0, matching: text) }.first
    }
    /// N2 (formal/notch-presentation OldProcessingNote): nothing under the notch while transcribing, warm-up
    /// status and every note (busy selection, quit refusal, rejection) included. The spinner and blue carry it.
    func testTranscribingNeverAddsAStatusBand() {
        let notes: [String?] = [nil, "Busy transcribing. Selection not read",
                                "Finish voice work or cancel the update, then quit again.", "Already queued"]
        for text in ["Transcribing", "Warming up the speech model…", long] {
            for note in notes {
                for history in [false, true] {
                    var input = VoiceBarNotchOperationalInput(mode: .transcribing, statusText: text, transientNote: note)
                    input.isHistoryPanelOpen = history
                    let p = resolve(input)
                    XCTAssertNil(p.feedback, "\(text) / \(note ?? "-")")
                    XCTAssertNil(p.transientNoteRect, "\(text) / \(note ?? "-")")
                    XCTAssertEqual(p.feedbackHeight, 0)
                    XCTAssertEqual(p.ownBodyHeight, p.geometry.lowerSurfaceHeight)
                }
            }
        }
    }
    func testOverflowingWingCopyFitsWithoutLosingTheFullNote() throws {
        let cancelled = "Transcription cancelled. Audio saved. Re-transcribe it from History when processing finishes."
        for text in [cancelled, long] {
            for mode in [VoiceMode.idle, .error] {
                for queueDepth in [0, 12, 99999] {
                    let p = resolve(.init(mode: mode, confirmationText: text,
                                          queueDepth: queueDepth, statusText: text))
                    let f = try XCTUnwrap(p.feedback)
                    XCTAssertEqual(f.statusText, text, "Full copy remains in the compact note")
                    let accessory: CGFloat = mode == .error ? 23 :
                        (queueDepth > 0 ? Theme.intrinsicPillStatusWidth(for: "\(queueDepth)") + 16 : 0)
                    let available = p.geometry.trailingWingWidth - WaveformLayout.coreGap -
                        WaveformLayout.outerInset - VoiceBarNotchContract.compactStatusTrailingSafetyInset - accessory
                    let measured = (f.wingText as NSString).size(withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium)
                    ]).width
                    XCTAssertLessThanOrEqual(measured, max(0, available))
                    XCTAssertFalse(f.wingText.contains("…") || f.wingText.contains("..."))
                    // N1: the notice is the tab; the wing carries no repeated, shortened or substitute label.
                    XCTAssertEqual(f.wingText, "")
                    XCTAssertTrue(f.replacesWingText)
                }
            }
        }
    }
    func testFullErrorSurvivesInsideCompactNoteShellWithHistory() throws {
        let p = resolve(.init(mode: .error, statusText: long))
        let f = try XCTUnwrap(p.feedback)
        XCTAssertEqual(f.statusText, long)
        XCTAssertTrue(f.opensHistory)
        // N1: the note is the tab under the notch, not a band across the wings.
        XCTAssertEqual(f.width, p.geometry.bodyWidth)
        XCTAssertEqual(p.geometry.bodyWidth, p.geometry.coreWidth)
        XCTAssertLessThan(p.geometry.bodyWidth, p.geometry.topWidth)
    }
    func testHistoryReservesInlineWidthWithoutAddingAnActionRow() throws {
        for core: CGFloat in [120, 185, 280] {
            for text in ["Busy", long, String(repeating: long, count: 20)] {
                let p = resolve(.init(mode: .error, statusText: text, coreWidth: core))
                let f = try XCTUnwrap(p.feedback)
                let textWidth = VoiceBarNotchFeedback.messageWidth(f.width, opensHistory: true)
                XCTAssertEqual(textWidth, f.width - 32 - VoiceBarNotchFeedback.historyButtonWidth
                    - VoiceBarNotchFeedback.historyButtonSpacing)
                XCTAssertEqual(f.statusHeight, max(VoiceBarNotchContract.transientNoteBandHeight,
                    min(VoiceBarNotchFeedback.maximumTextHeight,
                        VoiceBarNotchFeedback.textHeight(text, width: textWidth)) + 10))
                XCTAssertEqual(f.statusText, text)
                XCTAssertEqual(f.width, p.geometry.bodyWidth)
                if text == "Busy" {
                    XCTAssertEqual(f.statusHeight, VoiceBarNotchContract.transientNoteBandHeight)
                }
            }
        }
    }
    // N5's inline action is guarded by NotchCompactNoteTests.testOpenHistorySharesTheMessageRow: the action is
    // now a compact glyph (named "Open History" for VoiceOver and on hover), so OCR of its label no longer applies.
    func testQuitRefusalWrapsDownwardWithoutWideningTheCompactShell() throws {
        let text = "Finish voice work or cancel the update, then quit again."
        let p = resolve(.init(mode: .idle, confirmationText: text, statusText: text, coreWidth: 120))
        let f = try XCTUnwrap(p.feedback)
        XCTAssertEqual(f.statusText, text)
        XCTAssertEqual(f.width, p.geometry.bodyWidth)
        XCTAssertLessThan(f.width, p.geometry.topWidth, "N1: a tab, not the shell-wide slab")
        XCTAssertGreaterThan(f.statusHeight, VoiceBarNotchContract.transientNoteBandHeight)
        XCTAssertFalse(f.opensHistory)
        let host = NSHostingView(rootView: VoiceBarNotchFeedbackBand(feedback: f, onOpenHistory: {}))
        host.frame = NSRect(x: 0, y: 0, width: f.width, height: f.height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        VLOrderTestWindow(window)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let label = try XCTUnwrap(mountedText(host, matching: text), "Full quit instruction must be mounted")
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        XCTAssertGreaterThanOrEqual(Int((label.bounds.height / lineHeight).rounded()), 2,
                                    "Rendered lines, independent of OCR: the refusal wraps down")
        XCTAssertTrue(host.bounds.contains(label.convert(label.bounds, to: host)))
    }
    func testAnyLongNoteStaysWithinExistingShellAcrossCoreSizesAndResidentModel() throws {
        let note = "Finish voice work or cancel the update, then quit again. " + long
        for core: CGFloat in [120, 185, 280] {
            for mode in [VoiceMode.idle, .recording, .error, .speaking] { // transcribing: N2, no note
                var input = VoiceBarNotchOperationalInput(mode: mode, statusText: "Busy", coreWidth: core)
                let plain = resolve(input)
                input.transientNote = note
                let p = resolve(input)
                let shell = plain.visualState == .idle
                    ? VoiceBarNotchContract.geometry(for: .hoverLauncher, coreWidth: core)
                    : plain.geometry
                let f = try XCTUnwrap(p.feedback)
                let rect = try XCTUnwrap(p.transientNoteRect)
                XCTAssertEqual(p.geometry.leadingWingWidth, shell.leadingWingWidth)
                XCTAssertEqual(p.geometry.trailingWingWidth, shell.trailingWingWidth)
                let tab = VoiceBarNotchContract.noteBodyExtents(for: shell, ownBodyHeight: shell.lowerSurfaceHeight)
                XCTAssertEqual(p.geometry.bodyLeadingExtent, tab.leading)
                XCTAssertEqual(p.geometry.bodyTrailingExtent, tab.trailing)
                XCTAssertLessThanOrEqual(rect.width, shell.totalWidth)
                XCTAssertGreaterThan(f.noteHeight, VoiceBarNotchContract.transientNoteBandHeight)
                XCTAssertEqual(f.noteText, note)
                XCTAssertTrue(VoiceBarNotchShapeLayout(geometry: p.geometry).bodyRect.contains(rect))
                let model = VoiceBarNotchPresentationModel()
                model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: mode == .recording,
                    hasCompactStatus: p.visualState == .compactStatus,
                    compactStatusLeadingWingWidth: p.geometry.leadingWingWidth,
                    compactStatusTrailingWingWidth: p.geometry.trailingWingWidth,
                    recordingLeadingWingWidth: p.geometry.leadingWingWidth,
                    recordingTrailingWingWidth: p.geometry.trailingWingWidth,
                    coreWidth: core, transientNoteWidth: p.transientNoteWidth, feedback: p.feedback)
                XCTAssertEqual(model.presentation, p)
            }
        }
    }
    /// N1/N4 (formal/notch-presentation Fixed): every idle confirmation and error diagnostic is a notice in the
    /// tab, with no wing label; an empty diagnostic shows nothing rather than an invented "Error".
    func testConfirmationsAreNoticesInTheTabNotTheWing() throws {
        for text in ["Typed", "Copied", "Not pasted\nIn History", "Select text\nfirst"] {
            let p = resolve(.init(mode: .idle, confirmationText: text, statusText: text))
            let f = try XCTUnwrap(p.feedback, text)
            XCTAssertEqual(f.statusText, text)
            XCTAssertEqual(p.wingLabel(for: text), "", text)
            XCTAssertFalse(f.opensHistory, text)
        }
        let busy = try XCTUnwrap(resolve(.init(mode: .error, statusText: "Busy")).feedback)
        XCTAssertEqual(busy.statusText, "Busy")
        XCTAssertTrue(busy.statusOpensHistory)
        XCTAssertEqual(busy.wingText, "")
        // N4: an empty diagnostic is hidden, not replaced.
        XCTAssertEqual(VoiceBarPresentation.errorStatusText(nil), "")
        XCTAssertEqual(VoiceBarPresentation.errorStatusText("  "), "")
        let empty = resolve(.init(mode: .error, statusText: VoiceBarPresentation.errorStatusText(nil)))
        XCTAssertNil(empty.feedback)
        XCTAssertEqual(empty.wingLabel(for: ""), "")
        // Operational hints are not notices: "Hold to talk" stays the wing's own label.
        let hint = resolve(.init(mode: .idle, hotkeyPhase: .pressing, statusText: "Hold to talk"))
        XCTAssertNil(hint.feedback)
        XCTAssertEqual(hint.wingLabel(for: "Hold to talk"), "Hold to talk")
        // ...until a notice shows, when the wing carries no label at all.
        let noted = resolve(.init(mode: .idle, hotkeyPhase: .pressing, statusText: "Hold to talk",
                                  transientNote: "Busy with F5. Selection not read"))
        XCTAssertEqual(noted.wingLabel(for: "Hold to talk"), "")
    }

    /// N5 (formal/notch-presentation OldBusyHistory): a busy-selection note carries Open History inline, like an
    /// error diagnostic; other notes (quit refusal, rejection) do not.
    func testBusySelectionNotesCarryInlineHistory() throws {
        for (mode, phase) in [(VoiceMode.recording, HotkeyPhase.idle), (.idle, .pressing), (.speaking, .pressing)] {
            let note = try XCTUnwrap(VoiceBarPresentation.selectionBusyNote(isRequested: true, mode: mode, hotkeyPhase: phase))
            let f = try XCTUnwrap(resolve(.init(mode: mode, hotkeyPhase: phase, transientNote: note)).feedback, note)
            XCTAssertTrue(f.noteOpensHistory, note)
            XCTAssertEqual(f.noteHeight, VoiceBarNotchFeedback.bandHeight(note, width: f.width, opensHistory: true))
        }
        for note in ["Finish voice work or cancel the update, then quit again.", "Already queued"] {
            XCTAssertNotEqual(resolve(.init(mode: .idle, transientNote: note)).feedback?.noteOpensHistory, true, note)
        }
    }
    func testCancellationAndMultilineRecoveryWrapBelow() {
        for text in [long, "Recovery unavailable\nPlease open History", "fu… " + long] {
            let p = resolve(.init(mode: .idle, confirmationText: text, statusText: text))
            XCTAssertEqual(p.feedback?.statusText, text)
        }
    }
    func testCoreAndTopControlsNeverMoveWhenStatusGrows() {
        for core: CGFloat in [120, 185, 280] {
            let short = resolve(.init(mode: .error, statusText: "Busy", coreWidth: core))
            let extended = resolve(.init(mode: .error, statusText: long, coreWidth: core))
            XCTAssertEqual(short.geometry.topHeight, extended.geometry.topHeight)
            XCTAssertEqual(short.geometry.leadingWingWidth, extended.geometry.leadingWingWidth)
            // The short fitting wing is retained; the existing maximum wing cap remains unchanged.
            XCTAssertLessThanOrEqual(extended.geometry.trailingWingWidth, VoiceBarNotchContract.morphCanvasWingCapacity)
            XCTAssertEqual(extended.geometry.coreWidth, core)
        }
    }
    func testProcessingNoteAndStatusCoexistWithoutOverlappingPanels() throws {
        for mode in [VoiceMode.transcribing, .error] {
            let p = resolve(.init(mode: mode, statusText: long, transientNote: "Busy transcribing. Selection not read"))
            if mode == .transcribing {
                // N2: neither the status nor the selection note shows while transcribing.
                XCTAssertNil(p.feedback)
                XCTAssertNil(p.transientNoteRect)
                continue
            }
            let f = try XCTUnwrap(p.feedback)
            XCTAssertNotNil(f.noteText)
            XCTAssertEqual(f.statusText, mode == .error ? long : nil)
            XCTAssertEqual(f.height, f.statusHeight + f.noteHeight)
            XCTAssertEqual(p.transientNoteRect?.maxY, p.geometry.topHeight + f.noteHeight)
        }
        var input = VoiceBarNotchOperationalInput(mode: .idle, confirmationText: long, statusText: long)
        input.isHistoryPanelOpen = true
        let p = resolve(input)
        XCTAssertEqual(p.geometry.lowerSurfaceHeight,
                       VoiceBarNotchContract.historyLowerSurfaceHeight + (p.feedback?.height ?? 0))
    }
    func testBusyRecordingNoteKeepsOriginalControlsAndHeight() {
        let plain = resolve(.init(mode: .recording, showsRecordingHold: true))
        let p = resolve(.init(mode: .recording, showsRecordingHold: true,
                              transientNote: "Busy recording. Selection not read"))
        XCTAssertEqual(p.geometry.leadingWingWidth, plain.geometry.leadingWingWidth)
        XCTAssertEqual(p.geometry.trailingWingWidth, plain.geometry.trailingWingWidth)
        // N1/N3: at notch width the busy note wraps onto a second line and the tab grows down for it.
        XCTAssertEqual(p.geometry.lowerSurfaceHeight, p.feedbackHeight)
        XCTAssertEqual(p.feedback?.noteText, "Busy recording. Selection not read")
        XCTAssertGreaterThan(p.feedbackHeight, VoiceBarNotchContract.transientNoteBandHeight)
    }
    func testLongNoteUsesMultipleLinesAndLongDiagnosticsAreBounded() throws {
        for core: CGFloat in [120, 185, 280] {
            let p = resolve(.init(mode: .error, statusText: String(repeating: long, count: 20),
                                  coreWidth: core, transientNote: String(repeating: long, count: 20)))
            let f = try XCTUnwrap(p.feedback)
            XCTAssertGreaterThan(f.noteHeight, 26)
            XCTAssertLessThanOrEqual(f.height, VoiceBarNotchContract.transientNoteCanvasReserve - 6)
            XCTAssertEqual(f.statusText?.count, long.count * 20, "Viewport bounds never shorten stored text")
        }
    }
    func testCanvasIsStableWhenFeedbackClearsAndFitsNarrowDisplay() {
        for core: CGFloat in [120, 185, 280] {
            var a = VoiceBarNotchOperationalInput(mode: .idle, confirmationText: long, statusText: long, coreWidth: core)
            a.isHistoryPanelOpen = true
            var b = a; b.confirmationText = nil; b.statusText = ""
            let growing = resolve(a), cleared = resolve(b)
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: growing)
            XCTAssertEqual(canvas.canvasGeometry, VoiceBarNotchMorphCanvasLayout.resolve(for: cleared).canvasGeometry)
            XCTAssertGreaterThanOrEqual(canvas.canvasGeometry.totalHeight, growing.geometry.totalHeight)
            XCTAssertLessThanOrEqual(canvas.canvasGeometry.totalHeight + 17, 640)
            if core == 120 { XCTAssertLessThanOrEqual(canvas.canvasGeometry.totalWidth + 24, 520) }
        }
    }
    func testResidentModelPreservesStatusAndNoteLayout() {
        let p = resolve(.init(mode: .transcribing, statusText: long, transientNote: "Busy. Selection not read"))
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: false, hasCompactStatus: true,
            compactStatusLeadingWingWidth: p.geometry.leadingWingWidth,
            compactStatusTrailingWingWidth: p.geometry.trailingWingWidth,
            transientNoteWidth: p.transientNoteWidth, feedback: p.feedback)
        XCTAssertEqual(model.presentation, p)
    }
    func testFeedbackPassesPanelClickThroughGateButNotHardwareCore() {
        let p = resolve(.init(mode: .error, statusText: long))
        let layout = VoiceBarPanelLayout.make(presentation: p, interactionConfiguration: .none)
        let rect = layout.visibleContentRect
        XCTAssertTrue(layout.containsInteractiveContent(CGPoint(x: rect.midX, y: rect.minY + 16)))
        XCTAssertFalse(layout.containsInteractiveContent(CGPoint(x: rect.midX, y: rect.maxY - 16)))
    }
    func testConsecutiveErrorEventsRefreshResidentFeedbackWithoutChangingMode() {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: true)
        let model = VoiceBarNotchPresentationModel()
        var updates = 0
        func sync() {
            let text = VoiceBarPresentation.liveStatusText(mode: state.mode, transcript: "",
                confirmationText: state.confirmationText, hotkeyPhase: state.hotkeyPhase, hotkeyEnabled: true,
                errorMessage: state.errorMessage, transcribingStatusText: state.transcribingStatusText,
                commandModeState: nil, activeClipMarker: nil)
            let p = resolve(.init(mode: state.mode, statusText: text))
            model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: false,
                hasCompactStatus: p.visualState == .compactStatus,
                compactStatusLeadingWingWidth: p.geometry.leadingWingWidth,
                compactStatusTrailingWingWidth: p.geometry.trailingWingWidth,
                transientNoteWidth: p.transientNoteWidth, feedback: p.feedback)
        }
        state.onPanelLayoutChange = { updates += 1; sync() }
        defer { state.onPanelLayoutChange = nil }
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        state.handleEvent(["type": "error", "message": "First synthetic error"])
        drain()
        XCTAssertEqual(model.presentation.feedback?.statusText, "First synthetic error")
        updates = 0
        let next = "Second synthetic error with a different cause and substantially more detail"
        state.handleEvent(["type": "error", "message": next])
        drain()
        XCTAssertEqual(state.mode, .error)
        XCTAssertGreaterThan(updates, 0, "same-mode error changes must invalidate resident feedback")
        XCTAssertEqual(model.presentation.feedback?.statusText, next)
        updates = 0
        state.errorMessage = next
        drain()
        XCTAssertEqual(updates, 0, "identical messages do not churn panel layout")
        state.errorMessage = nil
        drain()
        XCTAssertNil(state.errorMessage)
        XCTAssertNotEqual(model.presentation.feedback?.statusText, next, "cleared error cannot remain in the resident model")
    }
    func testTeleprompterRetainsItsOriginalViewportBelowFeedback() {
        let p = resolve(.init(mode: .speaking, hasTeleprompterText: true, statusText: "Speaking…", transientNote: String(repeating: long, count: 2)))
        XCTAssertEqual(p.visualState, .teleprompter)
        XCTAssertEqual(p.geometry.lowerSurfaceHeight - p.feedbackHeight, 196)
    }
}
