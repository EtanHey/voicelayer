@testable import VoiceBarUI
import XCTest

/// MICDROP2: only this capture's device leaving the list or dying is a loss, and only when that
/// device is known: a default-input move near the capture start leaves sox's device ambiguous.
final class InputDeviceLossMonitorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testOnlyARemovedOrDeadDeviceIsReported() {
        let binding = InputDeviceLossBinding(captureID: 7, deviceID: 81, startedAt: start, lastDefaultInputChange: nil)
        XCTAssertEqual(binding.lossReason(isListed: false, isAlive: false), "device-removed")
        XCTAssertEqual(binding.lossReason(isListed: true, isAlive: false), "device-not-alive")
        XCTAssertNil(binding.lossReason(isListed: true, isAlive: true))
    }

    /// Sol R1 #3: default A -> B around the start, sox on B, A removed later. Never report.
    func testADefaultMoveAroundTheStartNeverReports() {
        let before = InputDeviceLossBinding(
            captureID: 7, deviceID: 81, startedAt: start, lastDefaultInputChange: start.addingTimeInterval(-0.5)
        )
        XCTAssertNil(before.lossReason(isListed: false, isAlive: false))

        var after = InputDeviceLossBinding(captureID: 7, deviceID: 81, startedAt: start, lastDefaultInputChange: nil)
        after.defaultInputChanged(at: start.addingTimeInterval(0.4))
        XCTAssertTrue(after.ambiguous)
        XCTAssertNil(after.lossReason(isListed: false, isAlive: false))
    }

    /// Sol R2 #1, sox on B after a startup move A -> B, then A is removed. Default-input callback
    /// first: ambiguous, nothing sent. Device-list callback first: A is reported. The daemon takes that
    /// report as evidence only (MICDROP3), so neither order can stop the healthy capture on B.
    func testBothCallbackOrdersOfAStartupMove() {
        var defaultFirst = InputDeviceLossBinding(captureID: 7, deviceID: 81, startedAt: start, lastDefaultInputChange: nil)
        defaultFirst.defaultInputChanged(at: start.addingTimeInterval(0.1))
        XCTAssertNil(defaultFirst.lossReason(isListed: false, isAlive: false))

        let listFirst = InputDeviceLossBinding(captureID: 7, deviceID: 81, startedAt: start, lastDefaultInputChange: nil)
        XCTAssertEqual(listFirst.lossReason(isListed: false, isAlive: false), "device-removed")
    }

    /// A default move well clear of the start does not move sox: its device's removal is still a loss.
    func testADefaultMoveClearOfTheStartKeepsTheBinding() {
        var binding = InputDeviceLossBinding(
            captureID: 7, deviceID: 81, startedAt: start, lastDefaultInputChange: start.addingTimeInterval(-30)
        )
        binding.defaultInputChanged(at: start.addingTimeInterval(10))
        XCTAssertFalse(binding.ambiguous)
        XCTAssertEqual(binding.lossReason(isListed: false, isAlive: false), "device-removed")
    }

}
