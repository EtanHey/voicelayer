import AppKit
import SwiftUI
import XCTest
@testable import VoiceBarUI

@MainActor
final class TeleprompterReflowTests: XCTestCase {
    @MainActor @Observable final class Clock {
        var epoch = 0
        let playback = TeleprompterTestPlaybackClock()
    }
    struct Host: View {
        let clock: Clock
        let text: String
        let boundaries: [TeleprompterBoundary]
        var body: some View {
            var view = TeleprompterView(text: text, wordBoundaries: boundaries, playbackEpoch: clock.epoch,
                                       playbackElapsedMilliseconds: { clock.playback.elapsed }, wrapWidth: 280)
            view.playbackSleep = clock.playback.sleep
            return view.frame(width: 288, height: 78)
        }
    }

    func testOneAndTwoLineTextStayVerticallyCentred() throws {
        for text in ["Short sentence.", "First row.\nSecond row."] {
            var frames: [Int: CGRect] = [:]
            TeleprompterLandingProbe.didMeasure = { frames = $0 }
            defer { TeleprompterLandingProbe.didMeasure = nil }
            let host = NSHostingView(rootView: Host(clock: Clock(), text: text, boundaries: []))
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 288, height: 78),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let bounds = try XCTUnwrap(frames.values.reduce(nil as CGRect?) { $0?.union($1) ?? $1 })
            XCTAssertEqual(bounds.midY, 39, accuracy: 2, "centred text: \(text)")
        }
    }

    func testBottomBoundaryAndSoftWrapStayIdenticalAndActiveLinePinsToMiddle() async throws {
        let text = "Opening sentence fills the first row and continues with words.\n- The installed app.\n- The cutoff control in your screenshot belongs to the same paragraph with enough words to wrap.\n\nNothing needed from you right now."
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let boundaries = tokens.enumerated().map {
            TeleprompterBoundary(offsetMs: $0.offset * 1000, durationMs: 900, text: $0.element, wordIndex: $0.offset)
        }
        let clock = Clock()
        let presentation = TeleprompterTestPresentation()
        defer { presentation.close(); clock.playback.cancel() }
        let host = NSHostingView(rootView: Host(clock: clock, text: text, boundaries: boundaries))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 288, height: 78),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func restart(at milliseconds: Int) async {
            let starts = clock.playback.starts
            clock.playback.elapsed = milliseconds
            clock.epoch += 1
            await presentation.wait(host, clock: clock.playback, for: "timeline restarted at \(milliseconds)") { _ in
                clock.playback.starts > starts
            }
        }
        await presentation.wait(host, clock: clock.playback, for: "initial word geometry") {
            $0.count == tokens.count && clock.playback.isSuspended(until: 1000)
        }
        let original = presentation.frames
        XCTAssertEqual(original.count, tokens.count)
        let secondBullet = try XCTUnwrap(tokens.indices.filter { tokens[$0] == "-" }.last)
        XCTAssertGreaterThan(try XCTUnwrap(original[secondBullet]).minY,
                             try XCTUnwrap(original[secondBullet - 1]).minY)
        for seeking in [true, false] {
            await restart(at: 0)
            var previousLine: CGFloat?
            for index in tokens.indices {
                if seeking || index == 0 {
                    await restart(at: index * 1000 + 10)
                } else {
                    await restart(at: index * 1000 - 150)
                    await presentation.wait(host, clock: clock.playback, for: "playback awaiting word \(index)") { _ in
                        clock.playback.isSuspended(until: index * 1000)
                    }
                    clock.playback.advance(to: index * 1000 + 10)
                }
                let line = try XCTUnwrap(original[index]).minY
                let isLaterLine = line > original[0]!.minY + 20
                await presentation.wait(host, clock: clock.playback, for: "word \(index) landed, seeking=\(seeking)") { frames in
                    guard let active = frames[index] else { return false }
                    let landed = !isLaterLine || Int(active.midY / 26) == 1
                    return landed && (index == tokens.count - 1 || clock.playback.isSuspended(until: (index + 1) * 1000))
                }
                let frames = presentation.frames
                let active = try XCTUnwrap(frames[index])
                for word in tokens.indices {
                    let before = try XCTUnwrap(original[word]), after = try XCTUnwrap(frames[word])
                    XCTAssertEqual(after.minX, before.minX, accuracy: 0.1)
                    XCTAssertEqual(after.minY - active.minY, before.minY - original[index]!.minY, accuracy: 0.1)
                }
                if isLaterLine {
                    XCTAssertEqual(Int(active.midY / 26), 1, "active line is the middle row")
                }
                if let previousLine, line == previousLine {
                    XCTAssertEqual(Int(active.midY / 26), 1, "no second scroll within a line")
                }
                previousLine = isLaterLine ? line : nil
            }
        }
    }
}
