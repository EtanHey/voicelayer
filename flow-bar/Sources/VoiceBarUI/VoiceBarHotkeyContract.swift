import Foundation

public enum VoiceBarHotkeyContract {
    public static let primaryShortcutLabel = "F5"
    // Copy below mirrors the actual wiring in HotkeyManager/VoiceBarCommandRouter:
    // single tap stops recording/speech and cancels transcription (idle: nothing),
    // hold is push-to-talk, double-tap locks the active recording hands-free.
    public static let singleTapDescription = "Stop recording or speech; cancel transcription"
    public static let holdDescription = "Push-to-talk recording"
    public static let doubleTapDescription = "Lock the active recording (hands-free)"
    public static let repasteShortcutLabel = "Shift+F5"
    public static let repasteDescription = "Re-paste last transcript"
    public static let activationLogMessage = "[VoiceBar] Hotkey system active — primary shortcut is F5"

    // MARK: - System remap chain (hidutil LaunchAgent)

    /// LaunchAgent that remaps the dictation key (🎤) to F18 so macOS
    /// Dictation never intercepts it. Physical F5 is NOT remapped — the
    /// event tap listens for keycode 96 directly, and a HID-level F5 rewrite
    /// would hide F5 from system chords like Cmd+F5 (VoiceOver). See
    /// scripts/apply-voicebar-f5-hidutil.sh.
    public static let remapAgentLabel = "com.voicelayer.f5-to-f18-hidutil"

    public static let remapExplanation =
        "VoiceBar listens for F5 directly. The dictation key (🎤) is "
        + "remapped to F18 by the com.voicelayer.f5-to-f18-hidutil launch "
        + "agent so macOS Dictation never intercepts it; VoiceBar listens "
        + "for F18 too."

    public static func shortcutChainLabel(remapDetected: Bool) -> String {
        remapDetected ? "F5  ·  🎤 → F18" : "F5"
    }
}
