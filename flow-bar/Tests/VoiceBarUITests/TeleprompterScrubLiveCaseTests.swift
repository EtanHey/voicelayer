import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// NOTCH2: Etan's live 2.2.48 screenshot (2026-10-20) showed the teleprompter scrub bar with a dotted tail after
/// the played part and "so far…" dropped onto a second line under "0:23". This renders the production notch in
/// that state (a long read whose total is still growing) and in the hour case, and checks the pixels: one solid
/// track, and "<total> so far" on one line next to the time.
@MainActor
final class TeleprompterScrubLiveCaseTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private struct Render {
        let image: CGImage
        let scale: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private func render(elapsedMs: Int, totalMs: Int, name: String) throws -> Render {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        let text = "TLA3 covers both the speech queue as it works today and the planned Option+F5 queue. "
            + "It found no rule breaks in either."
        // A long read without estimated_total_ms: synthesis is still adding audio, so the total is "so far".
        state.handleEvent(["type": "state", "state": "speaking", "text": text, "voice": "en-US-GuyNeural",
                           "playback_offset_ms": elapsedMs, "duration_ms": totalMs,
                           "long_read": ["id": "live", "chunk_start_ms": 0, "chunk_index": 0, "chunk_count": 4]])
        state.handleEvent(["type": "subtitle", "words": text.split(separator: " ").enumerated().map {
            ["text": String($0.element), "offset_ms": $0.offset * 350, "duration_ms": 300] as [String: Any]
        }])
        XCTAssertTrue(state.isPlaybackDurationGrowing, "fixture: the total must still be growing")
        XCTAssertTrue(state.showsTeleprompterScrubber, "fixture: the scrub bar must be mounted")

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
                .write(to: directory.appendingPathComponent("live-case-\(name).png"))
        }
        let image = try XCTUnwrap(bitmap.cgImage)
        return Render(image: image, scale: CGFloat(image.width) / size.width, width: size.width, height: size.height)
    }

    /// Luminance per pixel, top-down rows, in pixel units.
    private func luminance(_ render: Render) throws -> (Int, Int, [UInt8]) {
        let image = render.image
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var values = [UInt8](repeating: 0, count: image.width * image.height)
        for row in 0 ..< image.height {
            for column in 0 ..< image.width {
                // A bitmap context's buffer stores the image's top row first.
                let offset = (row * image.width + column) * 4
                values[row * image.width + column] = UInt8(
                    (54 * Int(bytes[offset]) + 183 * Int(bytes[offset + 1]) + 19 * Int(bytes[offset + 2])) / 256)
            }
        }
        return (image.width, image.height, values)
    }

    private func assertLiveCase(elapsedMs: Int, totalMs: Int, total: String, name: String) throws {
        let render = try render(elapsedMs: elapsedMs, totalMs: totalMs, name: name)
        let (width, height, lum) = try luminance(render)
        let s = render.scale
        // The scrub row lives between the text viewport and the controls of the teleprompter body.
        let zoneTop = Int((VoiceBarNotchContract.topHeight + 16 + Theme.teleprompterViewportHeight) * s)
        let zoneBottom = min(height, Int((VoiceBarNotchContract.topHeight + 196 - 14 - 26) * s))
        let bodyLeft = Int((render.width - 465) / 2 * s), bodyRight = Int((render.width + 465) / 2 * s)

        // Labels: bright ink in the trailing quarter of the body, inside the scrub zone.
        let labelLeft = bodyRight - Int(120 * s)
        var rows = Set<Int>(), minX = Int.max, maxX = Int.min
        for row in zoneTop ..< zoneBottom {
            for column in labelLeft ..< bodyRight where lum[row * width + column] > 110 {
                rows.insert(row); minX = min(minX, column); maxX = max(maxX, column)
            }
        }
        if rows.isEmpty, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
            throw XCTSkip("hosted runner render: label ink unreadable over the notch glass")
        }
        let top = try XCTUnwrap(rows.min(), "\(name): no total label rendered"), bottom = rows.max()!
        XCTAssertLessThanOrEqual(CGFloat(bottom - top) / s, 14,
                                 "\(name): the total and \"so far\" must sit on ONE line, not wrap under the time")
        let totalWidth = (total as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]).width
        XCTAssertGreaterThan(CGFloat(maxX - minX) / s, totalWidth + 20,
                             "\(name): \"so far\" must sit next to \(total) on its line")
        XCTAssertLessThan(maxX, bodyRight - Int(2 * s), "\(name): the label clips at the shell edge")

        // Track: the row through the knob's centre. From the end of the played fill to the track's end it is one
        // unbroken bar, never a dotted or dashed tail.
        // Past the leading time label (inset 14 + slot + spacing, under 114 pt on every version), up to the
        // trailing label zone; on 2.2.48 this span includes the dashed tail.
        let laneLeft = bodyLeft + Int(114 * s), laneRight = labelLeft
        var trackRow = zoneTop, best = 0
        for row in zoneTop ..< zoneBottom {
            let count = (laneLeft ..< laneRight).filter { lum[row * width + $0] > 40 }.count
            if count > best { best = count; trackRow = row }
        }
        let background = Int(lum[(trackRow - Int(8 * s)) * width + (laneLeft + laneRight) / 2])
        let ink = (laneLeft ..< laneRight).map { abs(Int(lum[trackRow * width + $0]) - background) > 3 }
        let first = try XCTUnwrap(ink.firstIndex(of: true), "\(name): no track rendered")
        let last = ink.lastIndex(of: true)!
        var gap = 0, widest = 0
        for index in first ... last {
            gap = ink[index] ? 0 : gap + 1
            widest = max(widest, gap)
        }
        XCTAssertLessThan(widest, 2, "\(name): a \(widest) px gap in the track is a dotted/dashed tail")
    }

    func testLiveCaseMinuteReadIsASolidTrackWithSoFarOnOneLine() throws {
        try assertLiveCase(elapsedMs: 1000, totalMs: 23000, total: "0:23", name: "0-23")
    }

    func testLiveCaseHourReadIsASolidTrackWithSoFarOnOneLine() throws {
        try assertLiveCase(elapsedMs: 1_800_000, totalMs: 3_600_000, total: "1:00:00", name: "1-00-00")
    }
}
