@testable import VoiceBar
import XCTest

final class VoiceBarHotkeyContractTests: XCTestCase {
    func testPrimaryShortcutLabelMatchesPhase2Contract() {
        XCTAssertEqual(VoiceBarHotkeyContract.primaryShortcutLabel, "F6")
    }

    func testDoubleTapIsNotAdvertisedAsPrimaryGesture() {
        XCTAssertEqual(VoiceBarHotkeyContract.doubleTapDescription, "Not assigned")
    }

    func testActivationLogDoesNotAdvertiseCmdF6OrDoubleTap() {
        XCTAssertEqual(
            VoiceBarHotkeyContract.activationLogMessage,
            "[VoiceBar] Hotkey system active — primary shortcut is F6"
        )
    }
}
