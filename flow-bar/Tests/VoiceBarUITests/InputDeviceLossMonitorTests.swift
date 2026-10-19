@testable import VoiceBarUI
import XCTest

/// MICDROP2: only a device that left the list or stopped being alive is a loss. A default-input
/// change alone keeps sox on a live device, so it never reaches the daemon.
final class InputDeviceLossMonitorTests: XCTestCase {
    func testOnlyARemovedOrDeadDeviceIsReported() {
        XCTAssertEqual(InputDeviceLossMonitor.lossReason(isListed: false, isAlive: false), "device-removed")
        XCTAssertEqual(InputDeviceLossMonitor.lossReason(isListed: true, isAlive: false), "device-not-alive")
        XCTAssertNil(InputDeviceLossMonitor.lossReason(isListed: true, isAlive: true))
    }
}
