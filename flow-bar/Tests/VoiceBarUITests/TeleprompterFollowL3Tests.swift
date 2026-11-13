import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C6 lane L3, V3-8 (Etan: no scroll-back in the live teleprompter): browsing older text does not force-follow until
/// an explicit return.
@MainActor
final class TeleprompterFollowL3Tests: XCTestCase {
    // MARK: - RED on candidate 5: the live teleprompter has a scroll path at all

    func testLiveTeleprompterMountsAScrollPath() throws {
        let host = mount(clock: { 60_000 })
        defer { host.window?.close() }
        host.layoutSubtreeIfNeeded()
        let names = descendants(host).map { String(describing: type(of: $0)) }
        XCTAssertTrue(names.contains { $0.contains("ScrollCatcher") }, "V3-8: Teleprompter A takes scroll events")
    }

    // MARK: - Browse never force-follows

    func testBrowsingHoldsItsLineWhileTheVoiceMovesOn() {
        var follow = TeleprompterFollow()
        follow.scroll(byLines: -2, followTop: 6, maximumTop: 10)
        XCTAssertEqual(follow.top(followTop: 6, maximumTop: 10), 4)
        for voiceTop in 7 ... 10 {
            XCTAssertEqual(follow.top(followTop: voiceTop, maximumTop: 10), 4, "no force-follow at \(voiceTop)")
        }
        follow.returnToReading()
        XCTAssertFalse(follow.isBrowsing)
        XCTAssertEqual(follow.top(followTop: 10, maximumTop: 10), 10)
    }

    func testScrollingBackToTheLiveLineStillDoesNotResumeFollowing() {
        var follow = TeleprompterFollow()
        follow.scroll(byLines: -1, followTop: 3, maximumTop: 9)
        follow.scroll(byLines: 1, followTop: 3, maximumTop: 9)
        XCTAssertTrue(follow.isBrowsing, "only an explicit return follows again")
        XCTAssertEqual(follow.top(followTop: 5, maximumTop: 9), 3)
    }

    func testAScrollThatMovesNothingStartsNoBrowse() {
        var follow = TeleprompterFollow()
        follow.scroll(byLines: -1, followTop: 0, maximumTop: 4)
        XCTAssertFalse(follow.isBrowsing, "already at the first line")
        follow.scroll(byLines: 1, followTop: 4, maximumTop: 4)
        XCTAssertFalse(follow.isBrowsing, "already at the last full window")
        follow.scroll(byLines: -9, followTop: 4, maximumTop: 4)
        XCTAssertEqual(follow.browseTop, 0, "clamped to the first line")
    }

    func testTrackpadPointsAccumulateIntoWholeLinesAndWheelClicksAreLines() {
        var follow = TeleprompterFollow()
        follow.scroll(deltaY: 10, isPrecise: true, followTop: 5, maximumTop: 9)
        XCTAssertFalse(follow.isBrowsing, "10 pt is less than a 24 pt line")
        follow.scroll(deltaY: 15, isPrecise: true, followTop: 5, maximumTop: 9)
        XCTAssertEqual(follow.browseTop, 4, "positive travel reveals earlier text")
        follow.scroll(deltaY: -1, isPrecise: false, followTop: 5, maximumTop: 9)
        XCTAssertEqual(follow.browseTop, 5)
    }

    // MARK: - The real view

    func testScrollOverTheColumnBrowsesAndShowsBackToReading() throws {
        let host = mount(clock: { 60_000 })
        defer { host.window?.close() }
        let catcher = try catcherView(host)
        XCTAssertFalse(tooltips(host).contains("Follow the voice again"))
        let centre = catcher.convert(NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY), to: nil)
        XCTAssertFalse(catcher.takes(window: nil, locationInWindow: centre, deltaY: 30, isPrecise: true),
                       "another window's scroll is not ours")
        XCTAssertFalse(catcher.takes(window: host.window, locationInWindow: NSPoint(x: -50, y: -50), deltaY: 30,
                                     isPrecise: true), "outside the column is not ours")
        XCTAssertTrue(catcher.takes(window: host.window, locationInWindow: centre, deltaY: 30, isPrecise: true))
        let shown = expectation(for: NSPredicate { [self] _, _ in
            host.layoutSubtreeIfNeeded()
            return tooltips(host).contains("Follow the voice again")
        }, evaluatedWith: nil)
        wait(for: [shown], timeout: 3)
    }

    // MARK: - R893 P2: a new read follows its own voice, even with identical text

    func testANewReadWithTheSameTextStopsBrowsing() throws {
        let host = mount(clock: { 60_000 }, readIdentity: "read:1")
        defer { host.window?.close() }
        let catcher = try catcherView(host)
        let centre = catcher.convert(NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY), to: nil)
        XCTAssertTrue(catcher.takes(window: host.window, locationInWindow: centre, deltaY: 30, isPrecise: true))
        let browsing = expectation(for: NSPredicate { [self] _, _ in
            host.layoutSubtreeIfNeeded()
            return tooltips(host).contains("Follow the voice again")
        }, evaluatedWith: nil)
        wait(for: [browsing], timeout: 3)
        // Another agent reads the same selection: same string, new utterance.
        host.rootView = teleprompter(clock: { 1_000 }, readIdentity: "read:2")
        let following = expectation(for: NSPredicate { [self] _, _ in
            host.layoutSubtreeIfNeeded()
            return !tooltips(host).contains("Follow the voice again")
        }, evaluatedWith: nil)
        wait(for: [following], timeout: 3)
    }

    func testTheSameReadKeepsBrowsingWhenItsViewIsRebuilt() throws {
        let host = mount(clock: { 60_000 }, readIdentity: "read:1")
        defer { host.window?.close() }
        let catcher = try catcherView(host)
        let centre = catcher.convert(NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY), to: nil)
        XCTAssertTrue(catcher.takes(window: host.window, locationInWindow: centre, deltaY: 30, isPrecise: true))
        host.rootView = teleprompter(clock: { 61_000 }, readIdentity: "read:1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(tooltips(host).contains("Follow the voice again"), "pause, resume and chunks keep the browse")
    }

    /// R893 P3: Reduce Motion removes the press scale; the pill dims instead, so the press still reads.
    func testBackToReadingPressNeverScalesUnderReduceMotion() {
        XCTAssertEqual(TeleprompterReturnPress.scale(isPressed: true, reduceMotion: true), 1)
        XCTAssertLessThan(TeleprompterReturnPress.opacity(isPressed: true, reduceMotion: true), 1)
        XCTAssertEqual(TeleprompterReturnPress.scale(isPressed: true, reduceMotion: false), 0.97)
        XCTAssertEqual(TeleprompterReturnPress.opacity(isPressed: true, reduceMotion: false), 1)
        XCTAssertEqual(TeleprompterReturnPress.scale(isPressed: false, reduceMotion: false), 1)
    }

    func testCatcherNeverTakesAClick() throws {
        let host = mount(clock: { 0 })
        defer { host.window?.close() }
        let catcher = try catcherView(host)
        XCTAssertNil(catcher.hitTest(NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY)))
    }

    func testHiddenTeleprompterMountsNoScrollPath() {
        let host = mount(clock: { 60_000 }, allowsBrowsing: false)
        defer { host.window?.close() }
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(descendants(host).contains { $0 is TeleprompterScrollCatcher.CatcherView })
    }

    // MARK: - Helpers

    private static let longText = (1 ... 120).map { "word\($0)" }.joined(separator: " ")

    private static var boundaries: [TeleprompterBoundary] {
        (0 ..< 120).map { TeleprompterBoundary(offsetMs: $0 * 500, durationMs: 400, text: "word\($0 + 1)") }
    }

    private func teleprompter(clock: @escaping () -> Int, allowsBrowsing: Bool = true,
                              readIdentity: String? = nil) -> AnyView {
        AnyView(TeleprompterAView(text: Self.longText, wordBoundaries: Self.boundaries, visibleLines: 3,
                                  playbackElapsedMilliseconds: clock, allowsBrowsing: allowsBrowsing,
                                  readIdentity: readIdentity))
    }

    private func mount(clock: @escaping () -> Int, allowsBrowsing: Bool = true,
                       readIdentity: String? = nil) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: teleprompter(clock: clock, allowsBrowsing: allowsBrowsing,
                                                        readIdentity: readIdentity))
        host.frame = NSRect(x: 0, y: 0, width: TeleprompterA.columnWidth + 20, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        window.orderBack(nil)
        return host
    }

    private func catcherView(_ host: NSView) throws -> TeleprompterScrollCatcher.CatcherView {
        let found = expectation(for: NSPredicate { [self] _, _ in
            host.layoutSubtreeIfNeeded()
            return descendants(host).contains { $0 is TeleprompterScrollCatcher.CatcherView }
        }, evaluatedWith: nil)
        wait(for: [found], timeout: 3)
        return try XCTUnwrap(descendants(host).compactMap { $0 as? TeleprompterScrollCatcher.CatcherView }.first)
    }

    private func tooltips(_ host: NSView) -> Set<String> { Set(descendants(host).compactMap(\.toolTip)) }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
