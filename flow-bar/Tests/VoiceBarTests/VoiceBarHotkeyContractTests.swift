@testable import VoiceBar
import XCTest

final class VoiceBarHotkeyContractTests: XCTestCase {
    func testPrimaryShortcutLabelMatchesPhase2Contract() {
        XCTAssertEqual(VoiceBarHotkeyContract.primaryShortcutLabel, "F5")
    }

    func testDoubleTapIsNotAdvertisedAsPrimaryGesture() {
        XCTAssertEqual(VoiceBarHotkeyContract.doubleTapDescription, "Not assigned")
    }

    func testRepasteShortcutUsesShiftF5() {
        XCTAssertEqual(VoiceBarHotkeyContract.repasteShortcutLabel, "Shift+F5")
    }

    func testActivationLogDoesNotAdvertiseCmdF5OrDoubleTap() {
        XCTAssertEqual(
            VoiceBarHotkeyContract.activationLogMessage,
            "[VoiceBar] Hotkey system active — primary shortcut is F5"
        )
    }
}
