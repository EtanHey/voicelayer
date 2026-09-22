@testable import VoiceBarUI
import XCTest

final class MicrophonePrioritySnapshotTests: XCTestCase {
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
