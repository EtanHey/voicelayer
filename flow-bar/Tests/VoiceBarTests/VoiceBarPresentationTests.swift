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

    func testRecordingContentShowsOnlyWaveformWhileHolding() {
        XCTAssertEqual(
            VoiceBarPresentation.recordingContent(hotkeyPhase: .holding),
            VoiceBarRecordingContent(
                statusText: "",
                showsWaveform: true,
                usesPulsingLabelOpacity: false
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
            "F6 to talk"
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

    func testLiveStatusTextShowsTranscribingDuringTranscribing() {
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
            "Transcribing..."
        )
    }

    func testNativeBackgroundDraggingIsDisabledAcrossVoiceStates() {
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .idle))
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .error))
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .disconnected))
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .recording))
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .transcribing))
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .speaking))
    }

    func testTranscriptPreviewUsesConfirmationTextOnlyWhenIdleAndUnclaimed() {
        XCTAssertEqual(
            VoiceBarPresentation.transcriptPreviewText(
                mode: .idle,
                confirmationText: " Copied ",
                commandModeState: nil,
                activeClipMarker: nil
            ),
            "Copied"
        )

        XCTAssertNil(
            VoiceBarPresentation.transcriptPreviewText(
                mode: .transcribing,
                confirmationText: "Copied",
                commandModeState: nil,
                activeClipMarker: nil
            )
        )

        XCTAssertNil(
            VoiceBarPresentation.transcriptPreviewText(
                mode: .idle,
                confirmationText: "Copied",
                commandModeState: CommandModeState(
                    phase: .done,
                    operation: "replace_selection",
                    prompt: nil
                ),
                activeClipMarker: nil
            )
        )

        XCTAssertNil(
            VoiceBarPresentation.transcriptPreviewText(
                mode: .idle,
                confirmationText: "Copied",
                commandModeState: nil,
                activeClipMarker: ClipMarkerState(
                    id: "clip-1",
                    label: "Action item",
                    source: "command",
                    status: "marked"
                )
            )
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
