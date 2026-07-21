#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s <VoiceBar.app> [receipt-directory]\n' "$0" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
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
render_scale_receipt="$receipt_dir/render-scale.json"
defaults_suite="com.voicelayer.qa.notch-dismissal.$$.${RANDOM}"
app_log="$receipt_dir/voicebar.log"
fixture_log="$receipt_dir/fixture.log"
app_pid=''
fixture_pid=''

cleanup() {
  if [[ -n "$fixture_pid" ]] && kill -0 "$fixture_pid" 2>/dev/null; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  defaults delete "$defaults_suite" >/dev/null 2>&1 || true
  rm -rf "$runtime_dir"
}
trap cleanup EXIT INT TERM

swift build -c release --package-path "$repo_root/flow-bar" \
  --product NotchGlassBackdropFixture
bin_path=$(swift build -c release --package-path "$repo_root/flow-bar" --show-bin-path)
fixture_binary="$bin_path/NotchGlassBackdropFixture"
fixture_receipt="$runtime_dir/fixture-busy.json"
"$fixture_binary" \
  --mode busy \
  --ready-receipt "$fixture_receipt" >"$fixture_log" 2>&1 &
fixture_pid=$!
for _ in {1..100}; do
  [[ -f "$fixture_receipt" ]] && break
  sleep 0.025
done
if [[ ! -f "$fixture_receipt" ]]; then
  printf 'error: busy fixture did not become ready; see %s\n' "$fixture_log" >&2
  exit 1
fi
capture_values=$(jq -er '.capture_rect | map(round) | @tsv' "$fixture_receipt")
read -r fixture_capture_x fixture_capture_y fixture_capture_width fixture_capture_height \
  <<<"$capture_values"
if [[ ! "$fixture_capture_x" =~ ^-?[0-9]+$ ||
      ! "$fixture_capture_y" =~ ^-?[0-9]+$ ||
      ! "$fixture_capture_width" =~ ^[1-9][0-9]*$ ||
      ! "$fixture_capture_height" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: invalid capture_rect in %s\n' "$fixture_receipt" >&2
  exit 1
fi

env \
  QA_VOICE_SOCKET_PATH="$socket_path" \
  QA_VOICE_MCP_SOCKET_PATH="$mcp_socket_path" \
  QA_VOICE_MCP_PID_PATH="$mcp_pid_path" \
  QA_VOICE_RETAINED_RECORDING_PATH="$recording_path" \
  QA_VOICE_DISABLE_FLAG_PATH="$disable_path" \
  QA_VOICEBAR_RENDER_SCALE_RECEIPT_PATH="$render_scale_receipt" \
  VOICEBAR_USER_DEFAULTS_SUITE="$defaults_suite" \
  DISABLE_VOICELAYER=1 \
  QA_VOICEBAR_CAPTURE_BOTTOM_LEFT=1 \
  VOICEBAR_QA_ALLOW_PARALLEL_INSTANCE=1 \
  VOICEBAR_QA_SKIP_LS_REGISTER=1 \
  VOICEBAR_QA_SKIP_PERMISSION_PROMPTS=1 \
  VOICEBAR_QA_SKIP_HOTKEY=1 \
  VOICEBAR_QA_PRESERVE_OVERRIDES=1 \
  "$app_binary" >"$app_log" 2>&1 &
app_pid=$!

for _ in {1..100}; do
  [[ -S "$socket_path" && -f "$render_scale_receipt" ]] && break
  sleep 0.05
done
if [[ ! -S "$socket_path" || ! -f "$render_scale_receipt" ]]; then
  printf 'error: isolated VoiceBar did not become capture-ready; see %s\n' "$app_log" >&2
  exit 1
fi

speaking_event=$(jq -cn '{type:"state",state:"speaking",text:"Atomic material and text must leave together"}')
idle_event=$(jq -cn '{type:"state",state:"idle",source:"playback",next_state:"recording"}')
printf '%s\n' "$speaking_event" | nc -U "$socket_path"
sleep 0.35

# Isolated capture placement pins the 472x245pt teleprompter panel at (24,24).
# Capture only that surface and a narrow same-screen backdrop reference.
capture_x=$((fixture_capture_x + 10))
capture_y=$((fixture_capture_y + fixture_capture_height - 24 - 245 - 18))
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

verifier="$repo_root/flow-bar/.build/release/NotchCaptureContrastVerifier"
if [[ ! -x "$verifier" ]]; then
  swift build -c release --package-path "$repo_root/flow-bar" --product NotchCaptureContrastVerifier
fi

"$verifier" \
  --teleprompter-dismissal-only \
  --teleprompter-dismissal-frames "$receipt_dir" \
  --teleprompter-dismissal-text-region 0.12,0.22,0.42,0.12 \
  --teleprompter-dismissal-interior-region 0.12,0.62,0.74,0.13 \
  | tee "$receipt_dir/metrics.txt"

printf 'TELEPROMPTER_DISMISSAL_REAL_CAPTURE=%s\n' "$receipt_dir"
