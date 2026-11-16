import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchLookRenderTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    func testRenderStatesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTCH_LOOK_SHOTS"] else {
            throw XCTSkip("Set NOTCH_LOOK_SHOTS to save offscreen renders")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for inset: CGFloat in [0, 12] {
            for light in [false, true] {
                for phase in ["transcribing", "recording-first", "recording-live", "history-overpull"] {
                    let state = VoiceState(
                        recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                        recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                        transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
                        keepsExpandedInDevState: false)
                    state.sendCommand = { _ in }
                    state.isConnected = true
                    state.isCollapsed = false
                    state.recordingTimingClock = { 100 }
                    state.recentTranscriptionEntries = (0..<8).map {
                        RecentTranscriptionEntry(text: "Synthetic garden row \($0)", recordingPath: "/synthetic/\($0).wav")
                    }
                    if phase.hasPrefix("recording") {
                        state.handleEvent(["type": "state", "state": "recording", "mode": "ptt"])
                        if phase == "recording-live" { state.handleEvent(["type": "audio_level", "rms": 0.45]) }
                    } else if phase == "transcribing" {
                        state.handleEvent(["type": "state", "state": "transcribing"])
                    }
                    let p = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
                        mode: state.mode, isCollapsed: false, visibleCoreOcclusionInset: inset))
                    let model = VoiceBarNotchPresentationModel()
                    model.updateOperationalEnvelope(hasTeleprompter: false,
                        isRecording: phase.hasPrefix("recording"), hasCompactStatus: phase == "transcribing",
                        compactStatusLeadingWingWidth: p.geometry.leadingWingWidth,
                        compactStatusTrailingWingWidth: p.geometry.trailingWingWidth,
                        recordingLeadingWingWidth: p.geometry.leadingWingWidth,
                        recordingTrailingWingWidth: p.geometry.trailingWingWidth,
                        visibleCoreOcclusionInset: inset)
                    var bar = BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                        presentationModel: model, includesPanelOutsets: true)
                    if phase == "history-overpull" {
                        model.setHistoryPanelOpen(true)
                        bar = bar.presentingSettingsPullHintForShots().freezingHistoryMorph(at: 1.12)
                    }
                    let view = bar.environment(\.colorScheme, light ? .light : .dark)
                        .environment(\.visualRenderTime, 101.5)
                        .frame(width: 700, height: 680, alignment: .top)
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
                    host.frame = CGRect(x: 0, y: 0, width: 700, height: 680)
                    let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                        backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = host.appearance
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                    host.layoutSubtreeIfNeeded()
                    func measure(_ v: NSView) {
                        if let tooltip = v.toolTip, !v.visibleRect.isEmpty {
                            let rect = v.convert(v.bounds, to: host)
                            print("NOTCH_MEASURE \(phase) \(light ? "light" : "dark") inset=\(inset) \(tooltip) \(rect)")
                        }
                        v.subviews.forEach(measure)
                    }
                    measure(host)
                    let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                        pixelsWide: 1400, pixelsHigh: 1360, bitsPerSample: 8, samplesPerPixel: 4,
                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                    rep.size = host.frame.size
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let name = "\(phase)-\(inset == 0 ? "flat" : "notch")-\(light ? "light" : "dark").png"
                    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent(name))
                }
            }
        }
    }
}
