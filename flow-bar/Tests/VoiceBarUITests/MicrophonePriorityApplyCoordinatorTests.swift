@testable import VoiceBarUI
import XCTest

final class MicrophonePriorityApplyCoordinatorTests: XCTestCase {
    func testDefersThroughCaptureBootingRecordingAndTranscriptionThenResolvesAtIdle() {
        var resolvedID = "old-device"
        var applied: [String] = []
        let coordinator = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: { resolvedID },
            applyDeviceID: { applied.append($0)
                return true
            }
        )

        coordinator.requestApply(mode: .recording, captureLive: false)
        coordinator.modeDidChange(.recording, captureLive: true)
        coordinator.modeDidChange(.transcribing, captureLive: false)
        coordinator.modeDidChange(.speaking, captureLive: false)
        XCTAssertTrue(applied.isEmpty)

        resolvedID = "new-device"
        coordinator.modeDidChange(.idle, captureLive: false)
        XCTAssertEqual(applied, ["new-device"])
        coordinator.modeDidChange(.idle, captureLive: false)
        XCTAssertEqual(applied, ["new-device"])
    }

    func testUnavailableResolutionDoesNotApplyAndCanRetry() {
        var resolvedID: String?
        var applied: [String] = []
        let coordinator = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: { resolvedID },
            applyDeviceID: { applied.append($0)
                return true
            }
        )
        coordinator.requestApply(mode: .idle, captureLive: false)
        XCTAssertTrue(applied.isEmpty)
        resolvedID = "connected-device"
        coordinator.modeDidChange(.idle, captureLive: false)
        XCTAssertEqual(applied, ["connected-device"])
    }

    func testFailedDefaultChangeRemainsPendingUntilIdleRetry() {
        var attempts = 0
        let coordinator = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: { "uid-resolved-device" },
            applyDeviceID: { _ in
                attempts += 1
                return attempts > 1
            }
        )
        coordinator.requestApply(mode: .idle, captureLive: false)
        XCTAssertEqual(attempts, 1)
        coordinator.modeDidChange(.recording, captureLive: false)
        XCTAssertEqual(attempts, 1)
        coordinator.modeDidChange(.idle, captureLive: false)
        XCTAssertEqual(attempts, 2)
    }

    func testPlaybackToRecordingIdleDoesNotReleasePendingApply() {
        let state = VoiceState()
        var applied: [String] = []
        let coordinator = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: { "next-device" },
            applyDeviceID: { applied.append($0)
                return true
            }
        )
        state.onModeChange = { mode in
            coordinator.modeDidChange(
                mode,
                captureLive: state.captureLive || state.isRecordingHandoffPending
            )
        }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "state", "state": "speaking"])
        coordinator.requestApply(mode: .speaking, captureLive: false)
        state.handleEvent([
            "type": "state", "state": "idle", "source": "playback", "next_state": "recording",
        ])
        XCTAssertEqual(state.mode, .idle)
        XCTAssertTrue(state.isRecordingHandoffPending)
        XCTAssertTrue(applied.isEmpty)

        state.handleEvent(["type": "state", "state": "recording", "bar_owned": false])
        XCTAssertFalse(state.isRecordingHandoffPending)
        XCTAssertTrue(applied.isEmpty)
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        XCTAssertEqual(applied, ["next-device"])
    }

    func testDisconnectedPreferenceAppliesAfterReconnectEvenAfterFallbackSucceeded() throws {
        let suite = "MicrophonePriorityReconnect.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let priority = MicrophoneDevicePriority(defaults: defaults)
        let deviceA = MicrophoneDevice(id: "1", name: "A", uid: "uid.a")
        let deviceB = MicrophoneDevice(id: "2", name: "B", uid: "uid.b")
        priority.replacePreferredUIDs(["uid.b", "uid.a"], observing: [deviceA, deviceB])

        var available = [deviceA]
        var systemDefault = "1"
        var applied: [String] = []
        let coordinator = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: {
                priority.resolveDeviceID(in: available, fallbackDeviceID: systemDefault)
            },
            applyDeviceID: { id in
                applied.append(id)
                systemDefault = id
                return true
            }
        )
        coordinator.requestApply(mode: .idle, captureLive: false)
        XCTAssertEqual(systemDefault, "1")

        available = [deviceA, deviceB]
        coordinator.availableDevicesDidChange(available, mode: .idle, captureLive: false)
        let displayedNextID = priority.resolveDeviceID(
            in: available, fallbackDeviceID: systemDefault
        )
        XCTAssertEqual(displayedNextID, "2")
        XCTAssertEqual(systemDefault, displayedNextID)
        XCTAssertEqual(applied, ["1", "2"])
        coordinator.availableDevicesDidChange(available, mode: .idle, captureLive: false)
        XCTAssertEqual(applied, ["1", "2"])
    }
}
