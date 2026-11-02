import AppKit
import SwiftUI
import Vision
import OffscreenTestSupport
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchStatusFeedbackTests: XCTestCase {
    private let long = "The speech model could not finish this transcription. Open History and select the retained recording to retry when the model is available."
    private func resolve(_ input: VoiceBarNotchOperationalInput) -> VoiceBarNotchPresentation {
        VoiceBarPresentation.notchPresentation(from: input)
    }
    func testTranscribingNeverAddsAStatusBand() {
        for text in ["Transcribing", long] {
            let p = resolve(.init(mode: .transcribing, statusText: text))
            XCTAssertNil(p.feedback)
            XCTAssertEqual(p.geometry.lowerSurfaceHeight, 0)
        }
    }
    func testFullErrorSurvivesInsideCompactNoteShellWithHistory() throws {
        let p = resolve(.init(mode: .error, statusText: long))
        let f = try XCTUnwrap(p.feedback)
        XCTAssertEqual(f.statusText, long)
        XCTAssertTrue(f.opensHistory)
        XCTAssertEqual(f.width, p.geometry.topWidth)
        XCTAssertEqual(p.geometry.bodyLeadingExtent, p.geometry.leadingWingWidth)
        XCTAssertEqual(p.geometry.bodyTrailingExtent, p.geometry.trailingWingWidth)
    }
    func testHistoryReservesInlineWidthWithoutAddingAnActionRow() throws {
        for core: CGFloat in [120, 185, 280] {
            for text in ["Busy", long, String(repeating: long, count: 20)] {
                let p = resolve(.init(mode: .error, statusText: text, coreWidth: core))
                let f = try XCTUnwrap(p.feedback)
                let textWidth = VoiceBarNotchFeedback.messageWidth(f.width, opensHistory: true)
                XCTAssertEqual(textWidth, f.width - 32 - 96 - 8)
                XCTAssertEqual(f.statusHeight, max(VoiceBarNotchContract.transientNoteBandHeight,
                    min(VoiceBarNotchFeedback.maximumTextHeight,
                        VoiceBarNotchFeedback.textHeight(text, width: textWidth)) + 10))
                XCTAssertEqual(f.statusText, text)
                XCTAssertEqual(f.width, p.geometry.topWidth)
                if text == "Busy" {
                    XCTAssertEqual(f.statusHeight, VoiceBarNotchContract.transientNoteBandHeight)
                }
            }
        }
    }
    func testHistoryActionRendersBesideFullMessage() throws {
        for text in ["Busy", long] {
            let f = try XCTUnwrap(resolve(.init(mode: .error, statusText: text)).feedback)
            let host = NSHostingView(rootView: VoiceBarNotchFeedbackBand(feedback: f, onOpenHistory: {})
                .foregroundStyle(.white).background(.black))
            host.frame = NSRect(x: 0, y: 0, width: f.width, height: f.height)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            VLOrderTestWindow(window)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
            func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views($0) } }
            let message = try XCTUnwrap(views(host).first { $0.accessibilityValue() as? String == text })
            let messageFrame = message.convert(message.bounds, to: host)
            XCTAssertTrue(host.bounds.contains(messageFrame), "Full message stays in the compact shell")
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
            // The diagnostic can itself say "Open History"; the action is the trailing occurrence.
            let boxes = try candidates.compactMap { candidate -> CGRect? in
                guard let range = candidate.string.range(of: "Open History", options: .backwards) else { return nil }
                return try candidate.boundingBox(for: range)?.boundingBox
            }
            let box = try XCTUnwrap(boxes.max { $0.minX < $1.minX },
                                   "Inline action must render legibly: \(candidates.map(\.string))")
            let actionFrame = CGRect(x: box.minX * host.bounds.width,
                y: (host.isFlipped ? 1 - box.maxY : box.minY) * host.bounds.height,
                width: box.width * host.bounds.width, height: box.height * host.bounds.height)
            XCTAssertLessThanOrEqual(messageFrame.maxX, actionFrame.minX, "History trails the message")
            XCTAssertGreaterThan(min(messageFrame.maxY, actionFrame.maxY),
                                 max(messageFrame.minY, actionFrame.minY), "Action shares the message row")
        }
    }
    func testQuitRefusalWrapsDownwardWithoutWideningTheCompactShell() throws {
        let text = "Finish voice work or cancel the update, then quit again."
        let p = resolve(.init(mode: .idle, confirmationText: text, statusText: text, coreWidth: 120))
        let f = try XCTUnwrap(p.feedback)
        XCTAssertEqual(f.statusText, text)
        XCTAssertEqual(f.width, p.geometry.topWidth)
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
        func field(_ view: NSView) -> NSView? {
            if let label = view as? NSTextField, label.stringValue == text { return label }
            // Selectable SwiftUI Text can mount as NSTextView.
            if let label = view as? NSTextView, label.string == text { return label }
            // macOS 27 uses AppKitTextInteractionView, exposing the full string
            // through accessibility while retaining the actual text layout bounds.
            if view.accessibilityValue() as? String == text { return view }
            return view.subviews.compactMap { field($0) }.first
        }
        let label = try XCTUnwrap(field(host), "Full quit instruction must be mounted")
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        XCTAssertEqual(Int((label.bounds.height / lineHeight).rounded()), 2, "Rendered lines, independent of OCR")
        XCTAssertTrue(host.bounds.contains(label.convert(label.bounds, to: host)))
    }
    func testAnyLongNoteStaysWithinExistingShellAcrossCoreSizesAndResidentModel() throws {
        let note = "Finish voice work or cancel the update, then quit again. " + long
        for core: CGFloat in [120, 185, 280] {
            for mode in [VoiceMode.idle, .recording, .transcribing, .error, .speaking] {
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
                XCTAssertEqual(p.geometry.bodyLeadingExtent, shell.bodyFlushWithWings.bodyLeadingExtent)
                XCTAssertEqual(p.geometry.bodyTrailingExtent, shell.bodyFlushWithWings.bodyTrailingExtent)
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
    func testFitTextKeepsOriginalWingAndNoExtraBand() {
        for text in ["Typed", "Copied", "F5 to talk", "Not pasted\nIn History"] {
            XCTAssertNil(resolve(.init(mode: .idle, confirmationText: text, statusText: text)).feedback)
        }
        XCTAssertEqual(resolve(.init(mode: .error, statusText: "Busy")).feedback?.replacesWingText, false)
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
                XCTAssertNil(p.feedback)
                XCTAssertNotNil(p.transientNoteRect, "The original compact selection note remains visible")
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
        XCTAssertEqual(p.geometry.lowerSurfaceHeight, 26)
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
