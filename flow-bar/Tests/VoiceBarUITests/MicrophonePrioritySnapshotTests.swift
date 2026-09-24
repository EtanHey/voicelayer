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
            "Hidden microphone selected"
        )
        XCTAssertEqual(snapshot.reorderedVisibleUIDs(moving: 1, by: -1), [
            "physical-b", "physical-a", "CADefaultDeviceAggregate-7",
        ])
    }

    /// Fold 2 review S2: one visible mic behind a saved-first aggregate has nothing to reorder, so General
    /// offers "Use visible microphones first", which keeps the hidden UIDs but moves them after the visible ones.
    func testLoneVisibleMicBehindHiddenAggregateCanBeMovedFirst() {
        let hiddenFirst = MicrophonePrioritySnapshot(rows: [
            .init(uid: "CADefaultDeviceAggregate-7", deviceID: "2", label: "System Audio", isConnected: true),
            .init(uid: "built-in", deviceID: "1", label: "MacBook Pro Microphone", isConnected: true),
        ], nextDeviceName: "System Audio")
        XCTAssertNil(hiddenFirst.reorderedVisibleUIDs(moving: 0, by: 1), "one visible row has nothing to reorder")
        XCTAssertEqual(hiddenFirst.visibleFirstUIDs, ["built-in", "CADefaultDeviceAggregate-7"])

        let visibleNext = MicrophonePrioritySnapshot(rows: hiddenFirst.rows, nextDeviceName: "MacBook Pro Microphone")
        XCTAssertNil(visibleNext.visibleFirstUIDs, "offered only while a hidden device would be used")
    }

    /// #119 Macroscope follow-up: a hidden aggregate that shares the selected physical mic's name must not make
    /// General claim "Hidden microphone selected". The snapshot compares device identity, not labels.
    func testSameNamedHiddenAggregateDoesNotHideTheSelectedPhysicalMic() {
        let rows: [MicrophonePriorityRow] = [
            .init(uid: "aggregate-uid", deviceID: "9", label: "Studio Mic", isConnected: true,
                  isVirtualOrAggregateTransport: true),
            .init(uid: "physical-uid", deviceID: "3", label: "Studio Mic", isConnected: true,
                  isVirtualOrAggregateTransport: false),
        ]
        let physicalNext = MicrophonePrioritySnapshot(
            rows: rows, nextDeviceName: "Studio Mic", nextDeviceUID: "physical-uid", nextDeviceID: "3"
        )
        XCTAssertFalse(physicalNext.nextDeviceIsHidden)
        XCTAssertEqual(physicalNext.nextVisibleDeviceName, "Studio Mic")
        XCTAssertNil(physicalNext.visibleFirstUIDs)

        let aggregateNext = MicrophonePrioritySnapshot(
            rows: rows, nextDeviceName: "Studio Mic", nextDeviceUID: "aggregate-uid", nextDeviceID: "9"
        )
        XCTAssertTrue(aggregateNext.nextDeviceIsHidden)
        XCTAssertEqual(aggregateNext.nextVisibleDeviceName, "Hidden microphone selected")

        let noUID = MicrophonePrioritySnapshot(
            rows: [.init(uid: nil, deviceID: "4", label: "Studio Mic", isConnected: true,
                         isVirtualOrAggregateTransport: false)] + rows,
            nextDeviceName: "Studio Mic", nextDeviceUID: nil, nextDeviceID: "4"
        )
        XCTAssertFalse(noUID.nextDeviceIsHidden, "a device without a UID is matched by its device ID")
    }

    func testTransportTypeOverridesNameAndNameIsOnlyFallback() {
        let namedLikeVirtual = MicrophonePriorityRow(
            uid: "physical", deviceID: "1", label: "Virtual Studio Mic", isConnected: true,
            isVirtualOrAggregateTransport: false
        )
        let unlabelledVirtual = MicrophonePriorityRow(
            uid: "zoom", deviceID: "2", label: "Studio Mic", isConnected: true,
            isVirtualOrAggregateTransport: true
        )
        let fallback = MicrophonePriorityRow(
            uid: "CADefaultDeviceAggregate-7", deviceID: nil, label: "System Audio", isConnected: false
        )
        XCTAssertFalse(namedLikeVirtual.isVirtualOrAggregate)
        XCTAssertTrue(unlabelledVirtual.isVirtualOrAggregate)
        XCTAssertTrue(fallback.isVirtualOrAggregate)
    }

    func testHiddenAggregateSavedFirstDoesNotKeepCapturingAfterVisibleReorder() throws {
        let devices = [
            MicrophoneDevice(id: "aggregate", name: "System Audio", uid: "CADefaultDeviceAggregate-7"),
            MicrophoneDevice(id: "built-in", name: "Built-in Microphone", uid: "physical-a"),
            MicrophoneDevice(id: "usb", name: "USB Microphone", uid: "physical-b"),
        ]
        let suiteName = "p07-hidden-priority-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let priority = MicrophoneDevicePriority(defaults: defaults)
        priority.observe(devices)
        let snapshot = MicrophonePrioritySnapshot(rows: priority.rows(for: devices), nextDeviceName: "System Audio")
        let reordered = snapshot.reorderedVisibleUIDs(moving: 1, by: -1)
        XCTAssertEqual(reordered, ["physical-b", "physical-a", "CADefaultDeviceAggregate-7"])
        if let reordered { priority.replacePreferredUIDs(reordered, observing: devices) }
        XCTAssertEqual(priority.resolveDeviceID(in: devices, fallbackDeviceID: "aggregate"), "usb")
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

    // MARK: - Etan's 2.2.24 review #5: "make default" on click, or drag to reorder, instead of up/up/up arrows

    private var threeMicsAndAHiddenAggregate: MicrophonePrioritySnapshot {
        MicrophonePrioritySnapshot(rows: [
            .init(uid: "mic-a", deviceID: "1", label: "Wireless Mic Rx", isConnected: true),
            .init(uid: "CADefaultDeviceAggregate-7", deviceID: "2", label: "System Audio", isConnected: true),
            .init(uid: "mic-b", deviceID: "3", label: "MacBook Pro Microphone", isConnected: true),
            .init(uid: "mic-c", deviceID: nil, label: "AirPods", isConnected: false),
        ], nextDeviceName: "Wireless Mic Rx", nextDeviceUID: "mic-a", nextDeviceID: "1")
    }

    func testMakeDefaultMovesOneRowToTheTopInOneStepAndKeepsTheRestInOrder() {
        let snapshot = threeMicsAndAHiddenAggregate
        XCTAssertEqual(snapshot.makingDefaultUIDs(at: 2), [
            "mic-c", "mic-a", "mic-b", "CADefaultDeviceAggregate-7",
        ], "one click, not two swaps; hidden devices are written after the visible ones")
        XCTAssertEqual(snapshot.makingDefaultUIDs(at: 1), ["mic-b", "mic-a", "mic-c", "CADefaultDeviceAggregate-7"])
        XCTAssertNil(snapshot.makingDefaultUIDs(at: 0), "the first row is already the default")
        XCTAssertNil(snapshot.makingDefaultUIDs(at: 3), "out of range")
    }

    func testMakeDefaultRefusesAUIDlessRow() {
        let snapshot = MicrophonePrioritySnapshot(rows: [
            .init(uid: "mic-a", deviceID: "1", label: "A", isConnected: true),
            .init(uid: nil, deviceID: "9", label: "No UID", isConnected: true),
        ], nextDeviceName: "A")
        XCTAssertNil(snapshot.makingDefaultUIDs(at: 1))
    }

    func testDragUsesOnMoveIndicesAndKeepsHiddenDevicesLast() {
        let snapshot = threeMicsAndAHiddenAggregate
        // SwiftUI onMove: destination is the index *before which* the item lands, in pre-move indices.
        XCTAssertEqual(snapshot.movingVisibleUIDs(from: IndexSet(integer: 0), to: 3), [
            "mic-b", "mic-c", "mic-a", "CADefaultDeviceAggregate-7",
        ])
        XCTAssertEqual(snapshot.movingVisibleUIDs(from: IndexSet(integer: 2), to: 0), [
            "mic-c", "mic-a", "mic-b", "CADefaultDeviceAggregate-7",
        ])
        XCTAssertEqual(
            snapshot.movingVisibleUIDs(from: IndexSet(integer: 1), to: 2),
            nil,
            "a no-op move writes nothing"
        )
    }

    func testDragNeverPlacesAMicBelowAUIDlessRow() {
        let snapshot = MicrophonePrioritySnapshot(rows: [
            .init(uid: "mic-a", deviceID: "1", label: "A", isConnected: true),
            .init(uid: "mic-b", deviceID: "2", label: "B", isConnected: true),
            .init(uid: nil, deviceID: "9", label: "No UID", isConnected: true),
        ], nextDeviceName: "A")
        XCTAssertEqual(snapshot.movingVisibleUIDs(from: IndexSet(integer: 0), to: 3), ["mic-b", "mic-a"])
        XCTAssertNil(snapshot.movingVisibleUIDs(from: IndexSet(integer: 2), to: 0), "a UID-less row cannot move")
    }

    /// P07 R2 invariant: after either gesture the saved order resolves to the new visible row 0, even with a
    /// hidden aggregate saved first.
    func testMakeDefaultAndDragBothResolveToTheNewFirstVisibleMic() throws {
        let devices = [
            MicrophoneDevice(id: "aggregate", name: "System Audio", uid: "CADefaultDeviceAggregate-7"),
            MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone", uid: "mic-a"),
            MicrophoneDevice(id: "usb", name: "USB Microphone", uid: "mic-b"),
            MicrophoneDevice(id: "rx", name: "Wireless Mic Rx", uid: "mic-c"),
        ]
        let suiteName = "r4-g1-make-default-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let priority = MicrophoneDevicePriority(defaults: defaults)
        priority.observe(devices)

        func snapshot() -> MicrophonePrioritySnapshot {
            MicrophonePrioritySnapshot(rows: priority.rows(for: devices), nextDeviceName: nil)
        }
        let madeDefault = try XCTUnwrap(snapshot().makingDefaultUIDs(at: 2))
        priority.replacePreferredUIDs(madeDefault, observing: devices)
        XCTAssertEqual(snapshot().visibleRows.first?.uid, "mic-c")
        XCTAssertEqual(priority.resolveDeviceID(in: devices, fallbackDeviceID: "aggregate"), "rx")
        XCTAssertEqual(priority.preferredUIDs.last, "CADefaultDeviceAggregate-7")

        let dragged = try XCTUnwrap(snapshot().movingVisibleUIDs(from: IndexSet(integer: 1), to: 0))
        priority.replacePreferredUIDs(dragged, observing: devices)
        XCTAssertEqual(snapshot().visibleRows.first?.uid, "mic-a")
        XCTAssertEqual(priority.resolveDeviceID(in: devices, fallbackDeviceID: "aggregate"), "built-in")
        XCTAssertEqual(priority.preferredUIDs.last, "CADefaultDeviceAggregate-7")
    }
}
