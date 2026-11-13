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

    /// Draws `host` at a fixed 2x backing scale. `bitmapImageRepForCachingDisplay` follows the machine's screen, so a
    /// 1x CI runner got half the pixels: OCR misread the tab bar and the N10 gap rounded to 5 pt (CI run 42680588819).
    static func fixedScaleBitmap(_ host: NSView, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let size = host.bounds.size
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Renders `view` offscreen and returns the painted text (Vision OCR), lowercased, plus the host for view checks.
    /// `expecting` re-reads (up to ~3 s) until that text appears, so a slow runner that paints a pane late is not a
    /// false failure; a pane that never paints it still fails the caller's assertion.
    static func paintedText(_ view: some View, size: CGSize = CGSize(width: 420, height: 394),
                            expecting: String? = nil) throws -> (String, NSView) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.black))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        var text = ""
        for _ in 0 ..< 5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let bitmap = try Self.fixedScaleBitmap(host)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").lowercased()
            guard let expecting, !text.contains(expecting) else { break }
        }
        return (text, host)
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
                // An explicit ink: a bare Text follows the system appearance, so a light-mode CI runner drew it black on
                // the black drawer (CI run 42689942140). The real NotchHistoryPanel uses the notch palette.
                history: { AnyView(Text("QA history row").font(.system(size: 13)).foregroundStyle(.white)) }, onSelectTab: { _ in })
            let (text, host) = try Self.paintedText(drawer, expecting: expectedSetting[tab]!)
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

    /// QA 0449 supersedes N10: clear separation and painted vertical centring, at fixed 2x.
    func testN10RecordingWaveformHasAClearGapAndSharesTheTimerCentre() throws {
        let row = VoiceBarRecordingTrailingRow {
            VoiceBarRecordingTimeRegion(elapsedMilliseconds: { 2_000 }, isCaptureOpen: true, microphoneName: nil,
                                        color: .white)
        } meter: {
            VoiceBarNotchWaveform(mode: .recording, isListening: false, isCaptureLive: true,
                                  recordingLevel: { 0 }, playbackLevel: { nil })
        }
        .environment(\.visualRenderTime, 1)
        let host = NSHostingView(rootView: row.frame(width: 130, height: 32).background(Color.black))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 130, height: 32), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let bitmap = try Self.fixedScaleBitmap(host)
        var lastDigit = -1, firstBar = Int.max
        var digits = CGRect.null, bars = CGRect.null
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh {
                let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.6 {
                    lastDigit = max(lastDigit, x); digits = digits.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
                if c.redComponent > 0.5, c.greenComponent < 0.45 {
                    firstBar = min(firstBar, x); bars = bars.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        XCTAssertGreaterThanOrEqual(lastDigit, 0, "fixture: the time paints")
        XCTAssertLessThan(firstBar, Int.max, "fixture: the meter paints")
        let gap = CGFloat(firstBar - lastDigit) * 130 / CGFloat(bitmap.pixelsWide)
        let offset = abs(digits.midY - bars.midY) / 2
        print("[0449 E1] gap=\(gap) pt, vertical centre offset=\(offset) pt")
        // C7-W (Etan, 2026-11-11: "no enough gap"): 6 pt read as too tight; the row now paints about 10 pt.
        XCTAssertGreaterThanOrEqual(gap, 9, "[0449 E1] the digits and bars have a clear gap")
        XCTAssertLessThanOrEqual(gap, 10.5, "[C7-W] aim for 10 pt")
        XCTAssertLessThanOrEqual(offset, 1, "[0449 E1] the painted centres align")
    }

    func test0449RecordingWingsPaintEqualSpaceAroundTheNotch() throws {
        for hold in [false, true] {
            for inset: CGFloat in [0, 8.5] {
                let p = VoiceBarPresentation.notchPresentation(from: .init(
                    mode: .recording, showsRecordingHold: hold, visibleCoreOcclusionInset: inset))
                let g = p.geometry
                let host = NSHostingView(rootView: VoiceBarNotchContinuousShape(geometry: g).fill(.white)
                    .frame(width: g.totalWidth, height: 32).background(Color.black))
                host.frame.size = CGSize(width: g.totalWidth, height: 32)
                host.layoutSubtreeIfNeeded()
                let bitmap = try Self.fixedScaleBitmap(host)
                var left = Int.max, right = -1
                for x in 0 ..< bitmap.pixelsWide {
                    if let c = bitmap.colorAt(x: x, y: 8)?.usingColorSpace(.deviceRGB), c.redComponent > 0.8 {
                        left = min(left, x); right = max(right, x)
                    }
                }
                XCTAssertGreaterThan(right, left, "fixture: the shell paints")
                let l = g.coreOriginX - CGFloat(left) / 2
                let r = CGFloat(right + 1) / 2 - g.coreOriginX - g.coreWidth
                print("[0449 E2] hold=\(hold) inset=\(inset) left=\(l) right=\(r)")
                XCTAssertEqual(l, r, accuracy: 2, "[0449 E2] equal space either side of the notch")
            }
        }
    }

    /// Review F2: in the notch drawer, Dictionary's Add/Edit cover owns Esc. Esc cancels the cover and returns to
    /// Dictionary with the drawer kept (the next Esc closes the drawer); Return saves and Cancel cancels through the
    /// editor's own buttons; the drawer stays open throughout.
    func testF2TheDictionaryCoverOwnsEscapeAndKeepsTheDrawer() throws {
        let ownership = NotchEscapeOwnership()
        let surface = NotchSurfaceModel()
        surface.log = { _ in }
        surface.send(.openSettings(.dictionary))
        let dismissal = NotchDrawerDismissal { surface.send(.dismiss($0)) }
        dismissal.escapeOwnership = ownership
        dismissal.escapeIsOwnedElsewhere = { false }

        final class Box: ObservableObject { @Published var edit: DictionaryTermEdit? }
        struct Host: View {
            @ObservedObject var box: Box
            let ownership: NotchEscapeOwnership
            let onSave: (DictionaryTermEdit) -> Void
            let onCancel: () -> Void
            var body: some View {
                Color.black.modifier(DictionaryTermEditorPresentation(
                    edit: $box.edit, inDrawer: true, escapeOwnership: ownership) { edit in
                    DictionaryAddSheetView(edit: edit, existingEntries: [], onSave: onSave, onCancel: onCancel)
                })
            }
        }
        let box = Box()
        var saved: [String] = [], cancelled = 0
        let host = NSHostingView(rootView: Host(box: box, ownership: ownership,
            onSave: { saved.append($0.correct); box.edit = nil }, onCancel: { cancelled += 1; box.edit = nil }))
        host.frame = CGRect(x: 0, y: 0, width: 404, height: 330)
        let panel = FloatingPillPanel(content: host)
        panel.isPillDragEnabled = false
        defer { panel.orderOut(nil); panel.close() }
        VLOrderTestWindow(panel)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func key(_ characters: String, _ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }

        // Escape: the cover cancels, the drawer stays on Dictionary.
        box.edit = DictionaryTermEdit(correct: "Kubernetes draft")
        settle()
        XCTAssertTrue(ownership.isOwned, "fixture: the open cover claims Esc")
        XCTAssertTrue(dismissal.handleLocalKeyDown(keyCode: NotchDrawerDismissal.escapeKeyCode), "Esc is consumed")
        settle()
        XCTAssertNil(box.edit, "[F2] Esc cancels the cover")
        XCTAssertEqual(surface.drawer, .settings(.dictionary), "[F2] and the drawer stays on Dictionary")
        XCTAssertFalse(ownership.isOwned, "the closed cover releases Esc")

        // Return: the editor saves through its default action; the drawer stays.
        box.edit = DictionaryTermEdit(correct: "Kubernetes")
        settle()
        XCTAssertTrue(host.performKeyEquivalent(with: try key("\r", 36)), "Return reaches the editor")
        settle()
        XCTAssertEqual(saved, ["Kubernetes"], "[F2] Return saves the term")
        XCTAssertEqual(surface.drawer, .settings(.dictionary))

        // Cancel: the editor's Cancel (its cancel action) closes the cover only.
        box.edit = DictionaryTermEdit(correct: "Draft")
        settle()
        XCTAssertTrue(host.performKeyEquivalent(with: try key("\u{1b}", NotchDrawerDismissal.escapeKeyCode)))
        settle()
        XCTAssertEqual(cancelled, 1, "[F2] Cancel cancels the cover")
        XCTAssertNil(box.edit)
        XCTAssertEqual(surface.drawer, .settings(.dictionary), "[F2] the drawer is retained")

        // With no cover, Esc closes the drawer as before.
        XCTAssertTrue(dismissal.handleLocalKeyDown(keyCode: NotchDrawerDismissal.escapeKeyCode))
        XCTAssertNil(surface.drawer, "the next Esc closes the drawer")
    }

    /// Review F4: the chevron's destination is the Microphone priority list itself, not merely General. With three
    /// permissions missing, Setup fills the top of General; the chevron's request scrolls the list to the top.
    func testF4TheMicrophoneRequestScrollsGeneralToMicrophonePriority() throws {
        func headerTop(_ request: SettingsTabRequest?) throws -> CGFloat? {
            let context = NotchSettingsDrawerContext(updates: nil, pane: { tab, request in
                AnyView(SettingsView(
                    hotkeyEnabled: false, missingPermissions: [.microphone, .accessibility, .inputMonitoring],
                    availableDevices: { [MicrophoneDevice(id: "qa", name: "QA microphone A")] },
                    selectedDeviceID: { "qa" }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
                    vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
                    initialTab: tab, tabRequest: request
                ).notchDrawerPane(tab))
            })
            let drawer = NotchSettingsDrawer(selectedTab: .general, appearance: .dark, context: context,
                                             request: request, onSelectTab: { _ in })
            let host = NSHostingView(rootView: drawer.frame(width: 420, height: 394).background(Color.black))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 394), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            VLOrderTestWindow(window)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let bitmap = try Self.fixedScaleBitmap(host)
            let ocr = VNRecognizeTextRequest()
            ocr.recognitionLevel = .accurate
            ocr.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([ocr])
            let header = (ocr.results ?? []).first {
                $0.topCandidates(1).first?.string.lowercased().contains("microphone priority") == true
            }
            // Vision boxes are normalised with a bottom-left origin; return points from the drawer's top.
            return header.map { (1 - $0.boundingBox.maxY) * 394 }
        }
        let focused = try XCTUnwrap(
            headerTop(SettingsTabRequest(tab: .general, focus: .microphonePriority, id: 1)),
            "[F4] Microphone priority is on screen after the chevron's request")
        XCTAssertLessThan(focused, 46 + 6 + 60, "[F4] the requested list sits at the top of the pane, under the tabs")
        let unfocused = try headerTop(nil)
        print("[F4] Microphone priority header top: focused=\(focused) unfocused=\(String(describing: unfocused))")
        if let unfocused {
            XCTAssertGreaterThan(unfocused, focused + 20, "fixture: without the request, Setup sits above the list")
        }
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

    /// Fixed (T3): reading draws no "Reading" prose.
    func testT3NoReadingProse() {
        XCTAssertEqual(TeleprompterA.footerState(isPaused: false, isPausedForDictation: false), "", "[T3] remove Reading prose")
    }

    /// Render every tab selected in turn. A declaration of Image is not proof that its glyph painted.
    /// This is a normal assertion: intermittent N3 must not be made artificially red on a good frame.
    func testN3AllTabGlyphsPaintForEverySelection() throws {
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
        for controlState in ControlActiveState.allCases {
        for selected in SettingsTab.allCases {
            let drawer = NotchSettingsDrawer(selectedTab: selected, appearance: appearance,
                context: NotchSettingsDrawerContext(updates: nil), onSelectTab: { _ in })
            let host = NSHostingView(rootView: drawer.frame(width: 420, height: 348).background(appearance == .dark ? Color.black : Color.white)
                .environment(\.controlActiveState, controlState))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 348),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            VLOrderTestWindow(window)
            XCTAssertFalse(window.isKeyWindow)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let bitmap = try Self.fixedScaleBitmap(host)
            let scale = CGFloat(bitmap.pixelsWide) / 420
            for (index, tab) in SettingsTab.allCases.enumerated() {
                // 8 pt horizontal padding, 5 equal tabs separated by 2 pt; icons sit above the text baseline.
                let centre = 8 + (CGFloat(index) + 0.5) * (404 / 5)
                var bright = 0
                for y in Int(8 * scale)..<Int(24 * scale) {
                    for x in Int((centre - 11) * scale)..<Int((centre + 11) * scale) {
                        let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if appearance == .dark ? min(c.redComponent, c.greenComponent, c.blueComponent) > 0.45
                            : max(c.redComponent, c.greenComponent, c.blueComponent) < 0.55 { bright += 1 }
                    }
                }
                XCTAssertGreaterThan(bright, 8, "[N3] \(tab.title) glyph absent with \(selected.title) selected, control state=\(controlState); pixels=\(bright)")
            }
        }
        }
        }
    }
}
