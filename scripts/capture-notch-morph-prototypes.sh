#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s <VoiceBar.app> [receipt-directory]\n' "$0" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

for command_name in ffmpeg ffprobe jq nc screencapture shasum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$command_name" >&2
    exit 2
  fi
done

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
  receipt_dir=$(mktemp -d "${TMPDIR:-/tmp}/notch-morph-receipts.XXXXXX")
fi

# Unix-domain sockets are capped at a short path length on macOS. Keep the
# isolated root deliberately terse so the longest variant remains valid even
# when the caller's TMPDIR is deeply nested.
runtime_root=$(mktemp -d /tmp/nm.XXXXXX)
fixture_receipt="$runtime_root/fixture-busy.json"
fixture_log="$receipt_dir/fixture.log"
fixture_pid=''
app_pid=''

cleanup_app() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  app_pid=''
}

cleanup() {
  cleanup_app
  if [[ -n "$fixture_pid" ]] && kill -0 "$fixture_pid" 2>/dev/null; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  rm -rf "$runtime_root"
}
trap cleanup EXIT INT TERM

swift build -c release --package-path "$repo_root/flow-bar" \
  --product NotchGlassBackdropFixture
bin_path=$(swift build -c release --package-path "$repo_root/flow-bar" --show-bin-path)
fixture_binary="$bin_path/NotchGlassBackdropFixture"

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
read -r capture_x capture_y capture_width capture_height <<<"$capture_values"
if [[ ! "$capture_x" =~ ^-?[0-9]+$ ||
      ! "$capture_y" =~ ^-?[0-9]+$ ||
      ! "$capture_width" =~ ^[1-9][0-9]*$ ||
      ! "$capture_height" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: invalid capture_rect in %s\n' "$fixture_receipt" >&2
  exit 1
fi
capture_rect="$capture_x,$capture_y,$capture_width,$capture_height"

app_sha256=$(shasum -a 256 "$app_binary" | awk '{ print $1 }')
jq -n \
  --arg app "$app_path" \
  --arg app_sha256 "$app_sha256" \
  --argjson capture_rect "$(jq -c '.capture_rect' "$fixture_receipt")" \
  '{app:$app,app_sha256:$app_sha256,capture_rect:$capture_rect,requested_fps:60}' \
  >"$receipt_dir/manifest.json"

record_transition() {
  local variant_dir=$1
  local direction=$2
  local event_payload=$3
  local video_path="$variant_dir/$direction.mov"
  local frames_dir="$variant_dir/$direction-frames"
  local capture_pid

  mkdir -p "$frames_dir"
  screencapture -x -v -V1 -R"$capture_rect" "$video_path" &
  capture_pid=$!
  sleep 0.20
  printf '%s\n' "$event_payload" | nc -U "$socket_path"
  wait "$capture_pid"

  ffmpeg -hide_banner -loglevel error -y \
    -i "$video_path" -vf fps=60 "$frames_dir/frame-%03d.png"
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=avg_frame_rate,r_frame_rate,nb_frames,duration,width,height \
    -of json "$video_path" >"$variant_dir/$direction-probe.json"
}

# macOS video capture can encode unchanged regions as dirty rectangles. Keep a
# second, independent sequence of full PNG screenshots for visual and pixel
# audits; the movie above remains the source of frame-timing evidence.
capture_live_png_transition() {
  local variant_dir=$1
  local direction=$2
  local event_payload=$3
  local frames_dir="$variant_dir/$direction-live-frames"
  local frame_path
  local trigger_pid

  mkdir -p "$frames_dir"
  (
    # Leave several baseline PNGs before the event. Individual screenshot
    # latency varies by display, so a single-frame lead is not reliable.
    sleep 0.18
    printf '%s\n' "$event_payload" | nc -U "$socket_path"
  ) &
  trigger_pid=$!

  for frame_number in {1..28}; do
    printf -v frame_path '%s/%s-live-frames/frame-%03d.png' \
      "$variant_dir" "$direction" "$frame_number"
    screencapture -x -R"$capture_rect" "$frame_path"
    sleep 0.01
  done
  wait "$trigger_pid"
}

# All three prototypes run from this one app binary and differ only by the
# isolated runtime selector.
variants=(p1-matched p2-native-glass p3-spring-delight)
speaking_event=$(jq -cn \
  '{type:"state",state:"speaking",text:"One continuous frosted shell should morph while this teleprompter remains crisp and readable."}')
recording_event=$(jq -cn '{type:"state",state:"recording"}')

for variant in "${variants[@]}"; do
  variant_dir="$receipt_dir/$variant"
  runtime_dir="$runtime_root/$variant"
  mkdir -p "$variant_dir" "$runtime_dir"
  socket_path="$runtime_dir/voicelayer.sock"
  mcp_socket_path="$runtime_dir/voicelayer-mcp.sock"
  mcp_pid_path="$runtime_dir/voicelayer-mcp.pid"
  recording_path="$runtime_dir/retained.wav"
  disable_path="$runtime_dir/disabled"
  render_scale_receipt="$variant_dir/render-scale.json"
  defaults_suite="com.voicelayer.qa.notch-morph.$$.${RANDOM}.$variant"
  app_log="$variant_dir/voicebar.log"

  env \
    QA_VOICE_SOCKET_PATH="$socket_path" \
    QA_VOICE_MCP_SOCKET_PATH="$mcp_socket_path" \
    QA_VOICE_MCP_PID_PATH="$mcp_pid_path" \
    QA_VOICE_RETAINED_RECORDING_PATH="$recording_path" \
    QA_VOICE_DISABLE_FLAG_PATH="$disable_path" \
    QA_VOICEBAR_RENDER_SCALE_RECEIPT_PATH="$render_scale_receipt" \
    VOICEBAR_USER_DEFAULTS_SUITE="$defaults_suite" \
    VOICEBAR_NOTCH_MORPH_VARIANT="$variant" \
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
    printf 'error: %s did not become capture-ready; see %s\n' "$variant" "$app_log" >&2
    exit 1
  fi

  printf '%s\n' "$recording_event" | nc -U "$socket_path"
  sleep 0.55
  screencapture -x -R"$capture_rect" "$variant_dir/compact-settled.png"

  record_transition "$variant_dir" forward "$speaking_event"
  sleep 0.40
  screencapture -x -R"$capture_rect" "$variant_dir/teleprompter-settled.png"

  printf '%s\n' "$recording_event" | nc -U "$socket_path"
  sleep 0.45
  capture_live_png_transition "$variant_dir" forward "$speaking_event"
  sleep 0.40

  record_transition "$variant_dir" reverse "$recording_event"
  sleep 0.40
  screencapture -x -R"$capture_rect" "$variant_dir/compact-returned.png"

  printf '%s\n' "$speaking_event" | nc -U "$socket_path"
  sleep 0.45
  capture_live_png_transition "$variant_dir" reverse "$recording_event"
  sleep 0.40

  cleanup_app
  defaults delete "$defaults_suite" >/dev/null 2>&1 || true
done

printf 'NOTCH_MORPH_PROTOTYPE_CAPTURES=%s\n' "$receipt_dir"
