@testable import VoiceBarUI
import XCTest

/// Device inventory, resolution and the default-input writer are all injected. These tests must
/// never enumerate CoreAudio devices, open a microphone, or read/write microphone preferences.
final class MicrophonePriorityTransientTests: XCTestCase {
    private let builtIn = MicrophoneDevice(id: "1", name: "Built-in Mic", uid: "physical.built-in",
                                          isVirtualOrAggregateTransport: false)
    private let usb = MicrophoneDevice(id: "2", name: "USB Mic", uid: "physical.usb",
                                      isVirtualOrAggregateTransport: false)

    func testTransientAggregateAppearingDuringCaptureAndDisappearingAtIdleNeverApplies() {
        let aggregate = MicrophoneDevice(id: "90", name: "Capture Mic", uid: "CADefaultDeviceAggregate-123-0")
        var applied: [String] = []
        let coordinator = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: { "1" },
            applyDeviceID: { applied.append($0); return true }
        )
        coordinator.availableDevicesDidChange([builtIn], mode: .idle, captureLive: false)
        XCTAssertEqual(applied, ["1"], "consume the initial inventory apply before capture")
        applied.removeAll()

        coordinator.availableDevicesDidChange([builtIn, aggregate], mode: .recording, captureLive: true)
        coordinator.modeDidChange(.idle, captureLive: true)
        coordinator.modeDidChange(.transcribing, captureLive: false)
        XCTAssertTrue(applied.isEmpty)
        coordinator.modeDidChange(.idle, captureLive: false)
        XCTAssertTrue(applied.isEmpty, "aggregate appearance must not arm a deferred apply")
        coordinator.availableDevicesDidChange([builtIn], mode: .idle, captureLive: false)
        XCTAssertTrue(applied.isEmpty, "aggregate disappearance must not apply either")
    }

    func testHiddenDeviceChurnUsesTheSameRuleAsThePriorityUI() {
        let hiddenDevices: [MicrophoneDevice] = [
            .init(id: "90", name: "Capture Mic", uid: "CADefaultDeviceAggregate-123-0"),
            .init(id: "91", name: "Studio Input", uid: "opaque.uid", isVirtualOrAggregateTransport: true),
            .init(id: "92", name: "BlackHole 2ch", uid: "loopback.uid"),
            .init(id: "93", name: "Microsoft Teams Audio", uid: "MSTeamsAudioDevice_UID"),
            .init(id: "94", name: "User Aggregate", uid: "aggregate.uid"),
        ]
        var applied: [String] = []
        let coordinator = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: { "1" },
            applyDeviceID: { applied.append($0); return true }
        )
        coordinator.availableDevicesDidChange([builtIn], mode: .idle, captureLive: false)
        applied.removeAll()

        for device in hiddenDevices {
            let row = MicrophonePriorityRow(uid: device.uid, deviceID: device.id, label: device.name,
                                            isConnected: true,
                                            isVirtualOrAggregateTransport: device.isVirtualOrAggregateTransport)
            XCTAssertTrue(row.isVirtualOrAggregate)
            coordinator.availableDevicesDidChange([device, builtIn], mode: .idle, captureLive: false)
            coordinator.availableDevicesDidChange([builtIn], mode: .idle, captureLive: false)
            XCTAssertTrue(applied.isEmpty, "hidden inventory churn: \(device.uid ?? device.name)")
        }
    }

    func testRealConnectAndDisconnectApplyOnlyAfterCaptureEnds() {
        var resolvedID = "1"
        var applied: [String] = []
        let coordinator = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: { resolvedID },
            applyDeviceID: { applied.append($0); return true }
        )
        coordinator.availableDevicesDidChange([builtIn], mode: .idle, captureLive: false)
        applied.removeAll()

        resolvedID = "2"
        coordinator.availableDevicesDidChange([builtIn, usb], mode: .recording, captureLive: true)
        coordinator.modeDidChange(.idle, captureLive: true)
        coordinator.modeDidChange(.transcribing, captureLive: false)
        XCTAssertTrue(applied.isEmpty)
        coordinator.modeDidChange(.idle, captureLive: false)
        XCTAssertEqual(applied, ["2"])

        resolvedID = "1"
        coordinator.availableDevicesDidChange([builtIn], mode: .idle, captureLive: true)
        XCTAssertEqual(applied, ["2"], "idle alone is insufficient while capture is live")
        coordinator.modeDidChange(.idle, captureLive: false)
        XCTAssertEqual(applied, ["2", "1"])
        coordinator.availableDevicesDidChange([builtIn], mode: .idle, captureLive: false)
        XCTAssertEqual(applied, ["2", "1"], "unchanged real inventory does not reapply")
    }

    func testKnownPhysicalTransportRemainsPickableDespiteVirtualLookingName() {
        let physical = MicrophoneDevice(id: "3", name: "Virtual Studio Mic", uid: "physical.studio",
                                        isVirtualOrAggregateTransport: false)
        var applied: [String] = []
        let coordinator = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: { "3" },
            applyDeviceID: { applied.append($0); return true }
        )
        coordinator.availableDevicesDidChange([builtIn], mode: .idle, captureLive: false)
        applied.removeAll()
        coordinator.availableDevicesDidChange([builtIn, physical], mode: .idle, captureLive: false)
        XCTAssertEqual(applied, ["3"], "honor transport metadata just like the UI")
    }

    func testHiddenChurnDoesNotDiscardAnExplicitPendingApply() {
        let aggregate = MicrophoneDevice(id: "90", name: "Capture Mic", uid: "CADefaultDeviceAggregate-123-0")
        var applied: [String] = []
        let coordinator = MicrophonePriorityApplyCoordinator(
            resolveDeviceID: { "2" },
            applyDeviceID: { applied.append($0); return true }
        )
        coordinator.availableDevicesDidChange([builtIn], mode: .idle, captureLive: false)
        applied.removeAll()
        coordinator.requestApply(mode: .recording, captureLive: true)
        coordinator.availableDevicesDidChange([builtIn, aggregate], mode: .recording, captureLive: true)
        coordinator.availableDevicesDidChange([builtIn], mode: .transcribing, captureLive: false)
        XCTAssertTrue(applied.isEmpty)
        coordinator.modeDidChange(.idle, captureLive: false)
        XCTAssertEqual(applied, ["2"])
    }
}
