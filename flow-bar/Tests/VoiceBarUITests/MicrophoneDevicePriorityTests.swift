@testable import VoiceBarUI
import XCTest

final class MicrophoneDevicePriorityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MicrophoneDevicePriorityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPreferredUIDOrderSurvivesChangedTransientDeviceIDs() {
        let initial = [
            device(id: "12", name: "Built-in", uid: "uid.builtin"),
            device(id: "42", name: "USB", uid: "uid.usb"),
        ]
        let priority = makePriority()
        priority.replacePreferredUIDs(["uid.usb", "uid.builtin"], observing: initial)

        let restored = makePriority()
        let reconnected = [
            device(id: "900", name: "USB", uid: "uid.usb"),
            device(id: "901", name: "Built-in", uid: "uid.builtin"),
        ]

        XCTAssertEqual(restored.preferredUIDs, ["uid.usb", "uid.builtin"])
        XCTAssertEqual(restored.resolveDeviceID(in: reconnected, fallbackDeviceID: "901"), "900")
    }

    func testDisconnectedRowIsRetainedAndReconnectsByUID() throws {
        let priority = makePriority()
        let connected = [device(id: "42", name: "Studio USB", uid: "uid.usb")]
        priority.replacePreferredUIDs(["uid.usb"], observing: connected)

        let disconnected = try XCTUnwrap(priority.rows(for: []).first)
        XCTAssertEqual(disconnected.uid, "uid.usb")
        XCTAssertEqual(disconnected.label, "Studio USB")
        XCTAssertFalse(disconnected.isConnected)
        XCTAssertNil(disconnected.deviceID)

        let reconnected = try XCTUnwrap(priority.rows(for: [
            device(id: "77", name: "Studio USB", uid: "uid.usb"),
        ]).first)
        XCTAssertTrue(reconnected.isConnected)
        XCTAssertEqual(reconnected.deviceID, "77")
    }

    func testDuplicateUIDsAreDedupedInStoredOrderAndRows() {
        let priority = makePriority()
        let devices = [
            device(id: "1", name: "USB First", uid: "uid.usb"),
            device(id: "2", name: "USB Duplicate", uid: "uid.usb"),
        ]
        priority.replacePreferredUIDs(["uid.usb", "uid.usb", "", "uid.usb"], observing: devices)

        XCTAssertEqual(priority.preferredUIDs, ["uid.usb"])
        XCTAssertEqual(priority.rows(for: devices).map(\.uid), ["uid.usb"])
        XCTAssertEqual(priority.resolveDeviceID(in: devices, fallbackDeviceID: nil), "1")
    }

    func testNonPreferredConnectedRowsFollowDeviceInputOrder() {
        let priority = makePriority()
        let devices = (0 ..< 12).map { index in
            device(id: String(index), name: "Microphone \(index)", uid: "uid.\(index)")
        }

        XCTAssertEqual(priority.rows(for: devices).map(\.uid), devices.map(\.uid))
    }

    func testFallsBackToCurrentDefaultWhenNoPreferredUIDIsAvailable() {
        let priority = makePriority()
        priority.replacePreferredUIDs(["uid.disconnected"], observing: [
            device(id: "8", name: "Known", uid: "uid.disconnected"),
        ])

        XCTAssertEqual(
            priority.resolveDeviceID(
                in: [device(id: "19", name: "Current", uid: "uid.current")],
                fallbackDeviceID: "19"
            ),
            "19"
        )
    }

    func testMissingUIDIsConnectedButCannotBePersistedAsPriority() throws {
        let priority = makePriority()
        let missingUID = device(id: "314", name: "Unknown identity", uid: nil)
        priority.replacePreferredUIDs(["314", ""], observing: [missingUID])

        XCTAssertEqual(priority.preferredUIDs, [])
        let row = try XCTUnwrap(priority.rows(for: [missingUID]).first)
        XCTAssertNil(row.uid)
        XCTAssertEqual(row.deviceID, "314")
        XCTAssertTrue(row.isConnected)
        XCTAssertFalse(row.canPrioritize)
        XCTAssertNil(priority.resolveDeviceID(in: [missingUID], fallbackDeviceID: nil))
    }

    func testMissingUIDReplacementPreservesSeededStableOrder() {
        let priority = makePriority()
        priority.replacePreferredUIDs(["uid.usb"], observing: [
            device(id: "42", name: "USB", uid: "uid.usb"),
        ])

        priority.replacePreferredUIDs(["314"], observing: [
            device(id: "314", name: "Unknown identity", uid: nil),
        ])

        XCTAssertEqual(priority.preferredUIDs, ["uid.usb"])
    }

    func testExplicitEmptyReplacementClearsSeededStableOrder() {
        let priority = makePriority()
        priority.replacePreferredUIDs(["uid.usb"], observing: [
            device(id: "42", name: "USB", uid: "uid.usb"),
        ])

        priority.replacePreferredUIDs([], observing: [])

        XCTAssertEqual(priority.preferredUIDs, [])
    }

    func testResolutionReturnsPreferredConnectedDeviceID() {
        let priority = makePriority()
        priority.replacePreferredUIDs(["uid.usb"], observing: [
            device(id: "42", name: "USB", uid: "uid.usb"),
        ])
        let resolution = priority.resolveDeviceID(
            in: [device(id: "77", name: "USB", uid: "uid.usb")],
            fallbackDeviceID: nil
        )

        XCTAssertEqual(resolution, "77")
    }

    private func makePriority() -> MicrophoneDevicePriority {
        MicrophoneDevicePriority(defaults: defaults, storageNamespace: "test.microphone.priority")
    }

    private func device(id: String, name: String, uid: String?) -> MicrophoneDevice {
        MicrophoneDevice(id: id, name: name, uid: uid)
    }
}
