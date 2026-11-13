// Harness-only stand-in for VoiceState.swift's GuardedTypingResult, so SynthesizedKeyEvents.swift
// compiles without the rest of VoiceBarUI.
public enum GuardedTypingResult: Equatable { case posted, focusChanged, failed, partial(delivered: String, remaining: String) }
