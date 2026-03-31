@testable import VoiceBar
import XCTest

final class WakeRecoveryCoordinatorTests: XCTestCase {
    func testSleepResetsTransientHotkeyStateImmediately() {
        var resetCount = 0
        let coordinator = WakeRecoveryCoordinator(
            modeProvider: { .idle },
            schedule: { _, _ in },
            restartRecordingAudio: {},
            resetHotkeyState: { resetCount += 1 }
        )

        coordinator.handleWillSleep()

        XCTAssertEqual(resetCount, 1)
    }

    func testWakeSchedulesRecordingAudioRecoveryAfterHalfSecondDelay() {
        var capturedDelay: TimeInterval?
        var scheduledBlock: (() -> Void)?
        var restartCount = 0
        let coordinator = WakeRecoveryCoordinator(
            modeProvider: { .recording },
            schedule: { delay, block in
                capturedDelay = delay
                scheduledBlock = block
            },
            restartRecordingAudio: { restartCount += 1 },
            resetHotkeyState: {}
        )

        coordinator.handleDidWake()

        XCTAssertEqual(capturedDelay, 0.5)
        XCTAssertEqual(restartCount, 0)

        scheduledBlock?()

        XCTAssertEqual(restartCount, 1)
    }

    func testWakeDoesNotRestartAudioWhenNotRecording() {
        var restartCount = 0
        let coordinator = WakeRecoveryCoordinator(
            modeProvider: { .idle },
            schedule: { _, block in block() },
            restartRecordingAudio: { restartCount += 1 },
            resetHotkeyState: {}
        )

        coordinator.handleDidWake()

        XCTAssertEqual(restartCount, 0)
    }
}
