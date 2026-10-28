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

    private func waitForPaint(_ host: NSView, until visible: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            host.layoutSubtreeIfNeeded()
            if visible() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while ProcessInfo.processInfo.systemUptime < deadline
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

    // Vision can split the repeated-x fixture into several OCR groups. Ordinary fixture words
    // contain no x, so eight recognised x characters still prove the giant token is painted.
    private func containsLongToken(_ text: String) -> Bool {
        text.filter { $0 == "x" || $0 == "X" }.count >= 8
    }

    /// OCR reads a bold 0 as O and 1 as l now and then; fold lookalikes on both sides. Fixture tokens are
    /// letters then a number, so a match may touch a neighbour's last digit on the left (Vision joins a word
    /// to a highlighted neighbour) but never a letter, and is never followed by another digit.
    static func ocr(_ text: String, shows word: String) -> Bool {
        func fold(_ text: String) -> String {
            String(text.map { "Oo".contains($0) ? "0" : "lI|".contains($0) ? "1" : $0 })
        }
        let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: fold(word)) + "(?![0-9])"
        return fold(text).range(of: pattern, options: .regularExpression) != nil
    }

    private func isOnScreen(_ word: String, _ host: NSView) -> Bool {
        Self.ocr(onScreenText(host), shows: word)
    }

    // CI (1x backing) OCR read "word1000word1001": the highlight box starts at the next word's glyphs, so
    // Vision can join a word to its highlighted neighbour. The 5 pt flow gap is still there; a joined
    // neighbour must count, a longer or different number must not.
    func testOCRMatchAcceptsAWordJoinedToItsNeighbourButNotANearMiss() {
        XCTAssertTrue(Self.ocr("word999 word1000word1001 word1002", shows: "word1000"))
        XCTAssertTrue(Self.ocr("word999word1000 word1001", shows: "word1000"))
        XCTAssertTrue(Self.ocr("w0rdl000", shows: "word1000"))
        XCTAssertFalse(Self.ocr("word10000 word100", shows: "word1000"))
        XCTAssertFalse(Self.ocr("sword1000 word2000", shows: "word1000"))
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
    @MainActor @Observable final class Clock {
        var boundaries: [TeleprompterBoundary]
        let playback: TeleprompterTestPlaybackClock
        init(boundaries: [TeleprompterBoundary], base: Int) {
            self.boundaries = boundaries
            playback = TeleprompterTestPlaybackClock(elapsed: base)
        }
    }

    private struct ClockHost: View {
        let text: String
        let clock: Clock
        var body: some View {
            var view = TeleprompterView(text: text, wordBoundaries: clock.boundaries,
                                       playbackElapsedMilliseconds: { [clock] in clock.playback.elapsed })
            view.playbackSleep = clock.playback.sleep
            return view
                .frame(width: 300, height: Theme.teleprompterViewportHeight)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
        }
    }

    func testACoalescedPlaybackAdvanceAcrossTheBlockBoundaryReachesTheWordAndTheNext() async {
        await coalescedAdvanceAcrossTheBlockBoundary { NSWindow(contentRect: $0, styleMask: .borderless, backing: .buffered, defer: false) }
    }

    /// Hosted CI runners draw at 1x, where SwiftUI snaps the landed word to whole points: half a point off
    /// its Retina position. Run the same landing at 1x so a Retina host covers CI's geometry too.
    private final class OneXWindow: NSWindow {
        override var backingScaleFactor: CGFloat { 1 }
    }

    func testACoalescedPlaybackAdvanceAcrossTheBlockBoundaryAtOneXReachesTheWordAndTheNext() async {
        await coalescedAdvanceAcrossTheBlockBoundary { OneXWindow(contentRect: $0, styleMask: .borderless, backing: .buffered, defer: false) }
    }

    /// Centred in the viewport to within one device pixel, the only freedom pixel snapping leaves.
    private static func isOnMiddleRow(_ frame: CGRect, in window: NSWindow) -> Bool {
        abs(frame.midY - Theme.teleprompterViewportHeight / 2) < 1 / window.backingScaleFactor
    }

    private func coalescedAdvanceAcrossTheBlockBoundary(window makeWindow: (NSRect) -> NSWindow) async {
        let token = String(repeating: "x", count: 960) // 40 display pieces, one timestamp
        let raw = (0 ... 280).map { "word\($0)" } + [token] + (282 ..< 600).map { "word\($0)" }
        let text = raw.joined(separator: " ")
        let boundaries = (0 ... 282).map { index -> TeleprompterBoundary in
            let offset = index <= 280 ? index * 380 : index == 281 ? 107_600 : 108_000
            return TeleprompterBoundary(offsetMs: offset, durationMs: 340, text: raw[index], wordIndex: index)
        }
        let clock = Clock(boundaries: boundaries, base: 106_410)
        let presentation = TeleprompterTestPresentation()
        defer { presentation.close(); clock.playback.cancel() }
        let host = NSHostingView(rootView: ClockHost(text: text, clock: clock))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: Theme.teleprompterViewportHeight)
        let window = makeWindow(host.frame)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.contentView = nil }
        await presentation.wait(host, clock: clock.playback, for: "word280 landed before playback advances") {
            guard let word = $0[280] else { return false }
            return Self.isOnMiddleRow(word, in: window) && clock.playback.isSuspended(until: 107_600)
        }
        XCTAssertTrue(isOnScreen("word280", host), "the read starts on word 280; OCR: \(onScreenText(host).prefix(120))")
        let preAdvanceFrame = onScreenText(host)
        clock.playback.advance(to: 107_760)
        await presentation.wait(host, clock: clock.playback, for: "last token piece landed across the block boundary") {
            guard let piece = $0[320], let earlier = $0[280] else { return false }
            return Self.isOnMiddleRow(piece, in: window) && earlier.maxY < 0
                && clock.playback.isSuspended(until: 108_000)
        }
        let destination = onScreenText(host)
        XCTAssertNotEqual(destination, preAdvanceFrame, "clock advance must produce a new frame")
        XCTAssertFalse(isOnScreen("word280", host), "the earlier word must have scrolled away")
        XCTAssertTrue(containsLongToken(destination),
                        "the token's last piece, in block 1, is on screen; OCR: \(destination.prefix(120))")
        clock.playback.advance(to: 108_010)
        await presentation.wait(host, clock: clock.playback, for: "word282 landed after the long token") {
            guard let word = $0[321] else { return false }
            return Self.isOnMiddleRow(word, in: window)
        }
        XCTAssertTrue(isOnScreen("word282", host), "the next ordinary word follows; OCR: \(onScreenText(host).prefix(120))")
    }

    // Replacements during playback must render against the eagerly mounted new document.
    @Observable final class ReplacingClock {
        var text: String
        var boundaries: [TeleprompterBoundary]
        var elapsed = 107_610
        init(text: String, boundaries: [TeleprompterBoundary]) { self.text = text; self.boundaries = boundaries }
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

    func testReplacingAnEagerDocumentRendersTheShortReplacement() throws {
        let token = String(repeating: "x", count: 960)
        let raw = (0 ... 280).map { "word\($0)" } + [token] + (282 ..< 600).map { "word\($0)" }
        let boundaries = (0 ... 282).map { index -> TeleprompterBoundary in
            let offset = index <= 280 ? index * 380 : index == 281 ? 107_600 : 108_000
            return TeleprompterBoundary(offsetMs: offset, durationMs: 340, text: raw[index], wordIndex: index)
        }
        let clock = ReplacingClock(text: raw.joined(separator: " "), boundaries: boundaries)
        let host = NSHostingView(rootView: ReplacingHost(clock: clock))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: Theme.teleprompterViewportHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.contentView = nil }
        settle(host, 0.3)
        clock.text = "Shorter replacement"
        clock.boundaries = []
        settle(host, 0.6)
        let text = onScreenText(host)
        XCTAssertTrue(text.contains("Shorter") && text.contains("replacement"), "the short document renders; OCR: \(text)")
    }

    // A same-length replacement with matching timings must still land the active word.
    func testASameLengthReplacementWithMatchingTimingsStillLandsTheWord() throws {
        let token = String(repeating: "x", count: 960)
        let raw = (0 ... 280).map { "word\($0)" } + [token] + (282 ..< 600).map { "word\($0)" }
        func rows(_ prefix: String) -> [TeleprompterBoundary] {
            (0 ... 282).map { index in
                let offset = index <= 280 ? index * 380 : index == 281 ? 107_600 : 108_000
                return TeleprompterBoundary(offsetMs: offset, durationMs: 340,
                                            text: raw[index].replacingOccurrences(of: "word", with: prefix), wordIndex: index)
            }
        }
        let clock = ReplacingClock(text: raw.joined(separator: " "), boundaries: rows("word"))
        let host = NSHostingView(rootView: ReplacingHost(clock: clock))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: Theme.teleprompterViewportHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.contentView = nil }
        settle(host, 0.3)
        clock.text = clock.text.replacingOccurrences(of: "word", with: "term")
        clock.boundaries = Array(rows("term").dropLast())
        settle(host, 0.6)
        let text = onScreenText(host)
        XCTAssertTrue(containsLongToken(text),
                        "the current word (the token, in block 1) is on screen; OCR: \(text.prefix(120))")
        clock.elapsed = 108_010
        clock.boundaries = rows("term")
        waitForPaint(host) { self.isOnScreen("term282", host) }
        XCTAssertTrue(isOnScreen("term282", host), "the replacement's next word renders")
        XCTAssertFalse(isOnScreen("word282", host), "no stale word from the previous document")
    }
}
