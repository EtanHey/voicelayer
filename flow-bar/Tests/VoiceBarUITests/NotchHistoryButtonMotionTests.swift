import AppKit
import Observation
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Lane C3: tapping History must not move its button, and its selected colour must ease in rather than snap.
@MainActor
final class NotchHistoryButtonMotionTests: XCTestCase {
    /// The panel window is placed so the core lands on the camera housing:
    /// `x = housing.midX - coreWidth / 2 - (visibleContentRect.minX + geometry.coreOriginX)`.
    /// If the core's x inside the panel differs between two states, AppKit moves the window while SwiftUI
    /// moves the content the other way, in separate commits, and every control jumps for a frame.
    func testTheCoreSitsAtOnePanelXInEveryVisibleState() {
        let states: [(String, VoiceBarNotchPresentation)] = [
            ("launcher", resolve()),
            ("history", resolve(history: true)),
            ("recording", resolve(recording: true)),
            ("recording + hold", resolve(recording: true, recordingLeading: VoiceBarNotchContract
                    .recordingLeadingWingWidthWithHoldControl)),
            ("compact status", resolve(compactStatus: true)),
            ("teleprompter", resolve(teleprompter: true)),
        ]
        let reference = corePanelX(states[0].1)
        for (name, presentation) in states {
            XCTAssertEqual(
                corePanelX(presentation), reference,
                "\(name): the core sits at \(corePanelX(presentation)) pt in the panel, the launcher at \(reference) pt"
            )
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry
            XCTAssertEqual(canvas.totalWidth, VoiceBarNotchMorphCanvasLayout.resolve(for: states[0].1)
                .canvasGeometry.totalWidth, "\(name): the canvas width changed")
        }
    }

    func testTheSelectedHistoryPlateEasesIntoItsColour() throws {
        let box = SelectionBox()
        let host = NSHostingView(rootView: SelectionHarness(box: box))
        host.frame = NSRect(x: 0, y: 0, width: 60, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let idle = plateRed(in: host)

        box.isSelected = true
        var samples: [Int] = []
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
            let red = plateRed(in: host)
            if red != (samples.last ?? idle) { samples.append(red) }
        }
        let selected = try XCTUnwrap(samples.last, "the plate never changed colour")
        XCTAssertGreaterThan(selected - idle, 20, "the selected plate should read as red")
        let firstStep = Double(samples[0] - idle) / Double(selected - idle)
        XCTAssertLessThan(
            firstStep, 0.9,
            "the plate snapped \(Int(firstStep * 100))% of the way to red on its first frame (\(samples))"
        )
        XCTAssertGreaterThanOrEqual(samples.count, 3, "the plate changed colour in too few frames (\(samples))")
    }

    /// Visual receipt (opt-in): the History button selecting, frame by frame, light and dark.
    func testWriteHistorySelectFilmstripWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_MORPH_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_MORPH_SHOTS_DIR to write the History select filmstrip")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, isDark) in [("dark", true), ("light", false)] {
            let box = SelectionBox()
            box.isDark = isDark
            let host = NSHostingView(rootView: SelectionHarness(box: box))
            host.frame = NSRect(x: 0, y: 0, width: 60, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            box.isSelected = true
            let start = Date()
            var frames: [NSBitmapImageRep] = []
            for time in [0, 0.033, 0.066, 0.1, 0.15, 0.25] as [TimeInterval] {
                let wait = time - Date().timeIntervalSince(start)
                if wait > 0 { RunLoop.main.run(until: Date().addingTimeInterval(wait)) }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                frames.append(bitmap)
            }
            window.orderOut(nil)
            window.contentView = nil
            let side = frames[0].pixelsWide
            let strip = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side * frames.count, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
            for (index, frame) in frames.enumerated() {
                frame.draw(in: NSRect(x: index * side, y: 0, width: side, height: side))
            }
            NSGraphicsContext.restoreGraphicsState()
            try XCTUnwrap(strip.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("history-select-\(name).png"), options: .atomic)
        }
    }

    // MARK: - Helpers

    private func resolve(
        recording: Bool = false, history: Bool = false, teleprompter: Bool = false, compactStatus: Bool = false,
        recordingLeading: CGFloat? = nil
    ) -> VoiceBarNotchPresentation {
        VoiceBarNotchPresentation.resolve(
            hasTeleprompter: teleprompter, isRecording: recording, hasCompactStatus: compactStatus,
            hasHistoryPanel: history, recordingLeadingWingWidth: recordingLeading,
            isHovered: !compactStatus, isKeyboardFocused: false
        )
    }

    private func corePanelX(_ presentation: VoiceBarNotchPresentation) -> CGFloat {
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation,
            canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry
        )
        return layout.visibleContentRect.minX + presentation.geometry.coreOriginX
    }

    /// The red channel of the History plate, 9 pt right of the glyph centre: inside the plate and clear of
    /// the glyph's ink.
    private func plateRed(in host: NSView) -> Int {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var pixel = [Int](repeating: 0, count: 4)
        bitmap.getPixel(&pixel, atX: Int((30 + 9) * scale), y: Int(30 * scale))
        return pixel[0]
    }
}

@Observable final class NotchHistorySelectionBox {
    var isSelected = false
    var isDark = true
}

private typealias SelectionBox = NotchHistorySelectionBox

private struct SelectionHarness: View {
    let box: NotchHistorySelectionBox
    var body: some View {
        VoiceBarPillControlButton(
            icon: "clock.arrow.circlepath", optics: .resolve(for: "clock.arrow.circlepath"),
            foreground: box.isSelected ? Theme.recordingColor : box.isDark ? .white : .black, halo: .clear,
            isSelected: box.isSelected, isDestructive: false,
            accessibilityLabel: "History", accessibilityHint: "", action: {}
        )
        .frame(width: 60, height: 60)
        .background(box.isDark ? Color.black : Color.white)
    }
}
