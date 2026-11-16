import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor final class RecordingReservationTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }
    func testCalibratedFourSlotWingFitsTheStableCanvas() {
        for inset: CGFloat in [0, 8.5, 10, 12, 24] {
            let plain = VoiceBarPresentation.notchPresentation(from: .init(mode: .recording,
                visibleCoreOcclusionInset: inset))
            let spinner = VoiceBarPresentation.notchPresentation(from: .init(mode: .recording,
                visibleCoreOcclusionInset: inset, showsEarlierTakeProcessing: true))
            XCTAssertEqual(plain.geometry.leadingWingWidth, 88.5 + inset)
            XCTAssertEqual(spinner.geometry.leadingWingWidth, 114.5 + inset)
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: plain).canvasGeometry
            print("R1_CANVAS inset=\(inset) leading=\(spinner.geometry.leadingWingWidth) capacity=\(canvas.leadingWingWidth)")
            XCTAssertEqual(canvas, VoiceBarNotchMorphCanvasLayout.resolve(for: spinner).canvasGeometry,
                           "spinner arrival cannot resize the canvas or move the core")
            XCTAssertLessThanOrEqual(spinner.geometry.leadingWingWidth, canvas.leadingWingWidth)
            XCTAssertLessThanOrEqual(spinner.geometry.trailingWingWidth, canvas.trailingWingWidth)
            let layout = VoiceBarPanelLayout.make(presentation: spinner, canvasGeometry: canvas)
            XCTAssertGreaterThanOrEqual(layout.visibleContentRect.minX, 0)
            XCTAssertLessThanOrEqual(layout.visibleContentRect.maxX, layout.panelSize.width)
        }
    }

    func testRecordedM4FourSlotBandAndEntryModelDomain() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/notch-geometry-m4-mac16-5.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let row = try XCTUnwrap((fixture["screens"] as? [[String: Any]])?.first)
        func rect(_ key: String) throws -> CGRect {
            let d = try XCTUnwrap(row[key] as? [String: Double])
            return CGRect(x: try XCTUnwrap(d["x"]), y: try XCTUnwrap(d["y"]),
                          width: try XCTUnwrap(d["width"]), height: try XCTUnwrap(d["height"]))
        }
        let screen = VoiceBarNotchScreenGeometry.resolve(metrics: .init(frame: try rect("frame"),
            visibleFrame: try rect("visibleFrame"), safeAreaTop: 32,
            auxiliaryTopLeftArea: try rect("auxiliaryTopLeftArea"), auxiliaryTopRightArea: try rect("auxiliaryTopRightArea")))
        XCTAssertEqual(screen.visibleCoreOcclusionInset, 8.5)
        let p = VoiceBarPresentation.notchPresentation(from: .init(mode: .recording,
            coreWidth: screen.housingFrame.width, visibleCoreOcclusionInset: screen.visibleCoreOcclusionInset,
            showsEarlierTakeProcessing: true))
        XCTAssertEqual(p.geometry.leadingWingWidth, 123)
        XCTAssertLessThanOrEqual(p.geometry.leadingWingWidth, 130, "recorded M4 fits even the compact bound")
        XCTAssertLessThanOrEqual(p.geometry.leadingWingWidth,
            VoiceBarNotchMorphCanvasLayout.resolve(for: p).canvasGeometry.leadingWingWidth)
        for inset: CGFloat in [0, screen.visibleCoreOcclusionInset] {
            for earlier in [false, true] {
                let p = VoiceBarPresentation.notchPresentation(from: .init(mode: .recording,
                    visibleCoreOcclusionInset: inset, showsEarlierTakeProcessing: earlier))
                let growth = p.geometry.leadingWingWidth - VoiceBarNotchContract.fixedWingWidth
                XCTAssertGreaterThan(growth, 0, "wing-entry's growing-wing premise is restored")
                let ticks = VoiceBarNotchWingContentEntry.delay(forGrowth: growth) * 120
                XCTAssertLessThanOrEqual(ticks, 21, "supported flat/M4 cover stays within the existing model's 21 ticks")
                print("R1_ENTRY inset=\(inset) earlier=\(earlier) growth=\(growth) coverTicks=\(ticks)")
            }
        }
    }

    func testLateTakeTypeAndEarlierSpinnerKeepStopAndCancelFrames() throws {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] }, keepsExpandedInDevState: false)
        state.sendCommand = { _ in }; state.isConnected = true; state.isCollapsed = false
        state.mode = .recording
        let host = NSHostingView(rootView: BarView(state: state, commandRouter: Router(), onOpenSettings: {},
            onOpenHistory: {}, includesPanelOutsets: true).frame(width: 700, height: 500))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; VLOrderTestWindow(window)
        defer { window.contentView = nil; window.close() }
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.4)); host.layoutSubtreeIfNeeded() }
        func frame(_ tooltip: String, _ view: NSView) -> CGRect? {
            if view.toolTip == tooltip { return view.convert(view.bounds, to: host) }
            return view.subviews.lazy.compactMap { frame(tooltip, $0) }.first
        }
        settle()
        let stop = try XCTUnwrap(frame("Stop recording", host)); let cancel = try XCTUnwrap(frame("Cancel recording", host))
        state.recordingMode = "ptt"; settle()
        let microphone = try XCTUnwrap(frame("Pause recording", host))
        XCTAssertEqual(microphone.midX, (stop.midX + cancel.midX) / 2, accuracy: 0.001,
                       "the microphone fills the slot reserved between Stop and Cancel")
        XCTAssertEqual(try XCTUnwrap(frame("Stop recording", host)), stop, "late PTT must not move Stop")
        XCTAssertEqual(try XCTUnwrap(frame("Cancel recording", host)), cancel, "late PTT must not move Cancel")
        state.setRecordingPaused(true); settle()
        XCTAssertEqual(try XCTUnwrap(frame("Stop recording", host)), stop)
        XCTAssertEqual(try XCTUnwrap(frame("Cancel recording", host)), cancel)
        let pausedMicrophone = try XCTUnwrap(frame("Resume recording", host))
        XCTAssertEqual(pausedMicrophone, microphone, "pausing keeps the microphone frame")
        state.handleEvent(["type": "state", "state": "recording", "mode": "ptt", "mic_take_id": "B",
            "recording_jobs": [["take_id": "A", "kind": "live", "phase": "processing"],
                               ["take_id": "B", "kind": "live", "phase": "capturing"]]]); settle()
        XCTAssertEqual(try XCTUnwrap(frame("Stop recording", host)), stop)
        XCTAssertEqual(try XCTUnwrap(frame("Cancel recording", host)), cancel)
        let micAfterSpinner = frame("Resume recording", host) ?? frame("Pause recording", host)
        XCTAssertEqual(try XCTUnwrap(micAfterSpinner), microphone, "spinner arrival keeps the microphone frame")
        state.handleEvent(["type": "state", "state": "idle", "recording_jobs": []]); settle()
        // VAD type is supplied in the state event before recording is published. Lock selection and an earlier
        // take may arrive later; neither changes these controls' positions.
        state.mode = .idle; state.recordingMode = "vad"; state.mode = .recording; settle()
        let vadStop = try XCTUnwrap(frame("Stop recording", host)); let vadCancel = try XCTUnwrap(frame("Cancel recording", host))
        state.setRecordingHold(true); settle()
        XCTAssertEqual(try XCTUnwrap(frame("Stop recording", host)), vadStop)
        XCTAssertEqual(try XCTUnwrap(frame("Cancel recording", host)), vadCancel)
        state.handleEvent(["type": "state", "state": "recording", "mode": "vad", "mic_take_id": "B",
            "recording_jobs": [["take_id": "A", "kind": "live", "phase": "processing"],
                               ["take_id": "B", "kind": "live", "phase": "capturing"]]]); settle()
        XCTAssertEqual(state.processingTakeCount, 1, "the earlier spinner actually arrived")
        XCTAssertEqual(try XCTUnwrap(frame("Stop recording", host)), vadStop)
        XCTAssertEqual(try XCTUnwrap(frame("Cancel recording", host)), vadCancel)
    }
}
