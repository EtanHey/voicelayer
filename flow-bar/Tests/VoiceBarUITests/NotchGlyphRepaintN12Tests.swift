import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// N12 (Etan, several times: "the icons only show when I click on their tab", "until I click the panel itself it
/// doesnt show the logos"). The mechanism, found on the M4 (macOS 27) and reproduced here:
///
/// 1. After every panel layout change the app re-rasterizes the notch panel
///    (`AppDelegate.schedulePanelBackingScaleRecertification`, reason `layout_changed`), which runs
///    `VoiceBarBackingScaleSynchronizer.synchronize` over every layer under the panel.
/// 2. That pass called `setNeedsDisplay()` on each of them. A layer that draws itself (text) draws again. A layer
///    whose contents were handed to it (SwiftUI's symbol `ImageLayer`, a `CGImage`) has nothing to draw with, so
///    its contents come back empty and the glyph is gone until SwiftUI next rewrites that one layer, which is
///    what selecting a tab does.
/// 3. macOS 27 draws every SF Symbol as such an image layer; macOS 26 only the bitmap ones (multicolor symbols),
///    which is why the tab glyphs never vanished on a macOS 26 host or in an offscreen "glyph exists" test.
@MainActor
final class NotchGlyphRepaintN12Tests: XCTestCase {
    /// The mechanism on its own, the same on every macOS: contents a layer was handed survive the pass, whether
    /// an image (what SwiftUI hands a symbol layer) or a surface.
    func testRerasterizingKeepsContentsALayerWasHanded() throws {
        let surface = try XCTUnwrap(IOSurface(properties: [
            .width: 28, .height: 28, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]))
        let handedContents: [(String, AnyObject)] = [("image", try n12SolidImage(side: 28)), ("surface", surface)]
        for (kind, contents) in handedContents {
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            view.wantsLayer = true
            let handed = CALayer()
            handed.frame = CGRect(x: 4, y: 4, width: 14, height: 14)
            handed.contents = contents
            try XCTUnwrap(view.layer).addSublayer(handed)
            let window = Self.window(holding: view)
            defer { window.contentView = nil; window.close() }

            VoiceBarBackingScaleSynchronizer.synchronize(view, to: 2)
            Self.commit()

            XCTAssertEqual(handed.contentsScale, 2, "the pass still carries the screen's scale to every layer")
            let kept = try XCTUnwrap(handed.contents, "[N12] the pass emptied a layer holding a handed \(kind)")
            XCTAssertTrue(kept as AnyObject === contents,
                          "[N12] the pass replaced a handed \(kind) with an empty backing store: \(kept)")
        }
    }

    /// R886: redraw ownership, not what the contents are. A layer that renders itself is re-rendered at the new
    /// scale by the pass, even when it already holds an image; a handed image beside it is left alone.
    func testAScaleChangeRerendersLayersThatOwnTheirDrawingAndKeepsHandedContents() throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        view.wantsLayer = true
        let root = try XCTUnwrap(view.layer)
        let imageDelegate = N12ImageRenderingDelegate(), drawingDelegate = N12DrawingDelegate()
        let delegateImage = CALayer(), delegateDrawn = CALayer(), selfRendered = N12SelfRenderingLayer()
        let handed = CALayer()
        delegateImage.delegate = imageDelegate
        delegateDrawn.delegate = drawingDelegate
        let handedImage = try n12SolidImage(side: 14)
        handed.contents = handedImage
        for (index, layer) in [delegateImage, delegateDrawn, selfRendered, handed].enumerated() {
            layer.frame = CGRect(x: 4 + index * 18, y: 4, width: 14, height: 14)
            layer.contentsScale = 1
            root.addSublayer(layer)
            if layer !== handed { layer.setNeedsDisplay() }
        }
        let window = Self.window(holding: view)
        defer { window.contentView = nil; window.close() }
        Self.commit()
        func imageWidth(_ layer: CALayer) throws -> Int {
            let contents = try XCTUnwrap(layer.contents)
            XCTAssertEqual(CFGetTypeID(contents as CFTypeRef), CGImage.typeID, "fixture: the renderer made an image")
            return (contents as! CGImage).width
        }
        XCTAssertEqual(try imageWidth(delegateImage), 14, "fixture: painted at 1x before the move")
        XCTAssertEqual(try imageWidth(selfRendered), 14, "fixture: painted at 1x before the move")
        XCTAssertEqual(drawingDelegate.drawnScales, [1], "fixture: drawn once at 1x before the move")

        // The panel lands on a 2x screen.
        VoiceBarBackingScaleSynchronizer.synchronize(view, to: 2)
        Self.commit()

        XCTAssertEqual(try imageWidth(delegateImage), 28,
                       "[R886] a display delegate's image must be rendered again at 2x, not kept at 1x")
        XCTAssertEqual(try imageWidth(selfRendered), 28,
                       "[R886] a layer overriding display() must be rendered again at 2x, not kept at 1x")
        XCTAssertEqual(drawingDelegate.drawnScales, [1, 2], "[R886] a draw delegate must draw again at 2x")
        XCTAssertTrue(try XCTUnwrap(handed.contents) as AnyObject === handedImage,
                      "[N12] contents the layer was handed must survive the same pass")
        XCTAssertEqual(handed.contentsScale, 2, "the pass still carries the screen's scale to every layer")
    }

    /// The live panel's shape (measured in the running QA app on macOS 27): SwiftUI's `ImageLayer` is the backing
    /// layer of an `_NSGraphicsView`, which draws nothing and declares `layerContentsRedrawPolicy == .never`.
    /// Every NSView answers `draw(_:in:)`, so asking the delegate alone would empty that layer again; the view's
    /// own policy decides. A view that draws keeps being redrawn.
    func testAViewBackedLayerFollowsItsViewsRedrawPolicy() throws {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        container.wantsLayer = true
        let handedView = N12HandedContentsView(frame: CGRect(x: 4, y: 4, width: 14, height: 14))
        handedView.wantsLayer = true
        handedView.layerContentsRedrawPolicy = .never
        let image = try n12SolidImage(side: 28)
        let handedLayer = try XCTUnwrap(handedView.layer)
        handedLayer.contents = image
        let drawingView = N12DrawingView(frame: CGRect(x: 24, y: 4, width: 14, height: 14))
        drawingView.wantsLayer = true
        container.addSubview(handedView)
        container.addSubview(drawingView)
        let window = Self.window(holding: container)
        defer { window.contentView = nil; window.close() }
        container.displayIfNeeded()
        Self.commit()
        XCTAssertTrue(handedLayer.delegate === handedView, "fixture: the view is its layer's delegate, as in the panel")
        XCTAssertTrue(handedView.responds(to: #selector(CALayerDelegate.draw(_:in:))),
                      "fixture: every NSView answers draw(_:in:), so the delegate test alone cannot tell")
        let drawsBefore = drawingView.draws
        XCTAssertGreaterThan(drawsBefore, 0, "fixture: the drawing view painted once")

        VoiceBarBackingScaleSynchronizer.synchronize(container, to: 2)
        Self.commit()

        XCTAssertTrue(try XCTUnwrap(handedLayer.contents, "[N12] the pass emptied a never-redraw view's layer")
            as AnyObject === image, "[N12] a never-redraw view's handed contents must survive the pass")
        XCTAssertGreaterThan(drawingView.draws, drawsBefore, "[R886] a view that draws must be drawn again by the pass")
    }

    /// SwiftUI's own image layers, in the real drawer. The warning triangle is a bitmap symbol on every macOS (the
    /// General pane's "Needs attention" glyph, natively wiped on the M1 too); on macOS 27 the five tab glyphs are
    /// image layers as well.
    func testNoDrawerImageLayerIsEmptiedByThePanelsPostLayoutPass() throws {
        let (host, window) = Self.hostedDrawer(selected: .general, appearance: .dark)
        defer { window.contentView = nil; window.close() }

        let before = Self.imageLayers(in: host.layer)
        XCTAssertGreaterThanOrEqual(before.count, 1, "fixture: SwiftUI drew at least the bitmap symbol as an image layer")

        // What the app does two main-queue turns after `applyPanelLayout`.
        VoiceBarBackingScaleSynchronizer.synchronize(host, to: 2)
        Self.commit()

        let emptied = before.filter { !Self.holdsImage($0) }
        XCTAssertTrue(emptied.isEmpty, "[N12] \(emptied.count) of \(before.count) SwiftUI image layers lost their "
            + "glyph to the post-layout pass: " + emptied.map { "\($0.frame)" }.joined(separator: " "))
    }

    /// What Etan sees: every tab glyph painted after the pass, whichever tab is selected, in both appearances. Red
    /// before the fix on macOS 27 (the M4), where the tab glyphs are image layers; macOS 26 draws them as vectors.
    func testEveryTabGlyphIsStillPaintedAfterThePanelsPostLayoutPass() throws {
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            for selected in SettingsTab.allCases {
                let (host, window) = Self.hostedDrawer(selected: selected, appearance: appearance)
                defer { window.contentView = nil; window.close() }
                XCTAssertFalse(window.isKeyWindow, "fixture: the notch panel is not key either")

                VoiceBarBackingScaleSynchronizer.synchronize(host, to: 2)
                Self.commit()

                let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
                let scale = CGFloat(bitmap.pixelsWide) / Self.size.width
                for (index, tab) in SettingsTab.allCases.enumerated() {
                    // 8 pt side inset, five equal tabs 2 pt apart; the glyph sits above the label.
                    let centre = 8 + (CGFloat(index) + 0.5) * ((Self.size.width - 16) / 5)
                    var inked = 0
                    for y in Int(8 * scale) ..< Int(24 * scale) {
                        for x in Int((centre - 11) * scale) ..< Int((centre + 11) * scale) {
                            let colour = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                            if appearance == .dark ? channels.min()! > 0.45 : channels.max()! < 0.55 { inked += 1 }
                        }
                    }
                    XCTAssertGreaterThan(inked, 8, "[N12] the \(tab.title) glyph is gone after the post-layout pass "
                        + "(\(selected.title) selected, \(appearance)); inked pixels=\(inked)")
                }
            }
        }
    }

    // MARK: Fixture

    private static let size = CGSize(width: 420, height: 160)

    private static func hostedDrawer(selected: SettingsTab, appearance: VoiceBarNotchAppearance)
        -> (NSView, NSWindow) {
        let drawer = VStack(spacing: 0) {
            NotchSettingsDrawer(selectedTab: selected, appearance: appearance,
                                context: NotchSettingsDrawerContext(updates: nil), onSelectTab: { _ in })
                .frame(width: size.width, height: size.height - 30)
            // The "Needs attention" glyph as Settings draws it: a bitmap symbol on every macOS.
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: size.width, height: 30)
        }
        .background(appearance == .dark ? Color.black : Color.white)
        let host = NSHostingView(rootView: drawer)
        let window = window(holding: host)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (host, window)
    }

    private static func window(holding view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: view.frame.size == .zero ? size : view.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        VLOrderTestWindow(window)
        return window
    }

    /// Lets Core Animation run the display pass the synchronizer asked for.
    private static func commit() {
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    private static func holdsImage(_ layer: CALayer) -> Bool {
        guard let contents = layer.contents else { return false }
        return CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
    }

    private static func imageLayers(in layer: CALayer?) -> [CALayer] {
        guard let layer else { return [] }
        return (holdsImage(layer) ? [layer] : []) + (layer.sublayers ?? []).flatMap { imageLayers(in: $0) }
    }
}

private func n12SolidImage(side: Int) throws -> CGImage {
    let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return try XCTUnwrap(context.makeImage())
}

/// A delegate that renders its layer into an image at the layer's scale (R886: such a layer holds a `CGImage`
/// and still owns its drawing).
private final class N12ImageRenderingDelegate: NSObject, CALayerDelegate {
    func display(_ layer: CALayer) {
        layer.contents = try? n12SolidImage(side: Int(layer.bounds.width * layer.contentsScale))
    }
}

/// A delegate that draws into the backing store Core Animation gives it.
private final class N12DrawingDelegate: NSObject, CALayerDelegate {
    private(set) var drawnScales: [CGFloat] = []

    func draw(_ layer: CALayer, in context: CGContext) {
        drawnScales.append(layer.contentsScale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(layer.bounds)
    }
}

/// A layer that renders itself into an image at its own scale.
private final class N12SelfRenderingLayer: CALayer {
    override func display() {
        contents = try? n12SolidImage(side: Int(bounds.width * contentsScale))
    }
}

/// SwiftUI's `_NSGraphicsView` shape: a plain backing layer whose contents are handed to it; no drawing override.
private final class N12HandedContentsView: NSView {
    override func makeBackingLayer() -> CALayer { CALayer() }
}

/// A view that draws its own layer.
private final class N12DrawingView: NSView {
    private(set) var draws = 0

    override func draw(_ dirtyRect: NSRect) {
        draws += 1
        NSColor.white.setFill()
        dirtyRect.fill()
    }
}
