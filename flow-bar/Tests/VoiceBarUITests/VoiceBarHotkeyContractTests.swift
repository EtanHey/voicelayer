@testable import VoiceBarUI
import XCTest

final class VoiceBarHotkeyContractTests: XCTestCase {
    func testPrimaryShortcutLabelMatchesPhase2Contract() {
        XCTAssertEqual(VoiceBarHotkeyContract.primaryShortcutLabel, "F5")
    }

    // Updated 2026-06-06: "Not assigned" dated from the phase-2 F6 era when
    // double-tap was a fallback lane (#168). Current wiring routes double-tap
    // to handleHotkeyDoubleTap → lock active recording, so the settings copy
    // now advertises the real behavior.
    func testDoubleTapCopyAdvertisesRecordingLock() {
        XCTAssertEqual(
            VoiceBarHotkeyContract.doubleTapDescription,
            "Lock the active recording (hands-free)"
        )
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
