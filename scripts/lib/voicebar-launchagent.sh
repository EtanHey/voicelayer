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

# A start is successful only when launchd owns the sole expected executable.
voicebar_sample_launchd() {
  local expected="${1:-/Applications/VoiceBar.app}/Contents/MacOS/VoiceBar"
  local output line state="" pid="" owners executable
  output="$(launchctl print "gui/$(id -u)/com.voicelayer.voicebar" 2>/dev/null)" || return 1
  while IFS= read -r line; do
    if [[ -z "$state" && "$line" =~ ^[[:space:]]*state[[:space:]]*=[[:space:]]*(.*)$ ]]; then state="${BASH_REMATCH[1]}"; fi
    if [[ -z "$pid" && "$line" =~ ^[[:space:]]*pid[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then pid="${BASH_REMATCH[1]}"; fi
  done <<< "$output"
  [[ "$state" == running && "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  owners="$(pgrep -U "$(id -u)" -x VoiceBar)" || return 1
  [[ "$owners" == "$pid" ]] || return 1
  executable="$(ps -p "$pid" -o comm=)" || return 1
  [[ "$executable" == "$expected" ]] || return 1
  VOICEBAR_VERIFIED_PID="$pid"
}

# Public verification also requires the same PID on two consecutive good samples.
voicebar_verify_launchd() {
  local previous
  voicebar_sample_launchd "$@" || return 1
  previous="$VOICEBAR_VERIFIED_PID"
  sleep 0.1
  voicebar_sample_launchd "$@" && [[ "$VOICEBAR_VERIFIED_PID" == "$previous" ]]
}

voicebar_start_launchd() {
  local app="${1:-/Applications/VoiceBar.app}" domain="gui/$(id -u)" attempt
  # 25 seconds includes native acceptedQuitWait (currently 3 seconds) and startup.
  local attempts="${VOICEBAR_LAUNCH_WAIT_ATTEMPTS:-250}"
  if [[ "${VOICELAYER_TEST_ISOLATED:-}" == 1 ]]; then
    local tool physical_home physical_bin
    tool="$(command -v launchctl)" || return 1
    physical_home="$(cd "$HOME" && pwd -P)" || return 1
    physical_bin="$(cd "$(dirname "$tool")" && pwd -P)" || return 1
    [[ "$physical_home" == "${VOICELAYER_TEST_RUN_ROOT:?}/"* &&
       "$physical_bin" == "$VOICELAYER_TEST_RUN_ROOT/"* && ! -L "$tool" ]] || {
      echo 'ERROR: launchd test tools/HOME escaped isolated root' >&2; return 1;
    }
  fi
  # An already verified resident, including an active recording, is a no-op.
  local previous="" good=0 bootstrapped=0
  voicebar_verify_launchd "$app" && return 0
  launchctl enable "$domain/com.voicelayer.voicebar" || {
    echo 'ERROR: launchd enable failed' >&2; return 1;
  }
  if ! launchctl print "$domain/com.voicelayer.voicebar" >/dev/null 2>&1; then
    launchctl bootstrap "$domain" "$HOME/Library/LaunchAgents/com.voicelayer.voicebar.plist" || {
      echo 'ERROR: launchd bootstrap failed; run voicelayer setup' >&2; return 1;
    }
    bootstrapped=1 # RunAtLoad has already started this instance; never kick it again.
  fi
  if [[ "$bootstrapped" -eq 0 ]]; then
    launchctl kickstart "$domain/com.voicelayer.voicebar" || {
      echo 'ERROR: launchd kickstart failed' >&2; return 1;
    }
  fi
  previous=""
  for ((attempt=0; attempt<attempts; attempt++)); do
    if voicebar_sample_launchd "$app"; then
      if [[ "$VOICEBAR_VERIFIED_PID" == "$previous" ]]; then good=$((good+1)); else good=1; fi
      previous="$VOICEBAR_VERIFIED_PID"
      [[ "$good" -ge 2 ]] && return 0
    else
      previous=""; good=0
    fi
    sleep 0.1
  done
  echo 'ERROR: launchd VoiceBar is not running with a stable sole expected PID/executable' >&2
  return 1
}
