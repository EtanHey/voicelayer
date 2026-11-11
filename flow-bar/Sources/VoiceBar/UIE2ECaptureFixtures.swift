#if VOICEBAR_QA
import AppKit
import CoreAudio
import VoiceBarUI

/// QA delegate only. Feeds the existing presentation inputs; never constructs a recorder.
@MainActor
enum UIE2ECaptureFixtures {
    static func hasNoDefaultOutputDevice() -> Bool {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device == kAudioObjectUnknown
    }

    static func hostGeometry() -> VoiceBarNotchScreenGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return nil }
        return VoiceBarNotchScreenGeometry.resolve(metrics: .init(frame: screen.frame,
            visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea, auxiliaryTopRightArea: screen.auxiliaryTopRightArea))
    }

    static func receipt(sandbox: UIE2ESandbox, geometry: VoiceBarNotchScreenGeometry,
                        panel: NSWindow, state: VoiceState) {
        sandbox.writeObject(["synthetic": true, "physicalNotch": geometry.kind == .hardwareNotch,
            "geometry": geometry.kind == .hardwareNotch ? "host-hardware-notch" : "host-flat-display-no-physical-notch",
            "coreWidth": geometry.housingFrame.width, "occlusionInset": geometry.visibleCoreOcclusionInset,
            "panelFrame": NSStringFromRect(panel.frame), "mode": state.recordingMode ?? "none",
            "elapsedMs": state.recordingElapsedMilliseconds(), "level": state.audioLevel as Any? ?? NSNull()],
            file: "capture-fixture.json")
    }
}

@MainActor
extension UIE2EModel {
    func beginSyntheticCapture(mode: String, elapsedMilliseconds: Int) {
        voice.setSetupMissingPermissions([])
        refresh()
        voice.handleEvent(["type": "state", "state": "idle"])
        syntheticCaptureClockMs = 1_000
        voice.recordingTimingClock = { [weak self] in Double(self?.syntheticCaptureClockMs ?? 0) / 1000 }
        voice.recordingMicrophoneNameProvider = { "Synthetic input (no microphone)" }
        voice.handleEvent(["type": "state", "state": "recording", "mode": mode])
        voice.handleEvent(["type": "audio_level", "rms": 0.4])
        advanceSyntheticCapture(milliseconds: elapsedMilliseconds)
    }

    func advanceSyntheticCapture(milliseconds: Int) {
        guard let clock = syntheticCaptureClockMs, voice.mode == .recording else { return }
        syntheticCaptureClockMs = clock + milliseconds
        let phase = Double((clock / 50) % 16) / 15
        voice.handleEvent(["type": "audio_level", "rms": 0.15 + 0.55 * phase])
    }
}
#endif
