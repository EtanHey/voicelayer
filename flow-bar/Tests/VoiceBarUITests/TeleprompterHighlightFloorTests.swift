import AppKit
import SwiftUI
import XCTest
@testable import VoiceBarUI

/// R2-05: when measured word timing replaces the first-frame estimate, the highlight never jumps back inside one
/// playback epoch, steps on the measured timestamps from then on, and lands on the clock for every new epoch.
@MainActor
final class TeleprompterHighlightFloorTests: XCTestCase {
    private static let text = "alpha bravo charlie delta echo foxtrot"
    private static let estimated = [0, 1000, 2000, 3000, 4000, 5000]
    private static let measured = [0, 1500, 3000, 4500, 6000, 7500]

    private static func boundaries(_ offsets: [Int], text: String = text, estimate: Bool) -> [TeleprompterBoundary] {
        text.split(separator: " ").map(String.init).enumerated().map {
            TeleprompterBoundary(offsetMs: offsets[$0.offset], durationMs: 400, text: $0.element,
                                 wordIndex: $0.offset, isInterpolated: estimate)
        }
    }

    private static func clockWord(_ offsets: [Int], at elapsed: Int, text: String = text) -> Int {
        TeleprompterPlaybackPolicy.currentWordIndex(
            in: TeleprompterContentModel.words(text: text, wordBoundaries: boundaries(offsets, text: text, estimate: false)),
            elapsedMilliseconds: elapsed
        )
    }

    // MARK: - Cursor logic

    func testMeasuredTimingKeepsTheWordOnScreenThenAdvancesOnMeasuredTimestamps() {
        let epoch = TeleprompterHighlightCursor.Epoch(playback: 4, text: Self.text, isReadback: false)
        XCTAssertEqual(Self.clockWord(Self.estimated, at: 2200), 2, "the estimate highlights charlie at 2.2 s")
        XCTAssertEqual(Self.clockWord(Self.measured, at: 2200), 1, "the measured clock alone would say bravo")

        var cursor = TeleprompterHighlightCursor(wordID: 0, at: 0, epoch: epoch)
        cursor.land(on: Self.clockWord(Self.estimated, at: 2200), at: 2200, in: epoch)
        XCTAssertEqual(cursor.wordID, 2)

        cursor.land(on: Self.clockWord(Self.measured, at: 2200), at: 2200, in: epoch, keepingWordOnScreen: true)
        XCTAssertEqual(cursor.wordID, 2, "measured timing replacing the estimate never moves the highlight back")
        cursor.land(on: Self.clockWord(Self.measured, at: 2600), at: 2600, in: epoch, keepingWordOnScreen: true)
        XCTAssertEqual(cursor.wordID, 2, "a later replacement while the clock runs on keeps it too")

        // The measured timeline catches up, then drives every later step.
        cursor.step(to: 3, at: 4500)
        XCTAssertEqual(cursor.wordID, 3)
        cursor.land(on: Self.clockWord(Self.measured, at: 6100), at: 6100, in: epoch, keepingWordOnScreen: true)
        XCTAssertEqual(cursor.wordID, 4)
    }

    /// Review F2b: measured timing AHEAD of the estimate lands straight on the word the audio is speaking. The floor
    /// only forbids going back; stepping through words the voice already passed would desync text from speech.
    func testMeasuredTimingAheadOfTheEstimateLandsOnTheSpokenWordWithoutReplayingPassedWords() {
        let epoch = TeleprompterHighlightCursor.Epoch(playback: 4, text: Self.text, isReadback: false)
        let slightlyAhead = [0, 700, 1400, 2100, 2800, 3500]
        let farAhead = [0, 400, 800, 1200, 1600, 2000]
        XCTAssertEqual(Self.clockWord(Self.estimated, at: 2200), 2, "the estimate highlights charlie at 2.2 s")
        XCTAssertEqual(Self.clockWord(slightlyAhead, at: 2200), 3, "the faster measured clock says delta")
        XCTAssertEqual(Self.clockWord(farAhead, at: 2200), 5, "the much faster measured clock says foxtrot")

        for (name, measured, spoken) in [("slightly ahead", slightlyAhead, 3), ("far ahead", farAhead, 5)] {
            var cursor = TeleprompterHighlightCursor(wordID: 0, at: 0, epoch: epoch)
            cursor.land(on: Self.clockWord(Self.estimated, at: 2200), at: 2200, in: epoch)
            var shown = [cursor.wordID]
            cursor.land(on: Self.clockWord(measured, at: 2200), at: 2200, in: epoch, keepingWordOnScreen: true)
            shown.append(cursor.wordID)
            XCTAssertEqual(shown, [2, spoken], "\(name): one move, from charlie straight to the spoken word")
            XCTAssertEqual(cursor.reachedAtMilliseconds, 2200, name)

            // The new word is now the floor: a later replacement at the same clock cannot pull it back.
            cursor.land(on: Self.clockWord(Self.estimated, at: 2300), at: 2300, in: epoch, keepingWordOnScreen: true)
            XCTAssertEqual(cursor.wordID, spoken, "\(name): the word reached on measured timing is kept")
        }
    }

    func testEveryNewEpochLandsOnTheClockEvenBehindTheFloor() {
        let epoch = TeleprompterHighlightCursor.Epoch(playback: 4, text: Self.text, isReadback: false)
        let resets: [(String, TeleprompterHighlightCursor.Epoch, Int, Int)] = [
            ("new read", .init(playback: 5, text: Self.text, isReadback: false), 2200, 1),
            ("seek back", .init(playback: 5, text: Self.text, isReadback: false), 500, 0),
            ("F5-park resume at bravo", .init(playback: 5, text: Self.text, isReadback: false), 1600, 1),
            ("new text", .init(playback: 4, text: "one two three four five six", isReadback: false), 2200, 1),
            ("read-back", .init(playback: 4, text: Self.text, isReadback: true), 2200, 1),
            ("jump back inside the epoch", epoch, 1600, 1),
        ]
        for (name, next, elapsed, expected) in resets {
            var cursor = TeleprompterHighlightCursor(wordID: 0, at: 0, epoch: epoch)
            cursor.land(on: Self.clockWord(Self.estimated, at: 2200), at: 2200, in: epoch)
            XCTAssertEqual(cursor.wordID, 2, name)
            // Even when the reset arrives together with new timing, the word on screen is no floor.
            cursor.land(on: Self.clockWord(Self.measured, at: elapsed, text: next.text), at: elapsed, in: next,
                        keepingWordOnScreen: true)
            XCTAssertEqual(cursor.wordID, expected, "\(name) lands where the clock says")
            XCTAssertEqual(cursor.epoch, next, name)
        }
    }

    func testAPlainRestartInTheSameEpochFollowsTheClock() {
        let epoch = TeleprompterHighlightCursor.Epoch(playback: 1, text: Self.text, isReadback: false)
        var cursor = TeleprompterHighlightCursor(wordID: 3, at: 4500, epoch: epoch)
        cursor.land(on: 1, at: 4600, in: epoch)
        XCTAssertEqual(cursor.wordID, 1, "only a timing replacement keeps the word on screen")
    }

    // MARK: - The mounted view

    @MainActor @Observable final class Model {
        var text = TeleprompterHighlightFloorTests.text
        var boundaries = TeleprompterHighlightFloorTests.boundaries(TeleprompterHighlightFloorTests.estimated, estimate: true)
        var epoch = 0
        let playback = TeleprompterTestPlaybackClock(elapsed: 2200)
    }

    struct Host: View {
        let model: Model
        var body: some View {
            var view = TeleprompterView(text: model.text, wordBoundaries: model.boundaries, playbackEpoch: model.epoch,
                                       playbackElapsedMilliseconds: { model.playback.elapsed }, wrapWidth: 280)
            view.playbackSleep = model.playback.sleep
            return view.frame(width: 288, height: 78)
        }
    }

    /// The playback task waits for the offset of the word after the highlighted one, so the deadline it sleeps
    /// until names the highlight: 3000 ms means bravo (measured) or charlie (estimate) is on screen, 4500 ms
    /// means charlie under measured timing.
    func testMountedViewHoldsTheWordAcrossMeasuredTimingAndResetsOnEveryEpoch() async throws {
        let model = Model()
        let presentation = TeleprompterTestPresentation()
        defer { presentation.close(); model.playback.cancel() }
        let host = NSHostingView(rootView: Host(model: model))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 288, height: 78),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        func expectNext(_ deadline: Int, notAt stale: [Int] = [], _ description: String,
                        file: StaticString = #filePath, line: UInt = #line) async {
            await presentation.wait(host, clock: model.playback, for: description, file: file, line: line) { _ in
                model.playback.isSuspended(until: deadline) && !stale.contains { model.playback.isSuspended(until: $0) }
            }
        }
        func onEstimatedCharlie() async {
            model.playback.elapsed = 2200
            model.boundaries = Self.boundaries(Self.estimated, text: model.text, estimate: true)
            model.epoch += 1
            await expectNext(3000, notAt: [4500, 1500], "estimate highlights charlie, awaiting delta at 3000")
        }

        await expectNext(3000, "estimate highlights charlie on the first frame")

        // Same epoch: measured timing replaces the estimate at 2.2 s.
        model.boundaries = Self.boundaries(Self.measured, estimate: false)
        await expectNext(4500, notAt: [3000], "charlie stays; the task awaits delta's measured 4500, not charlie's 3000")
        model.playback.advance(to: 4500)
        await expectNext(6000, notAt: [4500], "measured timestamps drive the next step (delta, then echo at 6000)")

        // Same epoch, measured timing AHEAD of the estimate: the highlight moves straight to delta (the task
        // awaits echo at 2800), never re-waits for charlie's 3000 or delta's own 2100.
        await onEstimatedCharlie()
        model.boundaries = Self.boundaries([0, 700, 1400, 2100, 2800, 3500], estimate: false)
        await expectNext(2800, notAt: [3000, 2100], "measured timing ahead of the estimate lands on delta")
        await onEstimatedCharlie()
        model.boundaries = Self.boundaries(Self.measured, estimate: false)
        await expectNext(4500, notAt: [3000], "back on the slower measured timeline, charlie is the floor again")
        model.playback.advance(to: 4500)
        await expectNext(6000, notAt: [4500], "and measured timestamps drive the next step")

        // A jump back inside the epoch (the clock went back) with re-sent timing lands on the clock, bravo.
        model.playback.elapsed = 1600
        model.boundaries = Self.boundaries(Self.measured, estimate: true)
        await expectNext(3000, notAt: [6000, 4500], "a jump back inside the epoch lands on bravo")

        // New read (or resume) arriving with measured timing: lands on the measured clock, bravo.
        await onEstimatedCharlie()
        model.boundaries = Self.boundaries(Self.measured, estimate: false)
        model.epoch += 1
        await expectNext(3000, notAt: [4500], "a new epoch lands on bravo, below the old floor")

        // Seek back within the read.
        await onEstimatedCharlie()
        model.playback.elapsed = 500
        model.boundaries = Self.boundaries(Self.measured, estimate: false)
        model.epoch += 1
        await expectNext(1500, notAt: [3000, 4500], "a seek lands on alpha")

        // Resume from an F5 park at bravo: a deliberate jump to the parked word.
        await onEstimatedCharlie()
        model.playback.elapsed = 1600
        model.boundaries = Self.boundaries(Self.measured, estimate: false)
        model.epoch += 1
        await expectNext(3000, notAt: [4500], "an F5-park resume lands on the parked word bravo")

        // New text in the same playback epoch, with its own measured timing.
        await onEstimatedCharlie()
        let next = "one two three four five six"
        model.playback.elapsed = 2200
        model.text = next
        model.boundaries = Self.boundaries(Self.measured, text: next, estimate: false)
        await expectNext(3000, notAt: [4500], "new text lands on its measured clock word")

        // A timeline arriving on an empty one lands on the clock, even before the first word is due.
        await onEstimatedCharlie()
        model.boundaries = []
        // The cleared timeline cancels the playback task without scheduling another; poll for that cancel.
        for _ in 0 ..< 250 where model.playback.isSuspended(until: 3000) {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.playback.isSuspended(until: 3000), "the cleared timeline stopped the playback task")
        model.playback.elapsed = 100
        model.boundaries = Self.boundaries([300, 1500, 3000, 4500, 6000, 7500], text: model.text, estimate: false)
        await expectNext(300, notAt: [1500], "nothing is highlighted until the first word's 300 ms")
    }
}
