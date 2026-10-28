import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// NOTCH2: "Preparing speech…" is a status, so it sits on the teleprompter body's centre, not in the reading
/// flow's top-leading corner where it read as off-centre.
@MainActor
final class TeleprompterPreparingLayoutTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private func renderTeleprompter(_ state: VoiceState) throws -> (CGImage, VoiceBarNotchGeometry) {
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false)
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
        let size = CGSize(width: canvas.totalWidth + 24, height: canvas.totalHeight + 17)
        let host = NSHostingView(rootView:
            BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                    presentationModel: model, includesPanelOutsets: true)
                .environment(\.colorScheme, .dark)
        )
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["VOICEBAR_NOTCH2_SHOTS_DIR"], !path.isEmpty {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("preparing-teleprompter.png"))
        }
        return (try XCTUnwrap(bitmap.cgImage), model.presentation.geometry)
    }

    func testPreparingSpeechIsCentredInTheTeleprompterBody() throws {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "prep", "chunk_start_ms": 0, "preparing": true]])
        XCTAssertTrue(state.isPreparingSpeech)
        let (image, geometry) = try renderTeleprompter(state)
        let scale = CGFloat(image.width) / (VoiceBarNotchMorphCanvasLayout.resolve(
            for: VoiceBarNotchPresentation.resolve(
                hasTeleprompter: true, isRecording: false, hasCompactStatus: false,
                isHovered: false, isKeyboardFocused: false
            )
        ).canvasGeometry.totalWidth + 24)

        // The text area: below the top row, above the scrubber and the controls.
        let band = CGRect(x: 0, y: geometry.topHeight + 8, width: CGFloat(image.width) / scale,
                          height: Theme.teleprompterViewportHeight + 8)
        let ink = try inkBounds(image, in: band, scale: scale)
        let panelMidX = CGFloat(image.width) / scale / 2
        XCTAssertEqual(ink.midX, panelMidX, accuracy: 3, "Preparing speech… must sit on the body's centre axis")
        XCTAssertGreaterThan(ink.minY, band.minY + 12, "Preparing speech… must not hug the body's top edge")
    }

    /// Bounds, in points, of pixels brighter than the glass in `rect`.
    private func inkBounds(_ image: CGImage, in rect: CGRect, scale: CGFloat) throws -> CGRect {
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let crop = try XCTUnwrap(image.cropping(to: pixels))
        let context = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for row in 0 ..< crop.height {
            for column in 0 ..< crop.width {
                let offset = (row * crop.width + column) * 4
                let luminance = (54 * Int(bytes[offset]) + 183 * Int(bytes[offset + 1]) + 19 * Int(bytes[offset + 2])) / 256
                guard luminance > 110 else { continue }
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        try GlassTextCapability.current.get().requireReadableText()
        guard minX <= maxX else {
            XCTFail("no ink in \(rect)")
            return .zero
        }
        // A bitmap context's buffer stores the crop's top row first, so rows are already top-down.
        return CGRect(
            x: rect.minX + CGFloat(minX) / scale,
            y: rect.minY + CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
    }
}
