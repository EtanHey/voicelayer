@testable import VoiceBarUI
import XCTest

final class TeleprompterContentModelTests: XCTestCase {
    func testWordFrameUsesCallerSuppliedWrapWidth() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/VoiceBarUI/TeleprompterView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".frame(width: wrapWidth, alignment: .leading)"))
        XCTAssertTrue(source.contains(".padding(.horizontal, contentInset)"))
    }

    func testUsesDisplayTextWhilePreservingMatchingBoundaryTimings() {
        let words = TeleprompterContentModel.words(
            text: "This matches speech",
            wordBoundaries: [
                TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "This"),
                TeleprompterBoundary(offsetMs: 120, durationMs: 110, text: "matches"),
                TeleprompterBoundary(offsetMs: 250, durationMs: 120, text: "speech"),
            ]
        )

        XCTAssertEqual(words.map(\.text), ["This", "matches", "speech"])
        XCTAssertEqual(words.map(\.offsetMs), [0, 120, 250])
    }

    func testPhoneticBoundaryTokensNeverReplaceOriginalDisplayText() {
        let words = TeleprompterContentModel.words(
            text: "Etan runs supabase cmuxlayer golems and BrainLayer",
            wordBoundaries: [
                TeleprompterBoundary(offsetMs: 0, durationMs: 80, text: "Eh"),
                TeleprompterBoundary(offsetMs: 90, durationMs: 110, text: "tahn"),
                TeleprompterBoundary(offsetMs: 220, durationMs: 100, text: "runs"),
                TeleprompterBoundary(offsetMs: 340, durationMs: 90, text: "Soopa"),
                TeleprompterBoundary(offsetMs: 440, durationMs: 100, text: "base"),
                TeleprompterBoundary(offsetMs: 560, durationMs: 120, text: "cmuxlayer"),
                TeleprompterBoundary(offsetMs: 700, durationMs: 80, text: "Go"),
                TeleprompterBoundary(offsetMs: 790, durationMs: 90, text: "lems"),
                TeleprompterBoundary(offsetMs: 900, durationMs: 70, text: "and"),
                TeleprompterBoundary(offsetMs: 990, durationMs: 100, text: "Brain"),
                TeleprompterBoundary(offsetMs: 1100, durationMs: 110, text: "Layer"),
            ]
        )

        XCTAssertEqual(
            words.map(\.text),
            ["Etan", "runs", "supabase", "cmuxlayer", "golems", "and", "BrainLayer"]
        )
        XCTAssertFalse(words.map(\.text).contains("Eh"))
        XCTAssertFalse(words.map(\.text).contains("Soopa"))
        XCTAssertEqual(words.first?.offsetMs, 0)
        XCTAssertEqual(
            words.map(\.offsetMs),
            [0, 164, 327, 510, 693, 871, 1027]
        )
        XCTAssertEqual(
            zip(words.compactMap(\.offsetMs), words.compactMap(\.durationMs))
                .map(+)
                .last,
            1210
        )
        XCTAssertTrue(words.allSatisfy { ($0.durationMs ?? 0) > 0 })
        let offsets = words.compactMap(\.offsetMs)
        XCTAssertEqual(offsets.count, words.count)
        XCTAssertTrue(zip(offsets, offsets.dropFirst()).allSatisfy(<))
    }

    func testUnrelatedStaleBoundariesFallBackToEstimatedPacing() {
        let words = TeleprompterContentModel.words(
            text: "Fresh queued playback has no subtitle payload",
            wordBoundaries: [
                TeleprompterBoundary(offsetMs: 0, durationMs: 200, text: "Previous"),
                TeleprompterBoundary(offsetMs: 240, durationMs: 180, text: "item"),
                TeleprompterBoundary(offsetMs: 460, durationMs: 190, text: "timings"),
            ]
        )

        XCTAssertEqual(
            words.map(\.text),
            ["Fresh", "queued", "playback", "has", "no", "subtitle", "payload"]
        )
        XCTAssertTrue(words.allSatisfy { $0.offsetMs == nil && $0.durationMs == nil })
    }

    func testStaleBoundaryPrefixOfFreshQueuedTextFallsBackToEstimatedPacing() {
        let sharedLeadIn = String(
            repeating: "The shared queued introduction remains exactly the same ",
            count: 12
        )
        let words = TeleprompterContentModel.words(
            text: sharedLeadIn + "before a fresh ending",
            wordBoundaries: [
                TeleprompterBoundary(
                    offsetMs: 0,
                    durationMs: 5400,
                    text: sharedLeadIn
                ),
            ]
        )

        XCTAssertTrue(words.allSatisfy { $0.offsetMs == nil && $0.durationMs == nil })
    }

    func testLongStaleBoundariesThatOnlyDifferInTheMiddleFallBackToEstimatedPacing() {
        let sharedPrefix = String(repeating: "a", count: 300)
        let sharedSuffix = String(repeating: "z", count: 300)
        let displayText = sharedPrefix + String(repeating: "x", count: 1000) + sharedSuffix
        let staleBoundaryText = sharedPrefix + String(repeating: "y", count: 1000) + sharedSuffix

        let words = TeleprompterContentModel.words(
            text: displayText,
            wordBoundaries: [
                TeleprompterBoundary(
                    offsetMs: 0,
                    durationMs: 4000,
                    text: staleBoundaryText
                ),
            ]
        )

        XCTAssertEqual(words.map(\.text).joined(), displayText)
        XCTAssertTrue(words.allSatisfy { $0.offsetMs == nil && $0.durationMs == nil })
    }

    func testInitialWordUsesTopScrollPositionInsteadOfCenteringPastViewportStart() {
        XCTAssertEqual(TeleprompterScrollPolicy.position(for: 0), .top)
        XCTAssertEqual(TeleprompterScrollPolicy.position(for: 1), .center)
        XCTAssertEqual(TeleprompterScrollPolicy.initialViewportAlignment, .top)
    }

    func testNewBriefGetsFreshScrollIdentityBeforeItsFirstPaint() {
        XCTAssertNotEqual(
            TeleprompterScrollPolicy.contentIdentity(for: "first brief"),
            TeleprompterScrollPolicy.contentIdentity(for: "replacement brief")
        )
    }

    func testDismissingTeleprompterKeepsTimelineMountedButVisuallyHidden() {
        XCTAssertTrue(TeleprompterVisibilityPolicy.keepsTimelineMounted(hasText: true))
        XCTAssertEqual(TeleprompterVisibilityPolicy.timelineOpacity(isDismissed: true), 0)
        XCTAssertEqual(TeleprompterVisibilityPolicy.timelineOpacity(isDismissed: false), 1)
        XCTAssertEqual(TeleprompterVisibilityPolicy.hiddenLabelOpacity(isDismissed: true), 1)
        XCTAssertEqual(TeleprompterVisibilityPolicy.hiddenLabelOpacity(isDismissed: false), 0)
    }

    func testReadbackUsesStaticReadableScrollablePresentation() {
        XCTAssertFalse(TeleprompterPlaybackPolicy.animatesTimeline(isReadback: true))
        XCTAssertEqual(TeleprompterPlaybackPolicy.wordOpacity(isReadback: true), 0.9)
        XCTAssertTrue(TeleprompterPlaybackPolicy.showsScrollIndicators(isReadback: true))
    }

    func testLivePlaybackKeepsAnimatedHighlightPresentation() {
        XCTAssertTrue(TeleprompterPlaybackPolicy.animatesTimeline(isReadback: false))
        XCTAssertNil(TeleprompterPlaybackPolicy.wordOpacity(isReadback: false))
        XCTAssertFalse(TeleprompterPlaybackPolicy.showsScrollIndicators(isReadback: false))
        XCTAssertEqual(TeleprompterPlaybackPolicy.startupDelay, .zero)
    }

    func testRemountedTimelineProjectsHighlightFromCurrentPlaybackPosition() {
        let words = [
            TeleprompterWord(id: 0, text: "zero", offsetMs: 0, durationMs: 300),
            TeleprompterWord(id: 1, text: "one", offsetMs: 400, durationMs: 300),
            TeleprompterWord(id: 2, text: "two", offsetMs: 800, durationMs: 300),
            TeleprompterWord(id: 3, text: "three", offsetMs: 1200, durationMs: 300),
        ]

        XCTAssertEqual(
            TeleprompterPlaybackPolicy.currentWordIndex(
                in: words,
                elapsedMilliseconds: 1250
            ),
            3
        )
    }

    func testRemountedEstimatedTimelineAlsoProjectsFromElapsedPlayback() {
        let words = [
            TeleprompterWord(id: 0, text: "one", offsetMs: nil, durationMs: nil),
            TeleprompterWord(id: 1, text: "two", offsetMs: nil, durationMs: nil),
            TeleprompterWord(id: 2, text: "three", offsetMs: nil, durationMs: nil),
        ]
        let firstTwoWordsMilliseconds = Int(
            ((TeleprompterPacePolicy.estimatedDelay(for: "one") +
                    TeleprompterPacePolicy.estimatedDelay(for: "two")) * 1000).rounded()
        )

        XCTAssertEqual(
            TeleprompterPlaybackPolicy.currentWordIndex(
                in: words,
                elapsedMilliseconds: firstTwoWordsMilliseconds + 1
            ),
            2
        )
    }

    func testPartialTimestampPayloadUsesOneEstimatedTimeline() {
        let words = [
            TeleprompterWord(id: 0, text: "one", offsetMs: 0, durationMs: 200),
            TeleprompterWord(id: 1, text: "two", offsetMs: nil, durationMs: nil),
            TeleprompterWord(id: 2, text: "three", offsetMs: 700, durationMs: 200),
        ]

        XCTAssertFalse(TeleprompterPlaybackPolicy.usesServerTimestamps(in: words))
        XCTAssertEqual(
            TeleprompterPlaybackPolicy.currentWordIndex(
                in: words,
                elapsedMilliseconds: 660
            ),
            2
        )
    }

    func testTeleprompterMountConsumesVoiceStatesAbsolutePlaybackClock() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let teleprompterSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/VoiceBarUI/TeleprompterView.swift"),
            encoding: .utf8
        )
        let barViewSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(teleprompterSource.contains("public let playbackElapsedMilliseconds: () -> Int"))
        XCTAssertTrue(teleprompterSource.contains("elapsedMilliseconds: playbackElapsedMilliseconds()"))
        XCTAssertTrue(teleprompterSource.contains("_currentIndex = State(initialValue: initialWordIndex)"))
        XCTAssertTrue(barViewSource.contains("playbackElapsedMilliseconds: state.playbackElapsedMilliseconds"))
    }

    func testSpeakingContentRemovesImmediatelyAndIdleContentAppearsImmediately() {
        XCTAssertFalse(
            VoiceBarContentTransitionPolicy.insertionUsesCrossFade(from: .speaking, to: .idle)
        )
        for sourceMode in VoiceMode.allCases where sourceMode != .speaking {
            XCTAssertTrue(
                VoiceBarContentTransitionPolicy.insertionUsesCrossFade(
                    from: sourceMode,
                    to: .idle
                ),
                "\(sourceMode) → idle must retain the normal cross-fade"
            )
        }
        for destinationMode in VoiceMode.allCases where destinationMode != .idle {
            XCTAssertTrue(
                VoiceBarContentTransitionPolicy.insertionUsesCrossFade(
                    from: .speaking,
                    to: destinationMode
                ),
                "Only speaking → idle may bypass insertion cross-fade"
            )
        }

        XCTAssertFalse(
            VoiceBarContentTransitionPolicy.removalUsesCrossFade(forContentMode: .speaking)
        )
        XCTAssertTrue(VoiceBarContentTransitionPolicy.removalUsesCrossFade(forContentMode: .idle))
        XCTAssertTrue(VoiceBarContentTransitionPolicy.removalUsesCrossFade(forContentMode: .recording))
        XCTAssertTrue(VoiceBarContentTransitionPolicy.removalUsesCrossFade(forContentMode: .transcribing))
        XCTAssertTrue(VoiceBarContentTransitionPolicy.removalUsesCrossFade(forContentMode: .error))
        XCTAssertTrue(VoiceBarContentTransitionPolicy.removalUsesCrossFade(forContentMode: .disconnected))
    }

    func testVoiceStateRetainsTheSourceModeForDestinationTransitionPolicy() {
        let state = VoiceState()
        state.mode = .transcribing
        state.mode = .idle

        XCTAssertEqual(state.previousMode, .transcribing)
    }

    func testFiltersEmptyBoundaryTokensBeforeDrivingHighlighting() {
        let words = TeleprompterContentModel.words(
            text: "Hello world",
            wordBoundaries: [
                TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "Hello"),
                TeleprompterBoundary(offsetMs: 120, durationMs: 110, text: " "),
                TeleprompterBoundary(offsetMs: 250, durationMs: 120, text: ""),
                TeleprompterBoundary(offsetMs: 380, durationMs: 130, text: "world"),
            ]
        )

        XCTAssertEqual(words.map(\.text), ["Hello", "world"])
        XCTAssertEqual(words.map(\.offsetMs), [0, 380])
    }

    func testFallsBackToTextSplittingWhenNoBoundaryWordsExist() {
        let words = TeleprompterContentModel.words(
            text: "three visible lines",
            wordBoundaries: []
        )

        XCTAssertEqual(words.map(\.text), ["three", "visible", "lines"])
        XCTAssertEqual(words.map(\.offsetMs), [nil, nil, nil])
    }

    func testSplitsLongUnspacedTokensSoTheyCanWrapInsideViewport() {
        let words = TeleprompterContentModel.words(
            text: "SupercalifragilisticexpialidociousShouldNotClip",
            wordBoundaries: []
        )

        XCTAssertGreaterThan(words.count, 1)
        XCTAssertEqual(words.map(\.text).joined(), "SupercalifragilisticexpialidociousShouldNotClip")
        XCTAssertTrue(words.allSatisfy { $0.text.count <= TeleprompterContentModel.maxDisplayTokenLength })
    }
}
