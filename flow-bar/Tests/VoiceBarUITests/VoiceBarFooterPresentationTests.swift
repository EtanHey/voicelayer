@testable import VoiceBarUI
import XCTest

final class VoiceBarFooterPresentationTests: XCTestCase {
    func testConnectedFooterWaitsForFreshModelsHealthAndResetsAfterDisconnect() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).status, "Starting…")

        state.handleEvent([
            "type": "health",
            "recording_state": "idle",
            "model_status": [
                "configured_model": ["name": "large-v3-turbo", "installed": true],
                "residency": "not_loaded",
                "configured_effort": "accurate",
            ],
        ])
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).status, "Ready")

        state.setConnectionStatus(false)
        state.setConnectionStatus(true)
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).status, "Starting…")
    }

    func testHealthPrivacyIsClearedAcrossDaemonConnections() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "remote_stt_configured": true])
        XCTAssertEqual(state.remoteSTTConfigured, true)
        state.setConnectionStatus(false)
        XCTAssertNil(state.remoteSTTConfigured)
        state.setConnectionStatus(true)
        XCTAssertNil(state.remoteSTTConfigured)
        state.handleEvent(["type": "health", "remote_stt_configured": false])
        XCTAssertEqual(state.remoteSTTConfigured, false)
    }

    func testStatusRequiresConnectedIdleState() {
        XCTAssertEqual(
            VoiceBarFooterPresentation
                .resolve(isConnected: false, mode: .idle, captureLive: false, errorMessage: nil,
                         remoteSTTConfigured: false).status,
            "Disconnected"
        )
        XCTAssertEqual(
            VoiceBarFooterPresentation
                .resolve(isConnected: true, mode: .recording, captureLive: false, errorMessage: nil,
                         remoteSTTConfigured: false).status,
            "Starting microphone"
        )
        XCTAssertEqual(
            VoiceBarFooterPresentation
                .resolve(isConnected: true, mode: .recording, captureLive: true, errorMessage: nil,
                         remoteSTTConfigured: false).status,
            "Recording"
        )
        XCTAssertEqual(
            VoiceBarFooterPresentation
                .resolve(isConnected: true, mode: .error, captureLive: false, errorMessage: "Failed",
                         remoteSTTConfigured: false).status,
            "Error"
        )
        XCTAssertEqual(
            VoiceBarFooterPresentation
                .resolve(isConnected: true, mode: .idle, captureLive: false, errorMessage: nil,
                         remoteSTTConfigured: false, hasFreshHealth: true).status,
            "Ready"
        )
    }

    func testPrivacyNeverClaimsLocalForUnknownOrRemoteConfiguration() {
        XCTAssertEqual(
            VoiceBarFooterPresentation
                .resolve(isConnected: true, mode: .idle, captureLive: false, errorMessage: nil,
                         remoteSTTConfigured: nil).privacy,
            "Processing location unavailable"
        )
        XCTAssertEqual(
            VoiceBarFooterPresentation
                .resolve(isConnected: true, mode: .idle, captureLive: false, errorMessage: nil,
                         remoteSTTConfigured: true).privacy,
            "Remote speech backend configured"
        )
        XCTAssertEqual(
            VoiceBarFooterPresentation
                .resolve(isConnected: true, mode: .idle, captureLive: false, errorMessage: nil,
                         remoteSTTConfigured: false).privacy,
            "Only on this Mac"
        )
    }

    func testPrivacySymbolDistinguishesUnknownFromRemote() {
        func symbol(_ remote: Bool?) -> String {
            VoiceBarFooterPresentation.resolve(
                isConnected: true, mode: .idle, captureLive: false,
                errorMessage: nil, remoteSTTConfigured: remote
            ).privacySymbol
        }
        XCTAssertEqual(symbol(false), "lock.fill")
        XCTAssertEqual(symbol(true), "network")
        XCTAssertEqual(symbol(nil), "questionmark.circle")
    }
}
