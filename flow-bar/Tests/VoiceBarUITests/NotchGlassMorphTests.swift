import AppKit
import Observation
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Lanes C2 + C4: the native glass must morph with the notch shape, not jump to the destination.
///
/// The glass is an AppKit `NSGlassEffectView` masked by the notch path; the border strokes and the content
/// clip are SwiftUI shapes. When only the SwiftUI side interpolated, tapping the mic or X made the wing that
/// changed most jump while its neighbour eased (C2), and opening History or the teleprompter drew the border
/// growing inside an already-grown glass body (C4). This drives the production `VoiceBarNotchView` through
/// each morph in an offscreen window and samples the glass mask as the animation runs.
@Observable final class NotchGlassMorphPresentationBox {
    var presentation: VoiceBarNotchPresentation
    init(_ presentation: VoiceBarNotchPresentation) {
        self.presentation = presentation
    }
}

@MainActor
final class NotchGlassMorphTests: XCTestCase {
    /// Mirrors BarView: the canvas follows the current presentation.
    struct Harness: View {
        let box: NotchGlassMorphPresentationBox
        var body: some View {
            VoiceBarNotchView(
                presentation: box.presentation,
                canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: box.presentation).canvasGeometry,
                leadingContent: { EmptyView() },
                trailingContent: { EmptyView() },
                lowerContent: { EmptyView() }
            )
        }
    }

    private static func presentation(
        recording: Bool = false, history: Bool = false, teleprompter: Bool = false, compactStatus: Bool = false
    ) -> VoiceBarNotchPresentation {
        VoiceBarNotchPresentation.resolve(
            hasTeleprompter: teleprompter, isRecording: recording, hasCompactStatus: compactStatus,
            hasHistoryPanel: history, isHovered: !compactStatus, isKeyboardFocused: false
        )
    }

    func testMicTapGrowsTheGlassWithTheShape() throws {
        try assertGlassMorphs(from: Self.presentation(), to: Self.presentation(recording: true), "mic → recording")
    }

    func testCancelTapShrinksTheGlassWithTheShape() throws {
        try assertGlassMorphs(from: Self.presentation(recording: true), to: Self.presentation(), "X → launcher")
    }

    func testHistoryPanelGrowsTheGlassWithTheShape() throws {
        try assertGlassMorphs(from: Self.presentation(), to: Self.presentation(history: true), "History open")
    }

    func testTeleprompterGrowsTheGlassWithTheShape() throws {
        try assertGlassMorphs(
            from: Self.presentation(compactStatus: true), to: Self.presentation(teleprompter: true), "teleprompter"
        )
    }

    /// UXP-2 / Lane C follow-up: the outer corners interpolate between the launcher's 15 pt and the panel's
    /// 18 pt. The radius was not animated data, and the body path used its own fixed 18 pt, so the glass
    /// mask's corners jumped 15 → 18 on the first frame and back in one step on close.
    func testTheOuterCornersStayRoundedWhileHistoryOpensAndCloses() throws {
        try assertCornersStayRounded(from: Self.presentation(), to: Self.presentation(history: true), "History open")
        try assertCornersStayRounded(from: Self.presentation(history: true), to: Self.presentation(), "History close")
    }

    private func assertCornersStayRounded(
        from start: VoiceBarNotchPresentation,
        to destination: VoiceBarNotchPresentation,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("The native glass host exists on macOS 26+; older systems draw the shape in SwiftUI")
        }
        let box = NotchGlassMorphPresentationBox(start)
        let host = NSHostingView(rootView: Harness(box: box))
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: Self.presentation(history: true)).canvasGeometry
        host.frame = NSRect(x: 0, y: 0, width: canvas.totalWidth, height: canvas.totalHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = try XCTUnwrap(
            glassMaskOuterCornerRadius(in: host),
            "\(label): no corner before",
            file: file,
            line: line
        )

        box.presentation = destination
        var radii: [CGFloat] = [before]
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
            if let radius = glassMaskOuterCornerRadius(in: host), radius != radii.last { radii.append(radius) }
        }
        XCTAssertGreaterThan(radii.count, 2, "\(label): the corner never eased (\(radii))", file: file, line: line)
        let steps = zip(radii, radii.dropFirst()).map { abs($1 - $0) }
        let largest = steps.max() ?? 0
        XCTAssertLessThanOrEqual(
            largest, 1.5,
            "\(label): the outer corner jumped \(largest) pt in one frame (\(radii.map { ($0 * 10).rounded() / 10 }))",
            file: file, line: line
        )
    }

    /// The smallest radius among the mask's corner curves, the quad curves whose control point is a corner of
    /// the path's bounding box. Orientation-free: AppKit may hand the mask over flipped.
    @available(macOS 26.0, *)
    private func glassMaskOuterCornerRadius(in view: NSView) -> CGFloat? {
        guard let path = glassMaskPath(in: view) else { return nil }
        let box = path.boundingBoxOfPath
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY),
        ]
        var radii: [CGFloat] = []
        path.applyWithBlock { element in
            guard element.pointee.type == .addQuadCurveToPoint else { return }
            let control = element.pointee.points[0]
            let end = element.pointee.points[1]
            guard corners.contains(where: { abs($0.x - control.x) < 0.01 && abs($0.y - control.y) < 0.01 })
            else { return }
            radii.append(max(abs(end.x - control.x), abs(end.y - control.y)))
        }
        return radii.min()
    }

    @available(macOS 26.0, *)
    private func glassMaskPath(in view: NSView) -> CGPath? {
        if view is NSGlassEffectView {
            return (view.layer?.mask as? CAShapeLayer)?.path
        }
        return view.subviews.lazy.compactMap { self.glassMaskPath(in: $0) }.first
    }

    private func assertGlassMorphs(
        from start: VoiceBarNotchPresentation,
        to destination: VoiceBarNotchPresentation,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("The native glass host exists on macOS 26+; older systems draw the shape in SwiftUI")
        }
        let box = NotchGlassMorphPresentationBox(start)
        let host = NSHostingView(rootView: Harness(box: box))
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: Self.presentation(history: true)).canvasGeometry
        host.frame = NSRect(x: 0, y: 0, width: canvas.totalWidth, height: canvas.totalHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = try XCTUnwrap(glassMaskBounds(in: host), "\(label): no native glass mask", file: file, line: line)

        box.presentation = destination
        var samples: [CGRect] = []
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
            Thread.sleep(forTimeInterval: 0.9) // RED: a slow rendered-frame read skips the morph
            if let bounds = glassMaskBounds(in: host), bounds != samples.last ?? before { samples.append(bounds) }
        }
        let after = try XCTUnwrap(samples.last, "\(label): the glass never changed", file: file, line: line)

        // Every edge that travels must pass through in-between frames: its first move may not already be
        // (nearly) the whole distance, which is what a mask that snaps to the destination does.
        let first = samples[0]
        for (edge, from, firstValue, to) in [
            ("leading", before.minX, first.minX, after.minX),
            ("trailing", before.maxX, first.maxX, after.maxX),
            ("bottom", before.height, first.height, after.height),
        ] where abs(to - from) >= 4 {
            let progress = (firstValue - from) / (to - from)
            XCTAssertLessThan(
                progress, 0.9,
                "\(label): the glass \(edge) edge jumped \(Int(progress * 100))% of its \(abs(to - from)) pt travel "
                    +
                    "on its first frame (\(from) → \(firstValue), destination \(to)); \(samples.count) distinct frames",
                file: file, line: line
            )
            XCTAssertGreaterThanOrEqual(samples.count, 3, "\(label): \(edge) moved in too few frames",
                                        file: file, line: line)
        }
    }

    @available(macOS 26.0, *)
    private func glassMaskBounds(in view: NSView) -> CGRect? {
        if view is NSGlassEffectView {
            return (view.layer?.mask as? CAShapeLayer)?.path?.boundingBoxOfPath
        }
        return view.subviews.lazy.compactMap { self.glassMaskBounds(in: $0) }.first
    }
}
