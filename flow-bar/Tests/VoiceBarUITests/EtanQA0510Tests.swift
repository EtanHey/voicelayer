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

    /// N5: a quick grab (two samples, 0.01 s) moves the panel exactly as far as a slow drag over the same distance.
    /// Before, the first sample past the slop re-anchored the drag there, so a flick lost its whole first sample.
    func testN5QuickGrabTravelsAsFarAsASlowDrag() throws {
        func drag(samples: [CGFloat], seconds: Double) -> (raw: CGFloat, shown: CGFloat) {
            var pull = NotchHistoryPull()
            pull.press(y: 300, progress: 6, time: 0)
            var shown: CGFloat = 6
            for (index, y) in samples.enumerated() {
                shown = pull.move(y: y, time: seconds * Double(index + 1) / Double(samples.count),
                                  range: NotchHistoryMorph.rowHeight, band: { $0 }, seed: 6) ?? shown
            }
            return (pull.rawProgress, shown)
        }
        let slow = drag(samples: stride(from: 302, through: 365, by: 3).map { CGFloat($0) }, seconds: 0.3)
        let quick = drag(samples: [340, 365], seconds: 0.01)
        XCTAssertEqual(quick.raw, slow.raw, accuracy: NotchHistoryMorph.handoffAllowance / NotchHistoryMorph.rowHeight,
                       "[N5] a 0.01 s grab travels like a 0.3 s grab")
        XCTAssertEqual(NotchHistoryDetent.nearest(rows: quick.shown), .expanded, "[N5] the quick grab reaches 8 rows")
        XCTAssertEqual(NotchHistoryDetent.nearest(rows: slow.shown), .expanded, "fixture: the slow grab reaches 8 rows")
    }

    /// N4: pushing History's handle above the collapsed rows closes the panel WITH the pointer (it used to rubber-band
    /// and sit still), one row of travel per row climbed, reaching fully closed at the top.
    func testN4HandlePushedUpClosesThePanelWithThePointer() {
        let travel = NotchHistoryMorph.lowerSurfaceHeight(rows: 6)
        var previous: CGFloat = 1
        for raw in stride(from: CGFloat(6), through: -1, by: -0.5) {
            let follow = NotchHistoryMorph.handleDrag(rawRows: raw, maximum: 8, openTravel: travel)
            XCTAssertEqual(follow.rows, 6, "[N4] the rows stay collapsed while the panel closes")
            XCTAssertLessThanOrEqual(follow.progress, previous, "[N4] climbing never reopens the panel")
            previous = follow.progress
        }
        let oneRow = NotchHistoryMorph.handleDrag(rawRows: 5, maximum: 8, openTravel: travel).progress
        XCTAssertEqual((1 - oneRow) * travel, NotchHistoryMorph.rowHeight, accuracy: 0.001, "[N4] it tracks the pointer 1:1")
        XCTAssertEqual(NotchHistoryMorph.handleDrag(rawRows: -1, maximum: 8, openTravel: travel).progress, 0,
                       "[N4] at the top of the screen the panel is closed")
        XCTAssertEqual(NotchHistoryMorph.handleDrag(rawRows: 7.5, maximum: 8, openTravel: travel).progress, 1,
                       "pulling down still only extends the rows")
    }

    /// N6: "Release for Settings" fits the handle's band, under the last row, so it can never cover one.
    func testN6SettingsPullHintFitsTheHandleBand() {
        XCTAssertLessThanOrEqual(NotchHistoryPresentation.settingsPullHintHeight, NotchHistoryMorph.handleBandHeight,
                                 "[N6] the hint is no taller than the band it replaces the grip in")
        XCTAssertEqual(NotchHistoryPresentation.settingsPullHint, "Release for Settings", "[N6] the feature stays")
    }

    /// N9: every idle notice (Typed included) keeps the launcher's mic and microphone control; a parked read's
    /// controls are the only thing that takes that wing.
    func testN9IdleNoticesKeepTheMicrophoneControl() {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            keepsExpandedInDevState: true, pasteboard: NSPasteboard.withUniqueName())
        state.mode = .idle
        state.confirmationText = "Typed"
        XCTAssertTrue(VoiceBarPresentation.showsIdleMicrophoneControl(for: state), "[N9] Typed shows it")
        var input = VoiceBarNotchOperationalInput(mode: .idle, confirmationText: "Typed", isHovered: true)
        input.showsIdleMicrophoneControl = true
        let typed = VoiceBarPresentation.notchPresentation(from: input)
        XCTAssertEqual(typed.visualState, .compactStatus)
        XCTAssertEqual(typed.geometry.leadingWingWidth, VoiceBarNotchContract.fixedWingWidth,
                       "[N9] Typed's left wing holds the mic and its control, like the launcher's")
        state.mode = .recording
        XCTAssertFalse(VoiceBarPresentation.showsIdleMicrophoneControl(for: state))
    }

    func testN7DrawersCanOpenDuringRecording() {
        for event in [NotchSurfaceEvent.openHistory, .openSettings(.general)] {
            var machine = NotchSurfaceMachine()
            machine.send(.recordingChanged(true))
            machine.send(event)
            XCTAssertNotNil(machine.drawer, "[N7] recording must permit History and Settings")
        }
    }

    func testN8MachineRetainsDrawerAcrossRecordingLifecycle() {
        for event in [NotchSurfaceEvent.openHistory, .openSettings(.general)] {
            var machine = NotchSurfaceMachine()
            machine.send(event)
            let drawer = machine.drawer
            XCTAssertNotNil(drawer, "fixture: drawer opened before recording")
            machine.send(.recordingChanged(true))
            XCTAssertEqual(machine.drawer, drawer, "[N8] keep the drawer while recording")
            machine.send(.recordingChanged(false))
            XCTAssertEqual(machine.drawer, drawer, "[N8] retain the drawer after recording ends")
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
            for mode in [VoiceMode.recording, .transcribing, .idle] {
                state.mode = mode
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                XCTAssertEqual(surface.drawer, drawer, "[N8] real BarView keeps the drawer through \(mode)")
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
