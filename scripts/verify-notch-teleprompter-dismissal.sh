#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s <VoiceBar.app> [receipt-directory]\n' "$0" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

app_path=$1
app_binary="$app_path/Contents/MacOS/VoiceBar"
if [[ ! -x "$app_binary" ]]; then
  printf 'error: VoiceBar executable not found at %s\n' "$app_binary" >&2
  exit 2
fi

if [[ $# -eq 2 ]]; then
  receipt_dir=$2
  mkdir -p "$receipt_dir"
else
  receipt_dir=$(mktemp -d "${TMPDIR:-/tmp}/notch-dismissal-receipts.XXXXXX")
fi

runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/notch-dismissal-runtime.XXXXXX")
socket_path="$runtime_dir/voicelayer.sock"
mcp_socket_path="$runtime_dir/voicelayer-mcp.sock"
mcp_pid_path="$runtime_dir/voicelayer-mcp.pid"
recording_path="$runtime_dir/retained.wav"
disable_path="$runtime_dir/disabled"
app_log="$receipt_dir/voicebar.log"
app_pid=''

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -rf "$runtime_dir"
}
trap cleanup EXIT INT TERM

env \
  QA_VOICE_SOCKET_PATH="$socket_path" \
  QA_VOICE_MCP_SOCKET_PATH="$mcp_socket_path" \
  QA_VOICE_MCP_PID_PATH="$mcp_pid_path" \
  QA_VOICE_RETAINED_RECORDING_PATH="$recording_path" \
  QA_VOICE_DISABLE_FLAG_PATH="$disable_path" \
  DISABLE_VOICELAYER=1 \
  QA_VOICEBAR_CAPTURE_BOTTOM_LEFT=1 \
  VOICEBAR_QA_ALLOW_PARALLEL_INSTANCE=1 \
  "$app_binary" >"$app_log" 2>&1 &
app_pid=$!

for _ in {1..100}; do
  [[ -S "$socket_path" ]] && break
  sleep 0.05
done
if [[ ! -S "$socket_path" ]]; then
  printf 'error: isolated VoiceBar socket did not appear; see %s\n' "$app_log" >&2
  exit 1
fi

speaking_event=$(jq -cn '{type:"state",state:"speaking",text:"Atomic material and text must leave together"}')
idle_event=$(jq -cn '{type:"state",state:"idle",source:"playback",next_state:"recording"}')
printf '%s\n' "$speaking_event" | nc -U "$socket_path"
sleep 0.35

desktop_bounds=$(osascript -e 'tell application "Finder" to get bounds of window of desktop')
screen_height=$(printf '%s\n' "$desktop_bounds" | awk -F ', *' '{print $4}')
if [[ ! "$screen_height" =~ ^[0-9]+$ ]]; then
  printf 'error: could not resolve main-screen height from: %s\n' "$desktop_bounds" >&2
  exit 1
fi

# Isolated capture placement pins the 472x245pt teleprompter panel at (24,24).
# Capture only that surface and a narrow same-screen backdrop reference.
capture_x=10
capture_y=$((screen_height - 24 - 245 - 18))
capture_width=520
capture_height=287

(
  sleep 0.55
  printf '%s\n' "$idle_event" | nc -U "$socket_path"
) &
event_pid=$!

for frame_index in {1..18}; do
  frame_path=$(printf '%s/frame-%03d.png' "$receipt_dir" "$frame_index")
  screencapture -x -R"$capture_x,$capture_y,$capture_width,$capture_height" "$frame_path"
  sleep 0.025
done
wait "$event_pid"

verifier="$PWD/flow-bar/.build/release/NotchCaptureContrastVerifier"
if [[ ! -x "$verifier" ]]; then
  swift build -c release --package-path "$PWD/flow-bar" --product NotchCaptureContrastVerifier
fi

"$verifier" \
  --teleprompter-dismissal-only \
  --teleprompter-dismissal-frames "$receipt_dir" \
  --teleprompter-dismissal-text-region 0.12,0.22,0.42,0.12 \
  --teleprompter-dismissal-interior-region 0.05,0.50,0.45,0.30

printf 'TELEPROMPTER_DISMISSAL_REAL_CAPTURE=%s\n' "$receipt_dir"
