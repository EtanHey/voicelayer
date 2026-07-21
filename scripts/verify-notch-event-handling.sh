#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s <isolated-VoiceBar.app> [receipt-directory]\n' "$0" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
raw_app_path=$1
if [[ "$raw_app_path" == *".."* ]]; then
  printf 'error: app path must not contain parent traversal\n' >&2
  exit 2
fi
app_path=$(realpath "$raw_app_path")
app_binary="$app_path/Contents/MacOS/VoiceBar"
if [[ ! -x "$app_binary" ]]; then
  printf 'error: VoiceBar executable not found at %s\n' "$app_binary" >&2
  exit 2
fi

case "$app_path" in
  /Applications/*)
    printf 'error: event acceptance requires a temporary isolated app bundle\n' >&2
    exit 2
    ;;
esac

temp_root=${TMPDIR:-/tmp}
temp_root=${temp_root%/}
if [[ $# -eq 2 ]]; then
  receipt_dir=$2
  mkdir -p "$receipt_dir"
else
  receipt_dir=$(mktemp -d "$temp_root/notch-event-receipts.XXXXXX")
fi
frame_dir="$receipt_dir/frames"
mkdir -p "$frame_dir"

runtime_dir=$(mktemp -d "$temp_root/notch-event-runtime.XXXXXX")
socket_path="$runtime_dir/voicelayer.sock"
mcp_socket_path="$runtime_dir/voicelayer-mcp.sock"
mcp_pid_path="$runtime_dir/voicelayer-mcp.pid"
recording_path="$runtime_dir/retained.wav"
disable_path="$runtime_dir/disabled"
render_scale_receipt="$runtime_dir/render-scale.json"
defaults_suite="com.voicelayer.qa.notch-event.$$.${RANDOM}"
app_log="$receipt_dir/voicebar.log"
state_log="$receipt_dir/state-events.ndjson"
app_pid=''
isolated_marker_path=''
offscreen_origin=-20000

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  defaults delete "$defaults_suite" >/dev/null 2>&1 || true
  if [[ -n "$isolated_marker_path" && -f "$isolated_marker_path" ]]; then
    rm -f "$isolated_marker_path"
  fi
  case "$runtime_dir" in
    "$temp_root"/notch-event-runtime.*)
      rm -rf "$runtime_dir"
      ;;
    *)
      printf 'warning: refusing to remove unexpected runtime path %s\n' "$runtime_dir" >&2
      ;;
  esac
}
trap cleanup EXIT INT TERM

env \
  QA_VOICE_SOCKET_PATH="$socket_path" \
  QA_VOICE_MCP_SOCKET_PATH="$mcp_socket_path" \
  QA_VOICE_MCP_PID_PATH="$mcp_pid_path" \
  QA_VOICE_RETAINED_RECORDING_PATH="$recording_path" \
  QA_VOICE_DISABLE_FLAG_PATH="$disable_path" \
  QA_VOICEBAR_RENDER_SCALE_RECEIPT_PATH="$render_scale_receipt" \
  VOICEBAR_USER_DEFAULTS_SUITE="$defaults_suite" \
  DISABLE_VOICELAYER=1 \
  QA_VOICEBAR_CAPTURE_OFFSCREEN=1 \
  VOICEBAR_QA_ALLOW_PARALLEL_INSTANCE=1 \
  VOICEBAR_QA_SKIP_LS_REGISTER=1 \
  VOICEBAR_QA_SKIP_PERMISSION_PROMPTS=1 \
  VOICEBAR_QA_SKIP_HOTKEY=1 \
  VOICEBAR_QA_PRESERVE_OVERRIDES=1 \
  "$app_binary" >"$app_log" 2>&1 &
app_pid=$!
isolated_marker_path="${HOME}/Library/Application Support/VoiceLayer/isolated-voicebar-instances/${app_pid}.json"

for _ in {1..200}; do
  [[ -S "$socket_path" && -f "$render_scale_receipt" && -f "$isolated_marker_path" ]] && break
  if ! kill -0 "$app_pid" 2>/dev/null; then
    printf 'error: isolated VoiceBar exited before becoming ready; see %s\n' "$app_log" >&2
    exit 1
  fi
  sleep 0.05
done
if [[ ! -S "$socket_path" || ! -f "$render_scale_receipt" || ! -f "$isolated_marker_path" ]]; then
  printf 'error: isolated VoiceBar did not become ready; see %s\n' "$app_log" >&2
  exit 1
fi

frame_values=$(jq -er '[.frameX, .frameY] | map(round) | @tsv' "$render_scale_receipt")
read -r frame_x frame_y <<<"$frame_values"
if (( frame_x > offscreen_origin || frame_y > offscreen_origin )); then
  printf 'error: VoiceBar frame is not safely offscreen: %s,%s\n' "$frame_x" "$frame_y" >&2
  exit 1
fi

for state_name in idle recording transcribing speaking; do
  case "$state_name" in
    speaking)
      state_event=$(jq -cn '{type:"state",state:"speaking",text:"Offscreen event handling acceptance"}')
      ;;
    *)
      state_event=$(jq -cn --arg state "$state_name" '{type:"state",state:$state}')
      ;;
  esac
  printf '%s\n' "$state_event" | tee -a "$state_log" | nc -U "$socket_path"
  sleep 0.15
done

swift test --package-path "$repo_root/flow-bar" \
  --filter BarViewClickabilityTests/testPanelAppKitMouseEventsHitOnlyMountedControls
swift test --package-path "$repo_root/flow-bar" \
  --filter BarViewClickabilityTests/testTeleprompterAppKitMouseEventsPassThroughItsBody
env \
  VOICEBAR_REGENERATE_VISUAL_ARTIFACTS=1 \
  VOICEBAR_VISUAL_ARTIFACT_OUTPUT="$frame_dir" \
  swift test --package-path "$repo_root/flow-bar" \
    --filter BarViewSnapshotArtifactTests/testWritesOffscreenAppKitArtifactsForAllPrimaryVoiceModes

for frame_name in idle recording transcribing speaking; do
  if [[ ! -s "$frame_dir/$frame_name.png" ]]; then
    printf 'error: missing rendered state artifact %s\n' "$frame_name" >&2
    exit 1
  fi
done

kill "$app_pid"
wait "$app_pid"
app_pid=''
for _ in {1..100}; do
  [[ ! -S "$socket_path" && ! -f "$isolated_marker_path" ]] && break
  sleep 0.05
done
if [[ -S "$socket_path" || -f "$isolated_marker_path" ]]; then
  printf 'error: exact isolated VoiceBar cleanup left a socket or marker\n' >&2
  exit 1
fi

printf 'offscreen_origin=%s\n' "$offscreen_origin" >"$receipt_dir/acceptance.txt"
printf 'states=idle,recording,transcribing,speaking\n' >>"$receipt_dir/acceptance.txt"
printf 'EVENT_HANDLING_OFFSCREEN_ACCEPTANCE=%s\n' "$receipt_dir"
