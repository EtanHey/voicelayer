@testable import VoiceBar
import VoiceBarUI
import XCTest

/// 0510 review F1: the notch Settings drawer mounts the Transcription pane with the Settings window closed. The
/// recognizer status read is gated on that pane being on screen, so the drawer must count, through the app's own
/// visibility wiring (its notch surface, its drawer context, its VoiceState).
@MainActor
final class NotchDrawerRecognizerVisibilityTests: XCTestCase {
    func testTheTranscriptionDrawerReadsRecognizerStatusWithTheWindowClosed() {
        let app = AppDelegate()
        var sent: [String] = []
        app.voiceState.sendCommand = { command in
            if let cmd = command["cmd"] as? String { sent.append(cmd) }
        }
        app.voiceState.setConnectionStatus(true)
        _ = app.notchSettingsDrawerContextForTesting() // what BarView receives
        XCTAssertNil(app.settingsWindowForTesting, "fixture: the Settings window was never opened")
        let surface = app.notchSurfaceForTesting

        surface.send(.openSettings(.general))
        XCTAssertFalse(app.voiceState.recognizerSettingsIsVisible(), "General shows no recognizer")

        surface.send(.selectSettingsTab(.transcription))
        XCTAssertTrue(app.voiceState.recognizerSettingsIsVisible(), "[F1] the mounted Transcription drawer is visible")
        sent.removeAll()
        app.voiceState.refreshRecognizerStatus()
        XCTAssertTrue(sent.contains("get_recognizer_status"), "[F1] the drawer's recognizer read is sent: \(sent)")

        surface.send(.dismiss(.escape))
        XCTAssertFalse(app.voiceState.recognizerSettingsIsVisible(), "a closed drawer reads nothing")
    }
}
