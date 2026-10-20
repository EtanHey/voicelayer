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

    // Split B R2 (Sol): with 320-word unpunctuated blocks the adjacent block is not built either.
    private struct PlainHost: View {
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

    private let plainText = (0 ..< 4500).map { "word\($0)" }.joined(separator: " ")

    private func plainTimed(_ range: Range<Int>) -> [TeleprompterBoundary] {
        range.map { TeleprompterBoundary(offsetMs: $0 * 380, durationMs: 340, text: "word\($0)", wordIndex: $0) }
    }

    private func mountPlain(_ feed: Feed) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: PlainHost(text: plainText, feed: feed))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: Theme.teleprompterViewportHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        settle(host)
        return (window, host)
    }

    private func jump(_ feed: Feed, to word: Int, _ host: NSView) {
        feed.elapsed = word * 380 + 10
        feed.boundaries = plainTimed(0 ..< 10) + plainTimed(word ..< word + 10)
        settle(host)
    }

    func testASameEpochJumpIntoTheAdjacentUnpunctuatedBlockScrollsTheWordIntoView() {
        let feed = Feed(boundaries: plainTimed(0 ..< 10))
        let (window, host) = mountPlain(feed)
        defer { window.contentView = nil }
        XCTAssertTrue(isOnScreen("word0", host))
        for target in [320, 640] {
            jump(feed, to: target, host)
            XCTAssertTrue(isOnScreen("word\(target)", host),
                          "adjacent block \(target / 320) is reached; OCR: \(onScreenText(host).prefix(120))")
        }
    }

    func testAJumpBackIntoTheAdjacentBlockScrollsTheWordIntoView() {
        let feed = Feed(boundaries: plainTimed(0 ..< 10))
        let (window, host) = mountPlain(feed)
        defer { window.contentView = nil }
        jump(feed, to: 1300, host)
        XCTAssertTrue(isOnScreen("word1300", host))
        jump(feed, to: 1000, host) // block 3, the block before 1300's block 4
        XCTAssertTrue(isOnScreen("word1000", host), "backward adjacent jump; OCR: \(onScreenText(host).prefix(120))")
    }

    // TELE1C (Sol split-B R2): equal-timestamp pieces make one coalesced playback advance across the
    // hard block boundary; the destination and the next ordinary word must both reach the viewport.
    @Observable final class Clock {
        var boundaries: [TeleprompterBoundary]
        let base: Int
        let started = Date()
        init(boundaries: [TeleprompterBoundary], base: Int) { self.boundaries = boundaries; self.base = base }
        var elapsed: Int { base + Int(Date().timeIntervalSince(started) * 1000) }
    }

    private struct ClockHost: View {
        let text: String
        let clock: Clock
        var body: some View {
            TeleprompterView(text: text, wordBoundaries: clock.boundaries,
                             playbackElapsedMilliseconds: { [clock] in clock.elapsed })
                .frame(width: 300, height: Theme.teleprompterViewportHeight)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
        }
    }

    func testACoalescedPlaybackAdvanceAcrossTheBlockBoundaryReachesTheWordAndTheNext() {
        let token = String(repeating: "x", count: 960) // 40 display pieces, one timestamp
        let raw = (0 ... 280).map { "word\($0)" } + [token] + (282 ..< 600).map { "word\($0)" }
        let text = raw.joined(separator: " ")
        let boundaries = (0 ... 282).map { index -> TeleprompterBoundary in
            let offset = index <= 280 ? index * 380 : index == 281 ? 107_600 : 108_000
            return TeleprompterBoundary(offsetMs: offset, durationMs: 340, text: raw[index], wordIndex: index)
        }
        let clock = Clock(boundaries: boundaries, base: 106_410)
        let host = NSHostingView(rootView: ClockHost(text: text, clock: clock))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: Theme.teleprompterViewportHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.contentView = nil }
        settle(host, 0.5)
        XCTAssertTrue(isOnScreen("word280", host), "the read starts on word 280; OCR: \(onScreenText(host).prefix(120))")
        settle(host, 0.85) // the token's 40 pieces land at 107.6 s in one coalesced step (280 -> 320); now ~107.76 s
        let destination = onScreenText(host)
        XCTAssertNotNil(destination.range(of: "x{8,}", options: [.regularExpression, .caseInsensitive]),
                        "the token's last piece, in block 1, is on screen; OCR: \(destination.prefix(120))")
        settle(host, 0.6) // word282 (display id 321) at 108.0 s
        XCTAssertTrue(isOnScreen("word282", host), "the next ordinary word follows; OCR: \(onScreenText(host).prefix(120))")
    }

    // TELE1C R2 (Sol, P1 crash): a landing waiting for word 320 must not outlive a document replacement.
    @Observable final class ReplacingClock {
        var text: String
        var boundaries: [TeleprompterBoundary]
        let started = Date()
        init(text: String, boundaries: [TeleprompterBoundary]) { self.text = text; self.boundaries = boundaries }
        var elapsed: Int { 106_410 + Int(Date().timeIntervalSince(started) * 1000) }
    }

    private struct ReplacingHost: View {
        let clock: ReplacingClock
        var body: some View {
            TeleprompterView(text: clock.text, wordBoundaries: clock.boundaries,
                             playbackElapsedMilliseconds: { [clock] in clock.elapsed })
                .frame(width: 300, height: Theme.teleprompterViewportHeight)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
        }
    }

    func testReplacingTheDocumentWhileALandingIsPendingNeitherTrapsNorLandsStale() throws {
        let token = String(repeating: "x", count: 960)
        let raw = (0 ... 280).map { "word\($0)" } + [token] + (282 ..< 600).map { "word\($0)" }
        let boundaries = (0 ... 282).map { index -> TeleprompterBoundary in
            let offset = index <= 280 ? index * 380 : index == 281 ? 107_600 : 108_000
            return TeleprompterBoundary(offsetMs: offset, durationMs: 340, text: raw[index], wordIndex: index)
        }
        let clock = ReplacingClock(text: raw.joined(separator: " "), boundaries: boundaries)
        var replaced = false
        TeleprompterLandingProbe.didPend = {
            guard !replaced else { return }
            replaced = true
            clock.text = "Shorter replacement"
            clock.boundaries = []
        }
        var staleLandings: [Int] = []
        TeleprompterLandingProbe.didLand = { word in if replaced { staleLandings.append(word) } }
        defer { TeleprompterLandingProbe.didPend = nil; TeleprompterLandingProbe.didLand = nil }
        let host = NSHostingView(rootView: ReplacingHost(clock: clock))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: Theme.teleprompterViewportHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.contentView = nil }
        settle(host, 2.2) // the coalesced 280 -> 320 step pends at ~107.6 s; the probe swaps the document then
        // A host whose lazy stack already built the next block never pends (seen on the CI runner): the window
        // this regression needs does not exist there. Skip loudly rather than pass or fail on another scenario.
        guard replaced else {
            throw XCTSkip("block 1 was already built on this host, so no landing went pending; scenario unreachable")
        }
        settle(host, 0.6)
        let text = onScreenText(host)
        XCTAssertTrue(text.contains("Shorter") && text.contains("replacement"), "the short document renders; OCR: \(text)")
        XCTAssertEqual(staleLandings, [], "the old document's landing never scrolls the new one")
    }
}
