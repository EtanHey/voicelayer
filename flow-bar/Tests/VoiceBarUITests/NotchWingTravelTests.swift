import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Owner r2 (2.4.3, N11b), icons travel with the wing. Opening the band from hidden, each icon keeps its settled
/// distance from its wing's OUTER end while the wing grows, so the outer icons ride out with the glass and the inner
/// ones come out from under the notch; closing is the same motion inward. Before, the icons sat at their settled
/// places from the first frame and the growing glass uncovered them (his recording: the microphone cut in half, the
/// chevron sitting where the wing ended), and the close dropped the glass and the icons in one frame.
///
/// The production BarView (with the resident presentation model) is sampled in real time at a fixed 4x while it
/// opens and closes. Each sample reads both outer edges of the band from the bitmap (the first and last pixel that is
/// not the backdrop: the shell's outline, which this Mac's offscreen capture paints even where it leaves the native
/// glass and its content blank) and, at the same instant, the outermost controls' slots from their own views (the
/// microphone's left edge, the gear's right edge). Each distance is read off one sample, so timing cannot fake it.
@MainActor
final class NotchWingTravelTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    static let scale: CGFloat = 4
    static let size = CGSize(width: 540, height: 300)
    /// The backdrop: a colour no notch pixel has.
    static let backdrop = (r: 1.0, g: 0.0, b: 1.0)
    private var windows: [NSWindow] = []
    private var restoreReduceMotion: (() -> Void)?

    override func setUp() {
        super.setUp()
        // The travel and the retained close are the full-motion path; under Reduce Motion the band only fades, in
        // place (owner card 8). GitHub's hosted macOS runner has Reduce Motion ON (#860,
        // `ReduceMotionOverride`), and these tests failed there with exactly the Reduce Motion frames (CI r3,
        // run 43970804395), so each test pins the setting it proves instead of inheriting the machine's.
        restoreReduceMotion = ReduceMotionOverride.pin(false)
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        restoreReduceMotion?()
        restoreReduceMotion = nil
        super.tearDown()
    }

    struct Frame {
        let time: TimeInterval
        let leftEdge: CGFloat?, rightEdge: CGFloat?
        /// The outermost controls' plate edges (their tooltip views), in points.
        let leftInk: CGFloat?, rightInk: CGFloat?
        var leftDistance: CGFloat? { leftInk.flatMap { ink in leftEdge.map { ink - $0 } } }
        var rightDistance: CGFloat? { rightInk.flatMap { ink in rightEdge.map { $0 - ink } } }
        /// The strongest green the band adds to the magenta backdrop on the edge row outside the core: the band's
        /// opacity times its outline's (the core is black and adds none, so it never counts).
        var lift: CGFloat = 0
    }

    func testIconsKeepTheirDistanceFromTheOuterEndWhileTheBandOpensAndCloses() throws {
        let rig = try mount()
        // Settled open: the reference distances.
        rig.hover(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let settled = try measure(rig.host, time: 0)
        if let path = ProcessInfo.processInfo.environment["NOTCH_OWNER_R2_FRAMES"] {
            try EtanQA0510Tests.fixedScaleBitmap(rig.host, scale: 2).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("travel-settled.png"))
        }
        let openLeft = try XCTUnwrap(settled.leftEdge, "the open band paints")
        let openRight = try XCTUnwrap(settled.rightEdge)
        let left = try XCTUnwrap(settled.leftDistance, "the microphone paints in the open band")
        let right = try XCTUnwrap(settled.rightDistance, "the gear paints in the open band")
        rig.hover(false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertNil(try measure(rig.host, time: 0).leftEdge, "fixture: the band is hidden again")

        var report: [String] = [String(format: "settled: left wing edge %.2f, mic %.2f pt in; gear %.2f pt in",
                                       openLeft, left, right)]
        for (phase, hovering) in [("open", true), ("close", false)] {
            rig.hover(hovering)
            let frames = try sample(rig.host)
            // Frames where both wings are drawn part-way: the core is 185 pt, so a wing is part-way open while its
            // edge is more than 4 pt inside the open edge and more than 4 pt outside the core.
            let coreMinX = Self.size.width / 2 - VoiceBarNotchContract.coreWidth / 2
            let coreMaxX = Self.size.width / 2 + VoiceBarNotchContract.coreWidth / 2
            let partway = frames.filter { frame in
                guard let l = frame.leftEdge, let r = frame.rightEdge else { return false }
                return l > openLeft + 4 && l < coreMinX - 4 && r < openRight - 4 && r > coreMaxX + 4
            }
            for frame in frames {
                report.append(String(format: "%@ %3.0f ms: edges %@ / %@, mic %@ pt in, gear %@ pt in", phase,
                                     frame.time * 1000, Self.text(frame.leftEdge), Self.text(frame.rightEdge),
                                     Self.text(frame.leftDistance), Self.text(frame.rightDistance)))
            }
            XCTAssertGreaterThanOrEqual(partway.count, 2,
                                        "\(phase): the wings are drawn part-way in \(partway.count) frames, not cut")
            for frame in partway {
                let at = String(format: "%@ at %.0f ms", phase, frame.time * 1000)
                let l = try XCTUnwrap(frame.leftDistance, "\(at): the microphone rides inside the left wing")
                let r = try XCTUnwrap(frame.rightDistance, "\(at): the gear rides inside the right wing")
                XCTAssertEqual(l, left, accuracy: 0.5, "\(at): the microphone keeps its distance from the outer end")
                XCTAssertEqual(r, right, accuracy: 0.5, "\(at): the gear keeps its distance from the outer end")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        }
        print("WING_TRAVEL\n" + report.joined(separator: "\n"))
    }

    /// Owner card 8 (2026-11-17, `fade-only`). Reduce Motion ON, as on GitHub's hosted runner (CI r3): the band opens
    /// and closes with a plain fade and no movement. Before, the glass eased open over 180 ms around still icons (the
    /// growing glass uncovered them) and the close was an instant cut.
    ///
    /// On every sampled frame of the open and the close, each outer edge reads either at its settled place or (the
    /// wing too faint for the edge reader, so the black core is the outermost paint) at the core's own edge, never in
    /// between; the icons sit at their settled places; and the band's paint (`lift`, the strongest green the outline
    /// adds over the magenta backdrop outside the core) rises through part-way values on the open and falls through
    /// them on the close, never reversing.
    func testUnderReduceMotionTheBandFadesInAndOutWithoutMoving() throws {
        restoreReduceMotion?()
        restoreReduceMotion = ReduceMotionOverride.pin(true)
        let rig = try mount()
        rig.hover(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let settled = try measure(rig.host, time: 0)
        let openLeft = try XCTUnwrap(settled.leftEdge, "the open band paints")
        let openRight = try XCTUnwrap(settled.rightEdge)
        let settledMic = try XCTUnwrap(settled.leftInk, "the microphone is laid out in the open band")
        let settledGear = try XCTUnwrap(settled.rightInk, "the gear is laid out in the open band")
        let settledLift = settled.lift
        XCTAssertGreaterThan(settledLift, 0.05, "fixture: the open band's outline lifts the backdrop")
        rig.hover(false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertNil(try measure(rig.host, time: 0).leftEdge, "fixture: the band is hidden again")

        let coreMinX = Self.size.width / 2 - VoiceBarNotchContract.coreWidth / 2
        let coreMaxX = Self.size.width / 2 + VoiceBarNotchContract.coreWidth / 2
        var report = [String(format: "settled: edges %.2f / %.2f, lift %.3f", openLeft, openRight, settledLift)]
        for (phase, hovering) in [("open", true), ("close", false)] {
            rig.hover(hovering)
            let frames = try sample(rig.host)
            for frame in frames {
                report.append(String(format: "%@ %3.0f ms: edges %@ / %@, mic %@, gear %@, lift %.3f", phase,
                                     frame.time * 1000, Self.text(frame.leftEdge), Self.text(frame.rightEdge),
                                     Self.text(frame.leftInk), Self.text(frame.rightInk), frame.lift))
                let at = String(format: "%@ at %.0f ms", phase, frame.time * 1000)
                if let left = frame.leftEdge {
                    XCTAssertTrue(abs(left - openLeft) <= 0.5 || abs(left - coreMinX) <= 0.5,
                                  "\(at): the left edge reads \(left), between the settled \(openLeft) and the core")
                }
                if let right = frame.rightEdge {
                    XCTAssertTrue(abs(right - openRight) <= 0.5 || abs(right - coreMaxX) <= 0.5,
                                  "\(at): the right edge reads \(right), between the settled \(openRight) and the core")
                }
                if let mic = frame.leftInk {
                    XCTAssertEqual(mic, settledMic, accuracy: 0.5, "\(at): the microphone holds still")
                }
                if let gear = frame.rightInk {
                    XCTAssertEqual(gear, settledGear, accuracy: 0.5, "\(at): the gear holds still")
                }
            }
            let lifts = frames.map(\.lift)
            let partway = lifts.filter { $0 > settledLift * 0.05 && $0 < settledLift * 0.95 }
            XCTAssertGreaterThanOrEqual(partway.count, 2, "\(phase): the band fades through part-way frames, not a cut")
            for (earlier, later) in zip(lifts, lifts.dropFirst()) {
                if hovering {
                    XCTAssertGreaterThanOrEqual(later, earlier - 0.01, "open: the fade never dims")
                } else {
                    XCTAssertLessThanOrEqual(later, earlier + 0.01, "close: the fade never brightens")
                }
            }
            XCTAssertEqual(lifts.last ?? -1, hovering ? settledLift : 0, accuracy: 0.01,
                           "\(phase): the fade lands \(hovering ? "fully open" : "hidden")")
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        }
        print("REDUCE_MOTION_FADE\n" + report.joined(separator: "\n"))
    }

    /// Review r1 (blocking 1): while a closed band rides under the notch its controls are pictures, not controls. From
    /// the close's first frame until the band is removed, none of the launcher's controls can take keyboard focus:
    /// SwiftUI registers one key-view proxy per focusable control in the glass's own host (four in the open launcher),
    /// and the retained band registers none. VoiceOver: this Mac's offscreen hosts never build SwiftUI's accessibility
    /// tree without an assistive client (`docs.local/2.4.3/owner-r2/r1-axprobe.log`), so the retained branch's
    /// accessibility hiding is pinned in source below alongside the measured focus check.
    func testTheClosingBandIsInertForAccessibilityAndFocus() throws {
        let rig = try mount()
        rig.hover(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let open = try measure(rig.host, time: 0)
        let openLeft = try XCTUnwrap(open.leftEdge, "the open band paints")
        XCTAssertEqual(Self.focusableControls(rig.host), 4, "fixture: the open launcher's four controls take focus")
        rig.hover(false)
        var checked = 0
        let start = Date()
        while Date().timeIntervalSince(start) < 0.5 {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
            let frame = try measure(rig.host, time: 0)
            // Only frames where the band is still drawn part-way (the retained close) count.
            guard let left = frame.leftEdge, left > openLeft + 1 else { continue }
            checked += 1
            let at = String(format: "%.0f ms into the close", Date().timeIntervalSince(start) * 1000)
            XCTAssertEqual(Self.focusableControls(rig.host), 0, "\(at): a retained control can take keyboard focus")
        }
        XCTAssertGreaterThanOrEqual(checked, 2, "fixture: the close was sampled while the band was still drawn")

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/VoiceBarNotchView.swift"), encoding: .utf8)
        let retained = try XCTUnwrap(source.components(separatedBy: "if let band = closing.band {").dropFirst().first)
            .components(separatedBy: "} else {")[0]
        for guardText in [".modifier(VoiceBarNotchInertContent())"] {
            XCTAssertTrue(retained.contains(guardText), "the retained band's slots carry \(guardText)")
        }
        let inert = try XCTUnwrap(source.components(separatedBy: "struct VoiceBarNotchInertContent").dropFirst().first)
        for modifier in [".disabled(true)", ".accessibilityHidden(true)", ".allowsHitTesting(false)"] {
            XCTAssertTrue(inert.prefix(900).contains(modifier), "VoiceBarNotchInertContent applies \(modifier)")
        }
    }

    /// SwiftUI's key-view proxies: one per control that can take keyboard focus in a hosting view.
    static func focusableControls(_ root: NSView) -> Int {
        // SwiftUI (re)builds its proxies when AppKit asks for the key-view loop.
        root.window?.recalculateKeyViewLoop()
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        return all(root).filter { String(describing: type(of: $0)).contains("KeyViewProxy") }.count
    }

    /// Review r1 (blocking 2): a close's completion ends only its own close. Close A, reopen, close B, then A's late
    /// completion: B's band stays until B's own completion.
    func testALateCompletionNeverEndsALaterClose() {
        let tracker = VoiceBarNotchClosingTracker()
        let launcher = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let a = tracker.begin(geometry: launcher, bandState: .hoverLauncher, trailingLayoutState: nil)
        tracker.cancel()
        let b = tracker.begin(geometry: launcher, bandState: .hoverLauncher, trailingLayoutState: nil)
        XCTAssertNotEqual(a, b, "each close has its own generation")
        tracker.complete(a)
        XCTAssertNotNil(tracker.band, "close A's late completion leaves close B's band in place")
        tracker.complete(b)
        XCTAssertNil(tracker.band, "close B's own completion ends it")
        // A close continued while still closing (a second change to idle) keeps its band and the newest generation.
        let c = tracker.begin(geometry: launcher, bandState: .hoverLauncher, trailingLayoutState: nil)
        let d = tracker.begin(geometry: VoiceBarNotchContract.geometry(for: .recording), bandState: .recording,
                              trailingLayoutState: nil)
        XCTAssertEqual(tracker.band?.geometry, launcher)
        tracker.complete(c)
        XCTAssertNotNil(tracker.band, "the superseded animation's completion does not end the continued close")
        tracker.complete(d)
        XCTAssertNil(tracker.band)
    }

    /// Review r2 (blocking): close A begins, then a further geometry change while still idle starts a replacement
    /// animation. A's late completion must not remove the band mid-replacement; only the replacement's own completion
    /// may. The view takes every replacement's token from `claim()`.
    func testAReplacementWhileClosingOwnsTheRetainedBand() {
        let tracker = VoiceBarNotchClosingTracker()
        let launcher = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        XCTAssertNil(tracker.claim(), "no retained band, nothing to claim")
        let a = tracker.begin(geometry: launcher, bandState: .hoverLauncher, trailingLayoutState: nil)
        let replacement = tracker.claim()
        XCTAssertNotNil(replacement)
        XCTAssertNotEqual(replacement, a, "the replacement carries its own token")
        tracker.complete(a)
        XCTAssertNotNil(tracker.band, "A's late completion leaves the band to the replacement")
        XCTAssertEqual(tracker.band?.geometry, launcher, "the replacement keeps the band it took over")
        let second = tracker.claim()
        tracker.complete(replacement!)
        XCTAssertNotNil(tracker.band, "a superseded replacement's completion does not end it either")
        tracker.complete(second!)
        XCTAssertNil(tracker.band, "the newest owner's completion ends it")
    }

    /// The slot offset is the gap between the drawn outer edge and the settled one, on each side; no live wings (any
    /// shell but the state shell) means no travel.
    func testTheSlotOffsetFollowsTheDrawnOuterEdge() {
        let live = VoiceBarNotchLiveWings(leading: 20, trailing: 100)
        XCTAssertEqual(VoiceBarNotchWingTravel.offset(side: .leading, settledWidth: 70, live: live), 50,
                       "a narrower drawn left wing carries its row toward the notch")
        XCTAssertEqual(VoiceBarNotchWingTravel.offset(side: .trailing, settledWidth: 73.5, live: live), 26.5,
                       "a wider drawn right wing carries its row outward")
        XCTAssertEqual(VoiceBarNotchWingTravel.offset(side: .leading, settledWidth: 70, live: nil), 0)
        let shape = VoiceBarNotchContinuousShape(geometry: VoiceBarNotchContract.geometry(for: .hoverLauncher))
        XCTAssertEqual(shape.liveWings, VoiceBarNotchLiveWings(leading: 70, trailing: 73.5))
    }

    /// Closing to hidden keeps the visible canvas while the glass closes (the window used to shrink to the core in the
    /// first frame), releases it after the close and drops it when the band reopens. Under Reduce Motion it holds the
    /// same way, so the band fades out where it sits (owner card 8) instead of being cut by the window.
    func testTheCloseToHiddenHoldsTheCanvasUntilItLandsUnderEitherMotionSetting() {
        let model = VoiceBarNotchPresentationModel()
        var releases: [(TimeInterval, () -> Void)] = []
        model.scheduleClosingCanvasRelease = { releases.append(($0, $1)) }
        model.setHovered(true)
        let open = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
        model.setHovered(false)
        XCTAssertEqual(model.presentation.visualState, .idle)
        XCTAssertTrue(model.presentation.holdsClosingCanvas)
        XCTAssertEqual(VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry, open,
                       "the window keeps the open canvas while the glass closes")
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.0, VoiceBarNotchPresentationModel.closingCanvasReleaseDelay)
        releases.removeFirst().1()
        XCTAssertFalse(model.presentation.holdsClosingCanvas)
        XCTAssertEqual(VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry,
                       model.presentation.geometry, "then the window shrinks to the core")

        model.setHovered(true)
        model.setHovered(false)
        model.setHovered(true)
        XCTAssertFalse(model.presentation.holdsClosingCanvas, "reopening drops the hold")
        releases.forEach { $0.1() }
        XCTAssertEqual(model.presentation.visualState, .hoverLauncher, "a stale release changes nothing")
        releases.removeAll()

        model.setReducedMotion(true)
        model.setHovered(false)
        XCTAssertTrue(model.presentation.holdsClosingCanvas, "Reduce Motion holds the canvas while the band fades out")
        XCTAssertEqual(VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry, open,
                       "the fade keeps the open canvas")
        XCTAssertEqual(releases.count, 1)
        XCTAssertGreaterThan(VoiceBarNotchPresentationModel.closingCanvasReleaseDelay,
                             VoiceBarNotchReduceMotionFade.closeDuration, "the hold outlasts the fade")
        releases.removeFirst().1()
        XCTAssertFalse(model.presentation.holdsClosingCanvas)
    }

    /// Opt-in frame sequences for the report: `NOTCH_OWNER_R2_FRAMES=<directory>` writes, for the open and the close,
    /// each sample's 2x bitmap (`<phase>-<nn>.png`), the band controls' frames at that instant (`<phase>.json`), and
    /// one 2x sprite per control glyph (`glyph-<symbol>.png`). This Mac's offscreen capture leaves the native glass
    /// and its content blank, so `docs.local/2.4.3/owner-r2/compose.py` draws each frame as a composite: the real
    /// outline and core from the bitmap, the glass filled between the measured edges, and the production glyphs at
    /// the frames the real views reported.
    func testWriteOpenCloseFramesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTCH_OWNER_R2_FRAMES"], !path.isEmpty else {
            throw XCTSkip("Set NOTCH_OWNER_R2_FRAMES to write the open and close frames")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for icon in Self.launcherGlyphs.values {
            let button = VoiceBarPillControlButton(icon: icon, optics: .resolve(for: icon), foreground: .white,
                                                   isSelected: false, isDestructive: false, accessibilityLabel: icon,
                                                   accessibilityHint: "", action: {})
            let bitmap = try NotchDesignPixels.render(button.frame(width: 20, height: 20).background(.black),
                                                     size: CGSize(width: 20, height: 20))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("glyph-\(icon).png"))
        }
        let rig = try mount()
        for (phase, hovering) in [("open", true), ("close", false)] {
            rig.hover(hovering)
            let start = Date()
            var index = 0
            var rows: [[String: Any]] = []
            while Date().timeIntervalSince(start) < 0.5 {
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
                let controls = bandControls(rig.host)
                let bitmap = try EtanQA0510Tests.fixedScaleBitmap(rig.host, scale: 2)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(String(format: "%@-%02d.png", phase, index)))
                rows.append(["frame": index, "ms": Int(Date().timeIntervalSince(start) * 1000),
                             "controls": controls.map { ["icon": Self.launcherGlyphs[$0.0] ?? "gearshape",
                                                         "x": $0.1.minX, "y": rig.host.bounds.height - $0.1.maxY,
                                                         "w": $0.1.width, "h": $0.1.height] }])
                index += 1
            }
            let json = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: directory.appendingPathComponent("\(phase).json"))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        }
    }

    /// The launcher's band controls by tooltip; anything else in the band is the gear (its tooltip carries setup state).
    static let launcherGlyphs = ["Start dictation (F5)": "mic.fill", "Choose microphone": "chevron.down",
                                 "History": "clock.arrow.circlepath", "Settings": "gearshape"]

    private func bandControls(_ host: NSView) -> [(String, CGRect)] {
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        let bandMinY = host.bounds.height - VoiceBarNotchContract.topHeight - 4
        return all(host).compactMap { view in
            guard let tooltip = view.toolTip, !view.isHiddenOrHasHiddenAncestor else { return nil }
            let frame = view.convert(view.bounds, to: nil)
            return frame.midY > bandMinY && frame.width > 0 ? (tooltip, frame) : nil
        }
    }

    // MARK: - Rig

    struct Rig {
        let state: VoiceState; let model: VoiceBarNotchPresentationModel; let host: NSView
        /// As the resident app does: the pointer's hover reaches the state and the presentation model.
        func hover(_ hovering: Bool) {
            state.isHovering = hovering
            model.setHovered(hovering)
        }
    }

    private final class ReferenceWindow: NSWindow {
        override var backingScaleFactor: CGFloat { NotchWingTravelTests.scale }
    }

    private func mount() throws -> Rig {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               keepsExpandedInDevState: false)
        state.sendCommand = { _ in }
        state.isConnected = true
        state.isCollapsed = false
        let model = VoiceBarNotchPresentationModel()
        let old = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let bar = BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                          presentationModel: model, includesPanelOutsets: true)
        NSApplication.shared.appearance = old
        let host = NSHostingView(rootView: AnyView(ZStack(alignment: .top) {
            Color(red: Self.backdrop.r, green: Self.backdrop.g, blue: Self.backdrop.b)
            bar
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .environment(\.colorScheme, .dark)))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = ReferenceWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        windows.append(window)
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return Rig(state: state, model: model, host: host)
    }

    /// Captures first (cheap), measures afterwards, so measuring never slows the sampling down.
    private func sample(_ host: NSView) throws -> [Frame] {
        let start = Date()
        var captured: [(TimeInterval, NSBitmapImageRep, (CGFloat?, CGFloat?))] = []
        while Date().timeIntervalSince(start) < 0.55 {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120.0))
            let controls = outermostControls(host)
            captured.append((Date().timeIntervalSince(start), try EtanQA0510Tests.fixedScaleBitmap(host, scale: Self.scale),
                             controls))
        }
        return captured.map { measure($0.1, controls: $0.2, time: $0.0) }
    }

    // MARK: - Pixels

    /// One frame: the band's outer edges along a row 10 pt below the top (clear of the wings' rounded lower corners)
    /// and the outermost icon ink in each wing, in points.
    private func measure(_ host: NSView, time: TimeInterval) throws -> Frame {
        measure(try EtanQA0510Tests.fixedScaleBitmap(host, scale: Self.scale), controls: outermostControls(host), time: time)
    }

    /// The left edge of the leftmost control and the right edge of the rightmost one in the band row (window points;
    /// the host sits at the window's origin, so x matches the bitmap's points).
    private func outermostControls(_ host: NSView) -> (CGFloat?, CGFloat?) {
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        let bandMinY = host.bounds.height - VoiceBarNotchContract.topHeight - 4
        let frames = all(host).compactMap { view -> CGRect? in
            guard view.toolTip != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
            let frame = view.convert(view.bounds, to: nil)
            return frame.midY > bandMinY && frame.width > 0 ? frame : nil
        }
        return (frames.map(\.minX).min(), frames.map(\.maxX).max())
    }

    private func measure(_ bitmap: NSBitmapImageRep, controls: (CGFloat?, CGFloat?), time: TimeInterval) -> Frame {
        let s = Self.scale
        // Raw bytes: the bitmap is 8-bit RGBA, device RGB (`fixedScaleBitmap`).
        let data = bitmap.bitmapData!, rowBytes = bitmap.bytesPerRow, step = bitmap.bitsPerPixel / 8
        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
            let p = data + y * rowBytes + x * step
            let a = max(1, CGFloat(p[3])) / 255
            // Unpremultiply (cacheDisplay writes premultiplied alpha); a transparent pixel reads as black.
            return p[3] == 0 ? (0, 0, 0) : (CGFloat(p[0]) / 255 / a, CGFloat(p[1]) / 255 / a, CGFloat(p[2]) / 255 / a)
        }
        // The backdrop is pure magenta; the outline (white 14 %) and anything else the band paints lifts green.
        func isBackdrop(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgb(x, y)
            return r > 0.9 && b > 0.9 && g < 0.05
        }
        let width = bitmap.pixelsWide
        let edgeRow = Int(10 * s)
        let first = (0 ..< width).first { !isBackdrop($0, edgeRow) }
        let last = (0 ..< width).last { !isBackdrop($0, edgeRow) }
        let coreMin = Int(((Self.size.width - VoiceBarNotchContract.coreWidth) / 2 * s).rounded(.down))
        let coreMax = Int(((Self.size.width + VoiceBarNotchContract.coreWidth) / 2 * s).rounded(.up))
        let lift = (0 ..< width).filter { $0 < coreMin || $0 >= coreMax }.map { rgb($0, edgeRow).1 }.max() ?? 0
        guard let first, let last else {
            return Frame(time: time, leftEdge: nil, rightEdge: nil, leftInk: nil, rightInk: nil, lift: lift)
        }
        return Frame(time: time, leftEdge: CGFloat(first) / s, rightEdge: CGFloat(last + 1) / s,
                     leftInk: controls.0, rightInk: controls.1, lift: lift)
    }

    static func text(_ value: CGFloat?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
}
