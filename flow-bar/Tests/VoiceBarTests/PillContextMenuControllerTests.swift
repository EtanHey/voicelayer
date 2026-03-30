@testable import VoiceBar
import XCTest

final class PillContextMenuControllerTests: XCTestCase {
    func testDeviceOptionsMarkSelectedMicrophone() {
        let options = PillContextMenuController.deviceOptions(
            devices: [
                MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                MicrophoneDevice(id: "usb", name: "USB Mic"),
            ],
            selectedID: "usb"
        )

        XCTAssertEqual(options.map(\.title), [
            "MacBook Pro Microphone",
            "USB Mic",
        ])
        XCTAssertEqual(options.map(\.isSelected), [false, true])
    }

    func testPasteActionEnabledOnlyWhenTranscriptExists() {
        XCTAssertFalse(PillContextMenuController.isPasteEnabled(transcript: ""))
        XCTAssertFalse(PillContextMenuController.isPasteEnabled(transcript: "   "))
        XCTAssertTrue(PillContextMenuController.isPasteEnabled(transcript: "latest note"))
    }
}
