@testable import VoiceBar
import XCTest

final class VoiceBarPresentationTests: XCTestCase {
    func testRecordingContentShowsWaveformWithoutListeningLabelByDefault() {
        XCTAssertEqual(
            VoiceBarPresentation.recordingContent(hotkeyPhase: .idle),
            VoiceBarRecordingContent(
                statusText: "",
                showsWaveform: true,
                usesPulsingLabelOpacity: false
            )
        )
    }

    func testRecordingContentUsesReleaseToSendCopyWhileHolding() {
        XCTAssertEqual(
            VoiceBarPresentation.recordingContent(hotkeyPhase: .holding),
            VoiceBarRecordingContent(
                statusText: "Release to send",
                showsWaveform: true,
                usesPulsingLabelOpacity: true
            )
        )
    }

    func testQueuePreviewSummarizesCurrentNextAndOverflow() {
        let preview = VoiceBarPresentation.queuePreview(from: [
            QueueItemState(
                text: "Current line",
                voice: "jenny",
                priority: "normal",
                isCurrent: true,
                progress: 0.35
            ),
            QueueItemState(
                text: "Queued line",
                voice: "jenny",
                priority: "high",
                isCurrent: false,
                progress: 0
            ),
            QueueItemState(
                text: "Third line",
                voice: "jenny",
                priority: "normal",
                isCurrent: false,
                progress: 0
            ),
            QueueItemState(
                text: "Fourth line",
                voice: "jenny",
                priority: "low",
                isCurrent: false,
                progress: 0
            ),
        ])

        XCTAssertEqual(preview.currentText, "Current line")
        XCTAssertEqual(preview.nextText, "Queued line")
        XCTAssertEqual(preview.overflowCount, 2)
        XCTAssertEqual(preview.progress, 0.35, accuracy: 0.001)
    }

    func testIdleStatusTextUsesHotkeyHintsBeforeReady() {
        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .pressing,
                hotkeyEnabled: true
            ),
            "Hold to talk"
        )

        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .holding,
                hotkeyEnabled: true
            ),
            "Release to send"
        )

        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .awaitingSecondTap,
                hotkeyEnabled: true
            ),
            "Tap again to lock"
        )
    }

    func testIdleStatusTextFallsBackToConfirmationTranscriptAndReady() {
        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "latest transcript line",
                confirmationText: "Pasted",
                hotkeyPhase: .idle,
                hotkeyEnabled: true
            ),
            "Pasted"
        )

        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "one two three four",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true
            ),
            "two three four"
        )

        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true
            ),
            "F6 to talk"
        )

        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: false
            ),
            "Enable hotkey"
        )
    }

    func testLiveStatusTextShowsThinkingDuringTranscribing() {
        XCTAssertEqual(
            VoiceBarPresentation.liveStatusText(
                mode: .transcribing,
                transcript: "ignored",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true,
                errorMessage: nil,
                commandModeState: nil,
                activeClipMarker: nil
            ),
            "Thinking..."
        )
    }

    func testLiveStatusTextPrefersCommandModeAndClipMarkerStatus() {
        XCTAssertEqual(
            VoiceBarPresentation.liveStatusText(
                mode: .idle,
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true,
                errorMessage: nil,
                commandModeState: CommandModeState(
                    phase: .applying,
                    operation: "replace_selection",
                    prompt: "Rewrite selection"
                ),
                activeClipMarker: nil
            ),
            "Command: Rewrite selection"
        )

        XCTAssertEqual(
            VoiceBarPresentation.liveStatusText(
                mode: .idle,
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true,
                errorMessage: nil,
                commandModeState: nil,
                activeClipMarker: ClipMarkerState(
                    id: "clip-1",
                    label: "Action item",
                    source: "command",
                    status: "marked"
                )
            ),
            "Clip marked: Action item"
        )
    }

    func testHotkeyPermissionHintIsSpecificToMissingPermission() {
        XCTAssertEqual(
            VoiceBarPresentation.hotkeyPermissionHint(
                hotkeyEnabled: false,
                missingPermissions: [.inputMonitoring]
            ),
            "Hotkey: enable Input Monitoring"
        )

        XCTAssertEqual(
            VoiceBarPresentation.hotkeyPermissionHint(
                hotkeyEnabled: false,
                missingPermissions: [.accessibility]
            ),
            "Hotkey: enable Accessibility"
        )
    }

    func testHotkeyPermissionHintHandlesBothPermissions() {
        XCTAssertEqual(
            VoiceBarPresentation.hotkeyPermissionHint(
                hotkeyEnabled: false,
                missingPermissions: [.inputMonitoring, .accessibility]
            ),
            "Hotkey: enable Accessibility + Input Monitoring"
        )
    }
}
