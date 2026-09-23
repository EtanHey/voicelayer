@testable import VoiceBarUI
import XCTest

final class MicrophonePrioritySnapshotTests: XCTestCase {
    func testGeneralHidesVirtualRowsWithoutDroppingTheirSavedPriority() {
        let snapshot = MicrophonePrioritySnapshot(rows: [
            .init(uid: "physical-a", deviceID: "1", label: "Built-in Microphone", isConnected: true),
            .init(uid: "CADefaultDeviceAggregate-7", deviceID: "2", label: "System Audio", isConnected: true),
            .init(uid: "physical-b", deviceID: "3", label: "USB Microphone", isConnected: true),
        ], nextDeviceName: "Built-in Microphone")

        XCTAssertEqual(snapshot.visibleRows.map(\.label), ["Built-in Microphone", "USB Microphone"])
        XCTAssertEqual(snapshot.nextVisibleDeviceName, "Built-in Microphone")
        XCTAssertEqual(
            MicrophonePrioritySnapshot(rows: snapshot.rows, nextDeviceName: "System Audio").nextVisibleDeviceName,
            "System selected device"
        )
        XCTAssertEqual(snapshot.reorderedVisibleUIDs(moving: 1, by: -1), [
            "physical-b", "CADefaultDeviceAggregate-7", "physical-a",
        ])
    }

    func testReorderIncludesRememberedDisconnectedUIDAndExcludesUIDlessDevice() {
        let snapshot = MicrophonePrioritySnapshot(rows: [
            .init(uid: "uid.connected", deviceID: "12", label: "Connected", isConnected: true),
            .init(uid: "uid.remembered", deviceID: nil, label: "Remembered", isConnected: false),
            .init(uid: nil, deviceID: "88", label: "No UID", isConnected: true),
        ], nextDeviceName: "Connected")

        XCTAssertEqual(snapshot.reorderedUIDs(moving: 1, by: -1), ["uid.remembered", "uid.connected"])
        XCTAssertNil(snapshot.reorderedUIDs(moving: 2, by: -1))
        XCTAssertNil(snapshot.reorderedUIDs(moving: 1, by: 1))
    }
}
