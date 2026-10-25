import AppKit
import SwiftUI
import XCTest
@testable import VoiceBarUI

@MainActor
final class TeleprompterReflowTests: XCTestCase {
    @Observable final class Clock {
        var epoch = 0; var elapsed = 0; var started: Date?
        var milliseconds: Int { elapsed + Int((started.map { Date().timeIntervalSince($0) } ?? 0) * 1000) }
    }
    struct Host: View {
        let clock: Clock
        let text: String
        let boundaries: [TeleprompterBoundary]
        var body: some View {
            TeleprompterView(text: text, wordBoundaries: boundaries, playbackEpoch: clock.epoch,
                            playbackElapsedMilliseconds: { clock.milliseconds }, wrapWidth: 280)
                .frame(width: 288, height: 78)
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

    func testBottomBoundaryAndSoftWrapStayIdenticalAndActiveLinePinsToMiddle() throws {
        let text = "Opening sentence fills the first row and continues with words.\n- The installed app.\n- The cutoff control in your screenshot belongs to the same paragraph with enough words to wrap.\n\nNothing needed from you right now."
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let boundaries = tokens.enumerated().map {
            TeleprompterBoundary(offsetMs: $0.offset * 1000, durationMs: 900, text: $0.element, wordIndex: $0.offset)
        }
        let clock = Clock()
        var frames: [Int: CGRect] = [:]
        TeleprompterLandingProbe.didMeasure = { frames = $0 }
        defer { TeleprompterLandingProbe.didMeasure = nil }
        let host = NSHostingView(rootView: Host(clock: clock, text: text, boundaries: boundaries))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 288, height: 78),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() {
            host.layoutSubtreeIfNeeded()
            // Playback crosses the boundary after 150 ms, then glides for 180 ms.
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let original = frames
        XCTAssertEqual(original.count, tokens.count)
        let secondBullet = try XCTUnwrap(tokens.indices.filter { tokens[$0] == "-" }.last)
        XCTAssertGreaterThan(try XCTUnwrap(original[secondBullet]).minY,
                             try XCTUnwrap(original[secondBullet - 1]).minY)
        for seeking in [true, false] {
            clock.started = nil; clock.elapsed = 0; clock.epoch += 1; settle()
            var previousLine: CGFloat?
            for index in tokens.indices {
                // For playback, start just before the target and let the real animation task cross it.
                clock.elapsed = seeking || index == 0 ? index * 1000 : index * 1000 - 150
                clock.started = seeking ? nil : Date()
                clock.epoch += 1
                settle()
                let active = try XCTUnwrap(frames[index])
                for word in tokens.indices {
                    let before = try XCTUnwrap(original[word]), after = try XCTUnwrap(frames[word])
                    XCTAssertEqual(after.minX, before.minX, accuracy: 0.1)
                    XCTAssertEqual(after.minY - active.minY, before.minY - original[index]!.minY, accuracy: 0.1)
                }
                let line = original[index]!.minY
                if line > original[0]!.minY + 20 {
                    XCTAssertEqual(Int(active.midY / 26), 1, "active line is the middle row")
                }
                if let previousLine, line == previousLine {
                    XCTAssertEqual(Int(active.midY / 26), 1, "no second scroll within a line")
                }
                previousLine = line > original[0]!.minY + 20 ? line : nil
            }
        }
    }
}
