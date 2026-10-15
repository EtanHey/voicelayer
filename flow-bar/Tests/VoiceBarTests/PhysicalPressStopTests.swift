@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class PhysicalPressStopTests: XCTestCase {
    func testNativeF5LockedStopCarriesPhysicalPressFlag() { checkLockedStop(mouse: false) }
    func testNativeMouseFiveLockedStopCarriesPhysicalPressFlag() { checkLockedStop(mouse: true) }

    private func checkLockedStop(mouse: Bool) {
        let app = AppDelegate()
        app.externalStartCommandGraceDeadline = nil
        app.hotkeyEnabled = true
        app.voiceState.isConnected = true
        app.voiceState.frontmostAppProvider = { nil }
        var sent: [[String: Any]] = []
        app.voiceState.sendCommand = { sent.append($0) }
        app.configureHotkeyCallbacksForTesting()
        for _ in 0 ..< (mouse ? 1 : 2) {
            if mouse {
                app.handleHotkeyMouseDown(from: .native)
                app.handleHotkeyMouseUp(from: .native)
            } else {
                app.handleHotkeyKeyDown(from: .native)
                app.handleHotkeyKeyUp(from: .native)
            }
        }
        app.voiceState.handleEvent(["type": "state", "state": "recording", "bar_owned": true, "mode": "ptt"])
        if mouse { app.handleHotkeyMouseDown(from: .native) }
        else { app.handleHotkeyKeyDown(from: .native) }
        XCTAssertEqual(sent.last?["cmd"] as? String, "stop")
        XCTAssertEqual(sent.last?["physical_press"] as? Bool, true)
    }

    func testOrdinaryStopRemoteAskAndVADNeverSendPhysicalPressFlag() {
        for scenario in ["legacy", "ask", "vad", "speaking"] {
            let state = VoiceState()
            state.frontmostAppProvider = { nil }
            state.isConnected = true
            var sent: [[String: Any]] = []
            state.sendCommand = { sent.append($0) }
            state.record(pressToTalk: true)
            state.handleEvent(["type": "state", "state": "recording", "bar_owned": scenario != "ask",
                               "mode": scenario == "vad" ? "vad" : "ptt"])
            if scenario == "speaking" { state.mode = .speaking }
            state.stop(physicalPress: scenario != "legacy")
            XCTAssertNil(sent.last?["physical_press"], scenario)
        }
    }
}
