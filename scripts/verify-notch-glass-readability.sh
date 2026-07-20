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
  receipt_dir=$(mktemp -d "${TMPDIR:-/tmp}/notch-glass-receipts.XXXXXX")
fi
mkdir -p "$receipt_dir/busy" "$receipt_dir/black" "$receipt_dir/bright"

runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/notch-glass-runtime.XXXXXX")
socket_path="$runtime_dir/voicelayer.sock"
mcp_socket_path="$runtime_dir/voicelayer-mcp.sock"
mcp_pid_path="$runtime_dir/voicelayer-mcp.pid"
recording_path="$runtime_dir/retained.wav"
disable_path="$runtime_dir/disabled"
render_scale_receipt="$receipt_dir/render-scale.json"
defaults_suite="com.voicelayer.qa.notch-glass.$$.${RANDOM}"
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
swift build -c release --package-path "$repo_root/flow-bar" \
  --product NotchCaptureContrastVerifier
bin_path=$(swift build -c release --package-path "$repo_root/flow-bar" --show-bin-path)
fixture_binary="$bin_path/NotchGlassBackdropFixture"
verifier="$bin_path/NotchCaptureContrastVerifier"

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

for fixture_mode in busy black bright; do
  fixture_receipt="$runtime_dir/fixture-$fixture_mode.json"
  "$fixture_binary" \
    --mode "$fixture_mode" \
    --ready-receipt "$fixture_receipt" >>"$fixture_log" 2>&1 &
  fixture_pid=$!
  for _ in {1..100}; do
    [[ -f "$fixture_receipt" ]] && break
    sleep 0.025
  done
  if [[ ! -f "$fixture_receipt" ]]; then
    printf 'error: %s fixture did not become ready\n' "$fixture_mode" >&2
    exit 1
  fi
  capture_values=$(jq -er '.capture_rect | map(round) | @tsv' "$fixture_receipt")
  read -r capture_x capture_y capture_width capture_height <<<"$capture_values"
  if [[ ! "$capture_x" =~ ^-?[0-9]+$ ||
        ! "$capture_y" =~ ^-?[0-9]+$ ||
        ! "$capture_width" =~ ^[1-9][0-9]*$ ||
        ! "$capture_height" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: invalid capture_rect in %s\n' "$fixture_receipt" >&2
    exit 1
  fi

  if [[ "$fixture_mode" == busy ]]; then
    state_event=$(jq -cn '{type:"state",state:"speaking",text:"Continuous liquid glass must frost every busy terminal row so this teleprompter remains calmly readable."}')
  else
    state_event=$(jq -cn '{type:"state",state:"recording"}')
  fi
  printf '%s\n' "$state_event" | nc -U "$socket_path"
  sleep 0.55

  for frame_index in 1 2 3; do
    frame_path=$(printf '%s/%s/frame-%03d.png' "$receipt_dir" "$fixture_mode" "$frame_index")
    screencapture -x -R"$capture_x,$capture_y,$capture_width,$capture_height" "$frame_path"
    sleep 0.10
  done

  kill "$fixture_pid" 2>/dev/null || true
  wait "$fixture_pid" 2>/dev/null || true
  fixture_pid=''
done

"$verifier" \
  --glass-readability-only \
  --glass-teleprompter-frames "$receipt_dir/busy" \
  --glass-black-frames "$receipt_dir/black" \
  --glass-bright-frames "$receipt_dir/bright" \
  --glass-teleprompter-interior-region 0.10,0.70,0.55,0.10 \
  --glass-teleprompter-text-region 0.10,0.38,0.58,0.24 \
  --glass-teleprompter-background-region 0.10,0.65,0.55,0.06 \
  --glass-wing-foreground-region 0.455,0.81,0.035,0.09 \
  --glass-wing-background-region 0.520,0.86,0.020,0.04 \
  --glass-reference-foreground-region 0.835,0.80,0.065,0.12 \
  --glass-reference-background-region 0.815,0.78,0.105,0.16 \
  | tee "$receipt_dir/metrics.txt"

printf 'NOTCH_GLASS_READABILITY_REAL_CAPTURE=%s\n' "$receipt_dir"
