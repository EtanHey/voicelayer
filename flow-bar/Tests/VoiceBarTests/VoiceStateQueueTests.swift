@testable import VoiceBar
import XCTest

final class VoiceStateQueueTests: XCTestCase {
    func testHandleQueueStoresOrderedItemsAndProgress() {
        let state = VoiceState()

        state.handleEvent([
            "type": "queue",
            "depth": 2,
            "items": [
                [
                    "text": "Current line",
                    "voice": "jenny",
                    "priority": "normal",
                    "is_current": true,
                    "progress": 0.35,
                ],
                [
                    "text": "Queued line",
                    "voice": "jenny",
                    "priority": "high",
                    "is_current": false,
                    "progress": 0.0,
                ],
            ],
        ])

        XCTAssertEqual(state.queueDepth, 2)
        XCTAssertEqual(state.queueItems.count, 2)
        XCTAssertEqual(state.queueItems[0].text, "Current line")
        XCTAssertTrue(state.queueItems[0].isCurrent)
        XCTAssertEqual(state.queueItems[0].progress, 0.35, accuracy: 0.001)
        XCTAssertEqual(state.queueItems[1].text, "Queued line")
        XCTAssertFalse(state.queueItems[1].isCurrent)
        XCTAssertEqual(state.queueItems[1].progress, 0.0, accuracy: 0.001)
    }

    func testHandleQueueClampsInvalidProgress() {
        let state = VoiceState()

        state.handleEvent([
            "type": "queue",
            "depth": 1,
            "items": [
                [
                    "text": "Current line",
                    "voice": "jenny",
                    "priority": "normal",
                    "is_current": true,
                    "progress": 1.8,
                ],
            ],
        ])

        XCTAssertEqual(state.queueItems[0].progress, 1.0, accuracy: 0.001)
    }

    func testIdlePlaybackClearsQueueItems() {
        let state = VoiceState()

        state.handleEvent([
            "type": "queue",
            "depth": 2,
            "items": [
                [
                    "text": "Current line",
                    "voice": "jenny",
                    "priority": "normal",
                    "is_current": true,
                    "progress": 0.5,
                ],
            ],
        ])

        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        XCTAssertEqual(state.queueDepth, 0)
        XCTAssertTrue(state.queueItems.isEmpty)
    }
}
