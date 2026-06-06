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

    /// LaunchAgent that remaps physical F5 and the dictation key (🎤) to F18
    /// so macOS Dictation never intercepts them.
    public static let remapAgentLabel = "com.voicelayer.f5-to-f18-hidutil"

    public static let remapExplanation =
        "F5 and the dictation key (🎤) are remapped to F18 by the "
        + "com.voicelayer.f5-to-f18-hidutil launch agent so macOS Dictation "
        + "never intercepts them. VoiceBar listens for both."

    public static func shortcutChainLabel(remapDetected: Bool) -> String {
        remapDetected ? "F5 / 🎤  →  F18  →  VoiceBar" : "F5  →  VoiceBar"
    }
}
