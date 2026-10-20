import AppKit
import SwiftUI
import Vision
@testable import VoiceBarUI
import XCTest

/// TELE1 PR B: a far jump driven by the timeline (an epoch that lands before its subtitle, or a same-epoch
/// timing update) must still bring the current word, inside a not-yet-built lazy block, into the viewport.
@MainActor
final class TeleprompterLazyScrollTests: XCTestCase {
    @Observable final class Feed {
        var boundaries: [TeleprompterBoundary]
        var epoch = 0
        var elapsed = 0
        init(boundaries: [TeleprompterBoundary]) { self.boundaries = boundaries }
    }

    private struct Host: View {
        let text: String
        let feed: Feed
        var body: some View {
            TeleprompterView(text: text, wordBoundaries: feed.boundaries, playbackEpoch: feed.epoch,
                             playbackElapsedMilliseconds: { [feed] in feed.elapsed })
                .frame(width: 300, height: Theme.teleprompterViewportHeight)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
        }
    }

    private let tokens = (0 ..< 4500).map { $0 % 40 == 39 ? "word\($0).\n\n" : "word\($0)" }
    private var text: String { tokens.joined(separator: " ") }

    private func timed(_ range: Range<Int>) -> [TeleprompterBoundary] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return range.map { TeleprompterBoundary(offsetMs: $0 * 380, durationMs: 340, text: words[$0], wordIndex: $0) }
    }

    private func settle(_ host: NSView, _ seconds: TimeInterval = 0.6) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    /// What is actually painted inside the viewport, read back with OCR.
    private func onScreenText(_ host: NSView) -> String {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return "" }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["TELE1_LAZY_DUMP"], let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("lazy-\(Int(Date().timeIntervalSince1970 * 1000)).png"))
        }
        guard let image = bitmap.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// OCR reads a bold 0 as O and 1 as l now and then; fold lookalikes on both sides.
    private func isOnScreen(_ word: String, _ host: NSView) -> Bool {
        func fold(_ text: String) -> String {
            String(text.map { "Oo".contains($0) ? "0" : "lI|".contains($0) ? "1" : $0 })
        }
        return onScreenText(host).components(separatedBy: CharacterSet.alphanumerics.inverted).map(fold)
            .contains(fold(word))
    }

    private func mount(_ feed: Feed) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: Host(text: text, feed: feed))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: Theme.teleprompterViewportHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        settle(host)
        return (window, host)
    }

    func testAnEpochBeforeItsSubtitleStillScrollsTheFarWordIntoView() {
        let feed = Feed(boundaries: timed(0 ..< 10))
        let (window, host) = mount(feed)
        defer { window.contentView = nil }
        XCTAssertTrue(isOnScreen("word0", host), "the read starts on screen")
        XCTAssertFalse(isOnScreen("word2200", host), "the destination starts unbuilt")

        feed.elapsed = 2200 * 380 + 10
        feed.epoch += 1 // the seek's speaking edge, before the destination chunk is timed
        settle(host)
        feed.boundaries = timed(0 ..< 10) + timed(2200 ..< 2210) // its subtitle, same epoch
        settle(host)
        XCTAssertTrue(isOnScreen("word2200", host), "the current word is laid out and on screen; OCR: \(onScreenText(host).prefix(120))")
    }

    func testASameEpochTimingJumpScrollsTheFarWordIntoView() {
        let feed = Feed(boundaries: timed(0 ..< 10))
        let (window, host) = mount(feed)
        defer { window.contentView = nil }
        feed.elapsed = 3100 * 380 + 10
        feed.boundaries = timed(0 ..< 10) + timed(3100 ..< 3110)
        settle(host)
        XCTAssertTrue(isOnScreen("word3100", host), "a timeline jump reaches the far word too; OCR: \(onScreenText(host).prefix(120))")
    }
}
