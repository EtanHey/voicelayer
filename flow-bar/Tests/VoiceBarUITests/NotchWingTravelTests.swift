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

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        super.tearDown()
    }

    struct Frame {
        let time: TimeInterval
        let leftEdge: CGFloat?, rightEdge: CGFloat?
        /// The outermost controls' plate edges (their tooltip views), in points.
        let leftInk: CGFloat?, rightInk: CGFloat?
        var leftDistance: CGFloat? { leftInk.flatMap { ink in leftEdge.map { ink - $0 } } }
        var rightDistance: CGFloat? { rightInk.flatMap { ink in rightEdge.map { $0 - ink } } }
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
    /// first frame), releases it after the close, drops it when the band reopens, and never holds under Reduce Motion.
    func testTheCloseToHiddenHoldsTheCanvasUntilItLandsAndNeverUnderReduceMotion() {
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
        XCTAssertFalse(model.presentation.holdsClosingCanvas, "Reduce Motion keeps the instant hide")
        XCTAssertTrue(releases.isEmpty)
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
        guard let first, let last else { return Frame(time: time, leftEdge: nil, rightEdge: nil, leftInk: nil, rightInk: nil) }
        return Frame(time: time, leftEdge: CGFloat(first) / s, rightEdge: CGFloat(last + 1) / s,
                     leftInk: controls.0, rightInk: controls.1)
    }

    static func text(_ value: CGFloat?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
}
