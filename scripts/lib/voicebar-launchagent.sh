#!/usr/bin/env bash
# Launchd executes Program when present, otherwise ProgramArguments[0].
agent_target() {
  "${PLIST_BUDDY:-/usr/libexec/PlistBuddy}" -c 'Print :Program' "$1" 2>/dev/null ||
    "${PLIST_BUDDY:-/usr/libexec/PlistBuddy}" -c 'Print :ProgramArguments:0' "$1" 2>/dev/null
}

is_voicebar_agent() {
  local label target
  label="$("${PLIST_BUDDY:-/usr/libexec/PlistBuddy}" -c 'Print :Label' "$1" 2>/dev/null || true)"
  # The TTS service uses resources inside the app; preserve its exact label,
  # including renamed plists. Similar labels receive no exemption.
  [[ "$label" != "com.golems.tts-daemon" ]] || return 1
  target="$(agent_target "$1" || true)"
  [[ "$target" == */Contents/MacOS/VoiceBar ]]
}
