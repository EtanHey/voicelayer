import XCTest
@testable import VoiceBarUI

final class NativeFixBusyReasonTests: XCTestCase {
    func testSharedBusyLineSuppressesOnlyDuplicateDisabledExplanation() {
        let recording = RecognizerPickerState(selected: .whisper, effective: .whisper,
            parakeet: .unloaded, whisper: .loaded, disabledReason: "Finish recording before switching recognizers.")
        XCTAssertNil(RecognizerPickerView(state: recording, onSelect: { _ in }, suppressDisabledExplanation: true).displayedExplanation)
        XCTAssertEqual(RecognizerPickerView(state: recording, onSelect: { _ in }).displayedExplanation, recording.disabledReason,
                       "Other callers retain the picker's existing explanation by default")
        let fallback = RecognizerPickerState(selected: .parakeet, effective: .whisper,
            parakeet: .error, whisper: .loaded, disabledReason: "Voice session in progress", fallbackReason: "parakeet-startup-failed")
        XCTAssertEqual(RecognizerPickerView(state: fallback, onSelect: { _ in }, suppressDisabledExplanation: true).displayedExplanation,
                       "Using Whisper: Parakeet failed to load")
        let rejected = RecognizerPickerState(selected: .whisper, effective: .whisper,
            parakeet: .unloaded, whisper: .loaded, disabledReason: "Voice session in progress", notice: "Could not switch; try again.")
        XCTAssertEqual(RecognizerPickerView(state: rejected, onSelect: { _ in }, suppressDisabledExplanation: true).displayedExplanation,
                       "Could not switch; try again.")
    }
    func testQueueAndCaptureKeepSharedHumanReadableBusyReason() {
        for (recording, queue, expected) in [("idle",1,"Playing back"),("recording",0,"Recording…"),("transcribing",0,"Transcribing…")] {
            let health: [String:Any] = ["type":"health","recording_state":recording,"queue_depth":queue,
                "model_status":["configured_model":["name":"synthetic","installed":true],"residency":"loaded","configured_effort":"accurate"]]
            let state=ModelsSettingsState(healthEvent:health)
            XCTAssertTrue(state.isBusy)
            XCTAssertEqual(ModelsSettingsView.effortDisabledReason(for:state),expected)
        }
    }
}
