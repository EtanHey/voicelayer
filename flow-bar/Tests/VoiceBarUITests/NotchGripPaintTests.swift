import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor final class NotchGripPaintTests: XCTestCase {
    /// Render the production handle, its capsule and the production rows modifier inside the shell's exact height.
    /// This is component pixel proof; the installed/native-glass full drawer remains a separate acceptance surface.
    static func render(progress: CGFloat, rows: CGFloat, light: Bool) throws -> (CGRect, NSBitmapImageRep, CGFloat, CGFloat) {
        let open = VoiceBarNotchContract.geometry(for: .history)
        let fade = NotchHistoryMorph.listTopInset + NotchHistoryMorph.listHeight(rows: rows)
        let height = fade + NotchHistoryMorph.handleBandHeight
        let morph = VoiceBarNotchHistoryMorphInput(progress: NotchHistoryMorph.rubberBand(1 + progress * 0.3),
            closed: VoiceBarNotchContract.geometry(for: .hoverLauncher), open: open, openLowerSurfaceHeight: height)
        let bottom = morph.geometry(at: morph.progress).lowerSurfaceHeight
        let extra = bottom - height
        var observed: CGRect?
        NotchPullHintProbe.rectObserver = { observed = $0 }
        defer { NotchPullHintProbe.rectObserver = nil }
        let content = VStack(spacing: 0) {
            Color.blue.frame(height: fade)
            NotchHistoryExtendHandle(palette: .resolve(for: light ? .light : .dark),
                settingsHintProgress: progress, settingsHintOffset: extra / 2)
                .frame(width: 420, height: NotchHistoryMorph.handleBandHeight)
        }
        .frame(width: 420, height: bottom, alignment: .top)
        .modifier(NotchHistoryRowsMorph(progress: morph.progress, keepsPointer: true))
        .clipped()
        .background(light ? Color.white : Color.black)
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 420, height: bottom)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        VLOrderTestWindow(window)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)); host.layoutSubtreeIfNeeded()
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
        return (try XCTUnwrap(observed, "the actual capsule must report its laid-out frame"), bitmap, fade, bottom)
    }

    func testActualCapsulePixelsStayInsideTheFooterAndClearEveryRow() throws {
        for light in [false, true] {
            for rows: CGFloat in [6, 8] {
                for p: CGFloat in [0, 0.5, 1] {
                    let (rect, bitmap, fade, bottom) = try Self.render(progress: p, rows: rows, light: light)
                    XCTAssertGreaterThanOrEqual(rect.minY, fade)
                    XCTAssertLessThanOrEqual(rect.maxY, bottom)
                    XCTAssertEqual(rect.midX, 210, accuracy: 0.5)
                    if p == 1 {
                        XCTAssertEqual(rect.minY - fade, 8, accuracy: 0.5)
                        XCTAssertEqual(bottom - rect.maxY, 8, accuracy: 0.5)
                    }
                    var ink: CGRect = .null
                    for y in Int(ceil(fade * 2))..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                            let grey = abs(c.redComponent - c.greenComponent) < 0.03 && abs(c.greenComponent - c.blueComponent) < 0.03
                            let differs = light ? c.redComponent < 0.97 : c.redComponent > 0.03
                            if grey && differs { ink = ink.union(CGRect(x: CGFloat(x)/2, y: CGFloat(y)/2, width: 0.5, height: 0.5)) }
                        }
                    }
                    XCTAssertFalse(ink.isNull, "the real capsule must paint, not just have a geometry frame")
                    XCTAssertEqual(ink.minY, rect.minY, accuracy: 1, "top is painted and not clipped")
                    XCTAssertEqual(ink.maxY, rect.maxY, accuracy: 1, "bottom is painted and not clipped")
                    XCTAssertEqual(ink.minX, rect.minX, accuracy: 1)
                    XCTAssertEqual(ink.maxX, rect.maxX, accuracy: 1)
                    if let base = ProcessInfo.processInfo.environment["R1_GRIP_SHOTS"] {
                        let directory = URL(fileURLWithPath: base); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let name = "grip-\(rows)-\(p)-\(light ? "light" : "dark").png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
                    }
                }
            }
        }
    }

    func testTheProductionGripHoverBrightensItsInk() throws {
        func ink(_ hovered: Bool) throws -> Double {
            let host = NSHostingView(rootView: NotchSettingsPullHint(ink: .white, progress: 0, isHovered: hovered)
                .frame(width: 100, height: 30).background(Color.black))
            host.frame = CGRect(x: 0, y: 0, width: 100, height: 30); host.layoutSubtreeIfNeeded()
            let rep = try EtanQA0510Tests.fixedScaleBitmap(host)
            return try XCTUnwrap(rep.colorAt(x: 100, y: 30)?.usingColorSpace(.sRGB)).redComponent
        }
        XCTAssertGreaterThan(try ink(true), try ink(false) + 0.05, "the real grip uses its hover opacity")
    }
}
