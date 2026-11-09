import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest
import Vision

/// Raw product assertions for the 00b9d380 QA. Strict XFAIL never absorbs fixture/render errors.
@MainActor
final class EtanQA0510Tests: XCTestCase {
    private func expected(_ row: String, _ body: () -> Void) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = { $0.type == .assertionFailure && $0.compactDescription.contains("[" + row + "]") }
        XCTExpectFailure("[" + row + "] Etan 2026-11-09", options: options, failingBlock: body)
    }

    /// AX hit-testing is not visibility: use the actual painted copy, with an OCR positive control. The panes are the
    /// real Settings panes the app embeds (N1); descriptions may remain as tooltips.
    func testN2NoExplanatoryProsePaintedInDrawer() throws {
        let prose = ["local recognizer", "spell your way", "used on every dictation"]
        for tab in [SettingsTab.transcription, .dictionary] {
            let drawer = NotchSettingsDrawer(selectedTab: tab, appearance: .dark, context: Self.settingsPaneContext(),
                                             onSelectTab: { _ in })
            let (text, _) = try Self.paintedText(drawer)
            XCTAssertTrue(text.contains(tab.title.lowercased()), "fixture: OCR must read the selected tab")
            for phrase in prose {
                XCTAssertFalse(text.contains(phrase), "[N2] explanatory prose '\(phrase)' painted in \(tab.title)")
            }
        }
    }

    /// The Settings window's own panes, from a minimal synthetic SettingsView (the app builds them from its stores).
    static func settingsPaneContext() -> NotchSettingsDrawerContext {
        NotchSettingsDrawerContext(updates: nil, pane: { tab, request in
            AnyView(SettingsView(
                hotkeyEnabled: true, missingPermissions: [],
                availableDevices: { [MicrophoneDevice(id: "qa", name: "QA microphone A")] },
                selectedDeviceID: { "qa" }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
                vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
                initialTab: tab, tabRequest: request
            ).notchDrawerPane(tab))
        })
    }

    /// Renders `view` offscreen and returns the painted text (Vision OCR), lowercased, plus the host for view checks.
    static func paintedText(_ view: some View, size: CGSize = CGSize(width: 420, height: 394)) throws -> (String, NSView) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.black))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return (text.lowercased(), host)
    }

    static func containsScrollView(_ view: NSView) -> Bool {
        view is NSScrollView || view.subviews.contains(where: containsScrollView)
    }

    /// R2: every tab paints the window's own settings pane (it scrolls inside the drawer), or History's own rows,
    /// and none hands off to the Settings window. Offscreen SwiftUI exposes no AX tree, so this reads what is painted.
    func testN1EveryNotchTabHoldsRealSettingsNotAHandoff() throws {
        let expectedSetting: [SettingsTab: String] = [
            .general: "microphone priority", .transcription: "recognizer", .dictionary: "add term",
            .speech: "voice profile threshold", .history: "qa history row",
        ]
        for tab in SettingsTab.allCases {
            let drawer = NotchSettingsDrawer(selectedTab: tab, appearance: .dark, context: Self.settingsPaneContext(),
                history: { AnyView(Text("QA history row").font(.system(size: 13))) }, onSelectTab: { _ in })
            let (text, host) = try Self.paintedText(drawer)
            XCTAssertTrue(text.contains(tab.title.lowercased()), "fixture: OCR reads the tab bar")
            print("[N1] \(tab.title) painted=\(text.prefix(160))")
            XCTAssertFalse(text.contains("all settings") || text.contains("open \(tab.title.lowercased()) settings"),
                           "[N1] \(tab.title) still hands off to the window")
            XCTAssertTrue(text.contains(expectedSetting[tab]!), "[N1] \(tab.title) does not show its real settings")
            if tab != .history {
                XCTAssertTrue(Self.containsScrollView(host), "[N1] \(tab.title) pane scrolls inside the drawer")
            }
        }
    }

    func testN7DrawersCanOpenDuringRecording() {
        for event in [NotchSurfaceEvent.openHistory, .openSettings(.general)] {
            var machine = NotchSurfaceMachine()
            machine.send(.recordingChanged(true))
            expected("N7") {
                machine.send(event)
                XCTAssertNotNil(machine.drawer, "[N7] recording must permit History and Settings")
            }
        }
    }

    func testN8MachineRetainsDrawerAcrossRecordingLifecycle() {
        for event in [NotchSurfaceEvent.openHistory, .openSettings(.general)] {
            var machine = NotchSurfaceMachine()
            machine.send(event)
            let drawer = machine.drawer
            XCTAssertNotNil(drawer, "fixture: drawer opened before recording")
            machine.send(.recordingChanged(true))
            expected("N8") {
                XCTAssertEqual(machine.drawer, drawer, "[N8] keep the drawer while recording")
                machine.send(.recordingChanged(false))
                XCTAssertEqual(machine.drawer, drawer, "[N8] retain the drawer after recording ends")
            }
        }
    }

    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    func testN8RealViewKeepsDrawerDuringTranscribing() {
        for drawer in [NotchDrawer.history(.collapsed), .settings(.general)] {
            let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                keepsExpandedInDevState: true, pasteboard: NSPasteboard.withUniqueName())
            state.mode = .idle
            let surface = NotchSurfaceModel()
            surface.log = { _ in }
            if case .history = drawer { surface.send(.openHistory) } else { surface.send(.openSettings(.general)) }
            let host = NSHostingView(rootView: BarView(state: state, commandRouter: Router(),
                onOpenSettings: {}, onOpenHistory: {}, surface: surface))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 450),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            VLOrderTestWindow(window)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(surface.drawer, drawer, "fixture: drawer mounted before mode change")
            state.mode = .transcribing
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            expected("N8") {
                XCTAssertEqual(surface.drawer, drawer, "[N8] real BarView dismisses drawer on transcribing mode change")
            }
        }
    }

    func testT3NoReadingProse() {
        expected("T3") {
            XCTAssertEqual(TeleprompterA.footerState(isPaused: false, isPausedForDictation: false), "", "[T3] remove Reading prose")
        }
    }

    /// Render every tab selected in turn. A declaration of Image is not proof that its glyph painted.
    /// This is a normal assertion: intermittent N3 must not be made artificially red on a good frame.
    func testN3AllTabGlyphsPaintForEverySelection() throws {
        for controlState in ControlActiveState.allCases {
        for selected in SettingsTab.allCases {
            let drawer = NotchSettingsDrawer(selectedTab: selected, appearance: .dark,
                context: NotchSettingsDrawerContext(updates: nil), onSelectTab: { _ in })
            let host = NSHostingView(rootView: drawer.frame(width: 420, height: 348).background(Color.black)
                .environment(\.controlActiveState, controlState))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 348),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            VLOrderTestWindow(window)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / 420
            for (index, tab) in SettingsTab.allCases.enumerated() {
                // 8 pt horizontal padding, 5 equal tabs separated by 2 pt; icons sit above the text baseline.
                let centre = 8 + (CGFloat(index) + 0.5) * (404 / 5)
                var bright = 0
                for y in Int(8 * scale)..<Int(24 * scale) {
                    for x in Int((centre - 11) * scale)..<Int((centre + 11) * scale) {
                        let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.45 { bright += 1 }
                    }
                }
                XCTAssertGreaterThan(bright, 8, "[N3] \(tab.title) glyph absent with \(selected.title) selected, control state=\(controlState); pixels=\(bright)")
            }
        }
        }
    }
}
