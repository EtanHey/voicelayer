#!/usr/bin/env bash
# Native UI-only fixture on host or terminal-mac. Never installs or swaps an app.
set -euo pipefail
[[ $# == 3 ]] || { echo "usage: $0 QA_APP ABSOLUTE_vl-ui-ROOT FIXTURE" >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd)
app=$1
qa=$2
fixture=$3
case "$qa" in /*/vl-ui-*) ;; *) echo "REFUSED: absolute fixture root basename must start vl-ui- (including terminal-mac guests)" >&2; exit 1 ;; esac
qa=$(cd "$qa" && pwd -P)
case "${qa##*/}" in vl-ui-*) ;; *) echo "REFUSED: resolved root basename must start vl-ui-*" >&2; exit 1 ;; esac
case "$qa" in *.noindex/*) ;; *) echo "REFUSED: use a vl-ui-* root beneath a .noindex directory" >&2; exit 1 ;; esac
[[ $qa != "$(cd "$HOME" && pwd -P)" ]] || { echo "REFUSED: HOME is not a fixture root" >&2; exit 1; }
app=$(cd "$app" && pwd -P)
case "$app" in /Applications/*) echo "REFUSED: /Applications is never a QA fixture source" >&2; exit 1 ;; esac
plist="$app/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :VoiceBarUIE2EOnly' "$plist") == true &&
   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist") == com.voicelayer.voicebar.uie2e ]] || {
  echo "REFUSED: requires a persistent UIE2E-only QA bundle" >&2; exit 1;
}
mkdir -p "$qa/home" "$qa/archive" "$qa/state" "$qa/tmp"
printf 'voicebar-ui-e2e-v1\n' > "$qa/.uie2e-sandbox"
ipc=$(mktemp -d /tmp/vl-ui-ipc.XXXXXX)
child=
source "$repo/scripts/lib/output-mute-guard.sh"
cleanup() {
  if [[ -n $child ]]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  output_mute_guard_final
}
if [[ $(osascript -e 'output muted of (get volume settings)') == "missing value" ]]; then
  echo "Output mute unavailable; QA app must independently verify no default CoreAudio output device."
else
  output_mute_guard_begin
fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
VOICEBAR_UIE2E=1 VOICEBAR_UIE2E_ROOT="$qa" VOICEBAR_UIE2E_GEOMETRY=host \
VOICEBAR_UIE2E_FIXTURE="$fixture" \
HOME="$qa/home" CFFIXED_USER_HOME="$qa/home" TMPDIR="$qa/tmp/" \
VOICELAYER_SOCKET_PATH="$ipc/v.sock" VOICELAYER_MCP_SOCKET_PATH="$ipc/m.sock" \
QA_VOICE_SOCKET_PATH="$ipc/v.sock" QA_VOICE_MCP_SOCKET_PATH="$ipc/m.sock" \
VOICELAYER_STATE_DIR="$qa/state" QA_VOICE_RECORDINGS_DIR="$qa/archive" \
QA_VOICE_MCP_PID_PATH="$ipc/m.pid" QA_VOICE_MCP_HEARTBEAT_PATH="$ipc/m.heartbeat" \
VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL=1 VOICELAYER_TEST_REAL_AUDIO=0 VOICELAYER_TEST_REAL_MIC=0 \
  "$app/Contents/MacOS/VoiceBar" > "$qa/fixture.log" 2>&1 &
child=$!
printf '%s\n' "$child" > "$qa/fixture.pid"
echo "UI-only synthetic fixture PID=$child; geometry receipt: $qa/capture-fixture.json"
wait "$child"
