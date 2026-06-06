#!/usr/bin/env bash
# Automated F5 runtime verification wrapper for scripts/voicelayer-verify.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="${VOICELAYER_AUTO_F5_REPO_ROOT:-$DEFAULT_REPO_ROOT}"
VERIFY_SCRIPT="${VOICELAYER_AUTO_F5_VERIFY_SCRIPT:-$REPO_ROOT/scripts/voicelayer-verify.sh}"
WORK_DIR="${VOICELAYER_AUTO_F5_WORK_DIR:-${TMPDIR:-/tmp}/voicelayer-auto-f5}"
MAIN_REPO_ROOT="${VOICELAYER_AUTO_F5_MAIN_REPO_ROOT:-}"
UTTERANCE="${VOICELAYER_AUTO_F5_UTTERANCE:-verification test}"
EDGE_TTS_VOICE="${VOICELAYER_AUTO_F5_EDGE_TTS_VOICE:-en-US-AriaNeural}"
IDLE_THRESHOLD_SECONDS="${VOICELAYER_AUTO_F5_IDLE_THRESHOLD_SECONDS:-120}"
TARGET_OUTPUT_VOLUME="${VOICELAYER_AUTO_F5_OUTPUT_VOLUME:-70}"
RECORD_SECONDS="${VOICELAYER_AUTO_F5_RECORD_SECONDS:-6}"
PASTE_TIMEOUT_SECONDS="${VOICELAYER_AUTO_F5_PASTE_TIMEOUT_SECONDS:-120}"
F5_SENDER="${VOICELAYER_AUTO_F5_SENDER:-swift}"
VERIFY_TESTER="${VOICELAYER_VERIFY_TESTER:-auto-F5-etan-consented-live}"
VOICEBAR_SOCKET_PATH="${QA_VOICE_SOCKET_PATH:-/tmp/voicelayer.sock}"
RESTORE_MAIN_ON_FAILURE="${VOICELAYER_AUTO_F5_RESTORE_ON_FAILURE:-1}"
VOICEBAR_LAUNCHD_LABEL="${VOICELAYER_AUTO_F5_VOICEBAR_LABEL:-com.voicelayer.voicebar}"
MCP_DAEMON_LAUNCHD_LABEL="${VOICELAYER_AUTO_F5_MCP_DAEMON_LABEL:-com.voicelayer.mcp-daemon}"

AUDIO_FILE="$WORK_DIR/verification-test-with-leading-silence.wav"
SINK_FILE="${VOICELAYER_AUTO_F5_SINK_FILE:-$WORK_DIR/af5-paste-sink.txt}"
LOG_FILE="${VOICELAYER_AUTO_F5_LOG_FILE:-$WORK_DIR/auto-f5-run.log}"

AUDIO_LOOP_PID=""
VERIFY_PID=""
VERIFY_FIFO=""
VERIFY_STDIN_OPEN=0
PREVIOUS_VOLUME=""
PREVIOUS_MUTED=""
BRANCH_BUILD_INSTALLED=0
RESTORE_MAIN_ATTEMPTED=0

log() {
  printf '[auto-f5] %s\n' "$*"
}

die() {
  printf '[auto-f5] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    die "required command not found: $name"
  fi
}

normalize_for_verification_match() {
  local value="$1"
  printf '%s' "$value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^[:alnum:]]/ /g' \
    | awk '{$1=$1; print}'
}

sink_contains_verification() {
  local normalized
  normalized="$(normalize_for_verification_match "$1")"
  [[ "$normalized" =~ (^|[[:space:]])verification[[:space:]]+tests?($|[[:space:]]) ]]
}

hid_idle_ns_to_seconds() {
  local idle_ns="$1"
  [[ "$idle_ns" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((idle_ns / 1000000000))"
}

user_idle_ns_meets_threshold() {
  local idle_ns="$1"
  local threshold_seconds="$2"
  [[ "$idle_ns" =~ ^[0-9]+$ ]] || return 1
  [[ "$threshold_seconds" =~ ^[0-9]+$ ]] || return 1
  (( idle_ns >= threshold_seconds * 1000000000 ))
}

format_auto_provenance() {
  local audio_hash="$1"
  local audio_file="$2"
  printf 'Tester: auto-F5 (programmatic, no human)\n'
  printf 'Loop-Audio-SHA256: %s\n' "$audio_hash"
  printf 'Loop-Audio-File: %s\n' "$audio_file"
}

artifact_path_from_verify_log() {
  local verify_log="$1"
  local path
  path="$(
    printf '%s\n' "$verify_log" \
      | awk -F'wrote runtime artifact: ' '/wrote runtime artifact: / { print $2 }' \
      | tail -n 1
  )"
  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

resolve_main_repo_root() {
  if [ -n "${MAIN_REPO_ROOT:-}" ]; then
    [ -d "$MAIN_REPO_ROOT" ] || return 1
    printf '%s\n' "$MAIN_REPO_ROOT"
    return 0
  fi

  local root=""
  local line
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) root="${line#worktree }" ;;
      branch\ refs/heads/main)
        [ -n "$root" ] || return 1
        printf '%s\n' "$root"
        return 0
        ;;
    esac
  done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null)

  return 1
}

kickstart_launchd_service() {
  local label="$1"
  local domain="gui/$(id -u)"
  local service="$domain/$label"

  if ! command -v launchctl >/dev/null 2>&1; then
    log "launchctl not found; cannot kickstart $label"
    return 1
  fi

  if launchctl kickstart -k "$service" >/dev/null 2>&1; then
    log "kickstarted launchd service: $service"
    return 0
  fi

  local plist="$HOME/Library/LaunchAgents/$label.plist"
  if [ -f "$plist" ]; then
    launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 || true
    if launchctl kickstart -k "$service" >/dev/null 2>&1; then
      log "bootstrapped and kickstarted launchd service: $service"
      return 0
    fi
  fi

  log "could not kickstart launchd service: $service"
  return 1
}

restore_last_known_good_main_build() {
  [ "$RESTORE_MAIN_ON_FAILURE" = "1" ] || return 0
  [ "$RESTORE_MAIN_ATTEMPTED" -eq 0 ] || return 0
  RESTORE_MAIN_ATTEMPTED=1

  local main_root
  if ! main_root="$(resolve_main_repo_root)"; then
    log "failed to restore main VoiceBar build: could not resolve main checkout"
    return 1
  fi

  if [ ! -f "$main_root/flow-bar/build-app.sh" ]; then
    log "failed to restore main VoiceBar build: missing $main_root/flow-bar/build-app.sh"
    return 1
  fi

  log "restoring installed VoiceBar.app from main checkout: $main_root"
  if ! (cd "$main_root" && bash flow-bar/build-app.sh); then
    log "failed to rebuild VoiceBar.app from main checkout"
    return 1
  fi

  local restored=0
  kickstart_launchd_service "$MCP_DAEMON_LAUNCHD_LABEL" || restored=1
  kickstart_launchd_service "$VOICEBAR_LAUNCHD_LABEL" || restored=1
  return "$restored"
}

branch_build_was_installed() {
  [ "$BRANCH_BUILD_INSTALLED" -eq 1 ] && return 0
  [ -f "${LOG_FILE:-}" ] || return 1
  grep -qF "[voicelayer-verify] relaunching VoiceBar.app" "$LOG_FILE"
}

recording_state_from_health_json() {
  local health_json="$1"
  printf '%s' "$health_json" \
    | sed -n 's/.*"recording_state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

recording_state_is_busy() {
  case "$1" in
    recording|transcribing) return 0 ;;
    *) return 1 ;;
  esac
}

read_hid_idle_ns() {
  local hid_report
  hid_report="$(ioreg -c IOHIDSystem)"
  awk '/HIDIdleTime/ { print $NF; exit }' <<<"$hid_report"
}

assert_user_idle_window() {
  local idle_ns
  local idle_seconds
  idle_ns="$(read_hid_idle_ns)"
  [[ "$idle_ns" =~ ^[0-9]+$ ]] || die "could not read HIDIdleTime from ioreg"
  idle_seconds="$(hid_idle_ns_to_seconds "$idle_ns")"

  if ! user_idle_ns_meets_threshold "$idle_ns" "$IDLE_THRESHOLD_SECONDS"; then
    die "recent keyboard/mouse input detected (${idle_seconds}s idle; need ${IDLE_THRESHOLD_SECONDS}s)"
  fi

  log "user idle gate passed (${idle_seconds}s idle; threshold ${IDLE_THRESHOLD_SECONDS}s)"
}

voicebar_health_json() {
  local socket_path="$1"
  [ -S "$socket_path" ] || return 1
  python3 - "$socket_path" <<'PY'
import socket
import sys

path = sys.argv[1]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(1.0)
client.connect(path)
client.sendall(b'{"cmd":"health"}\n')
data = b""
while not data.endswith(b"\n"):
    chunk = client.recv(4096)
    if not chunk:
        break
    data += chunk
client.close()
if data:
    print(data.decode("utf-8", errors="replace").splitlines()[0])
PY
}

recording_state_from_shared_source() {
  local source_path="$REPO_ROOT/src/recording-state.ts"
  [ -f "$source_path" ] || return 1

  (
    cd "$REPO_ROOT"
    bun --silent -e '
      const mod = await import("./src/recording-state.ts");
      const reader = mod.getRecordingState ?? mod.readRecordingState;
      const state = typeof reader === "function" ? await reader() : mod.recordingState;
      if (typeof state === "string") console.log(state);
    ' 2>/dev/null
  )
}

assert_no_recording_in_progress() {
  local state=""
  local health=""

  if state="$(recording_state_from_shared_source 2>/dev/null)"; then
    if recording_state_is_busy "$state"; then
      die "recording already in progress according to src/recording-state.ts: $state"
    fi
    log "shared recording-state gate passed ($state)"
  fi

  if health="$(voicebar_health_json "$VOICEBAR_SOCKET_PATH" 2>/dev/null)"; then
    state="$(recording_state_from_health_json "$health")"
    if recording_state_is_busy "$state"; then
      die "recording already in progress according to VoiceBar health: $state"
    fi
    [ -n "$state" ] && log "VoiceBar health gate passed (recording_state=$state)"
  else
    log "VoiceBar health unavailable at $VOICEBAR_SOCKET_PATH; falling back to process check"
  fi

  if pgrep -x rec >/dev/null 2>&1; then
    die "recording already in progress: rec process is running"
  fi
  log "process recording gate passed (no rec process)"
}

capture_system_volume() {
  local settings
  settings="$(
    osascript \
      -e 'set s to get volume settings' \
      -e 'return (output volume of s as string) & ":" & (output muted of s as string)'
  )"
  PREVIOUS_VOLUME="${settings%%:*}"
  PREVIOUS_MUTED="${settings#*:}"
  [[ "$PREVIOUS_VOLUME" =~ ^[0-9]+$ ]] || die "could not read current output volume"
  log "captured current output volume: ${PREVIOUS_VOLUME}, muted=${PREVIOUS_MUTED}"
}

set_system_volume_for_capture() {
  osascript \
    -e "set volume output volume $TARGET_OUTPUT_VOLUME" \
    -e 'set volume without output muted' >/dev/null
  log "set output volume to $TARGET_OUTPUT_VOLUME for speaker-to-mic capture"
}

restore_system_volume() {
  [ -n "${PREVIOUS_VOLUME:-}" ] || return 0
  osascript -e "set volume output volume $PREVIOUS_VOLUME" >/dev/null || true
  if [ "${PREVIOUS_MUTED:-false}" = "true" ]; then
    osascript -e 'set volume with output muted' >/dev/null || true
  else
    osascript -e 'set volume without output muted' >/dev/null || true
  fi
  log "restored output volume to $PREVIOUS_VOLUME, muted=${PREVIOUS_MUTED:-false}"
  PREVIOUS_VOLUME=""
  PREVIOUS_MUTED=""
}

generate_loop_audio() {
  mkdir -p "$WORK_DIR"
  if [ -s "$AUDIO_FILE" ]; then
    log "reusing loop audio: $AUDIO_FILE"
    return 0
  fi

  require_command python3
  require_command ffmpeg

  local raw_audio
  local tmp_audio
  raw_audio="$(mktemp "$WORK_DIR/edge-tts-raw.XXXXXX.mp3")"
  tmp_audio="$(mktemp "$WORK_DIR/verification-loop.XXXXXX.wav")"
  rm -f "$tmp_audio"

  log "generating loop audio with python3 -m edge_tts"
  python3 -m edge_tts \
    --voice "$EDGE_TTS_VOICE" \
    --text "$UTTERANCE" \
    --write-media "$raw_audio" >/dev/null

  log "prepending 2s silence and writing wav: $AUDIO_FILE"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -t 2 -i anullsrc=channel_layout=mono:sample_rate=24000 \
    -i "$raw_audio" \
    -filter_complex '[0:a][1:a]concat=n=2:v=0:a=1' \
    -ar 24000 -ac 1 "$tmp_audio"

  mv "$tmp_audio" "$AUDIO_FILE"
  rm -f "$raw_audio"
}

audio_hash() {
  shasum -a 256 "$AUDIO_FILE" | awk '{ print $1 }'
}

start_audio_loop() {
  require_command afplay
  [ -s "$AUDIO_FILE" ] || die "loop audio missing: $AUDIO_FILE"
  (
    while :; do
      afplay "$AUDIO_FILE"
    done
  ) &
  AUDIO_LOOP_PID="$!"
  log "started loop audio with afplay pid=$AUDIO_LOOP_PID"
}

stop_audio_loop() {
  [ -n "${AUDIO_LOOP_PID:-}" ] || return 0
  if kill -0 "$AUDIO_LOOP_PID" >/dev/null 2>&1; then
    kill "$AUDIO_LOOP_PID" >/dev/null 2>&1 || true
    wait "$AUDIO_LOOP_PID" >/dev/null 2>&1 || true
  fi
  AUDIO_LOOP_PID=""
  pkill -P "$$" afplay >/dev/null 2>&1 || true
  log "stopped loop audio"
}

send_f5_osascript() {
  osascript -e 'tell application "System Events" to key code 96' >/dev/null
}

send_f5_swift() {
  local tap_count="${1:-1}"
  local inter_tap_delay_us="${2:-0}"
  require_command swift
  local swift_file
  swift_file="$(mktemp "$WORK_DIR/send-f5.XXXXXX.swift")"
  cat >"$swift_file" <<'SWIFT'
import CoreGraphics
import Foundation

let keyCode: CGKeyCode = 96
let tapCount = max(1, Int(CommandLine.arguments.dropFirst().first ?? "1") ?? 1)
let interTapDelayUs = useconds_t(max(0, Int(CommandLine.arguments.dropFirst(2).first ?? "0") ?? 0))
let source = CGEventSource(stateID: .hidSystemState)

for index in 0..<tapCount {
  let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)!
  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)!
  down.post(tap: .cghidEventTap)
  usleep(50_000)
  up.post(tap: .cghidEventTap)
  if index + 1 < tapCount {
    usleep(interTapDelayUs)
  }
}
SWIFT
  swift "$swift_file" "$tap_count" "$inter_tap_delay_us" >/dev/null
  rm -f "$swift_file"
}

send_f5_once() {
  case "$F5_SENDER" in
    osascript) send_f5_osascript ;;
    swift) send_f5_swift ;;
    *) die "unknown F5 sender '$F5_SENDER' (expected osascript or swift)" ;;
  esac
}

send_f5_start_locked() {
  log "sending double-F5 to start locked VoiceBar recording"
  if [ "$F5_SENDER" = "swift" ]; then
    send_f5_swift 2 120000
    return
  fi
  send_f5_once
  sleep 0.12
  send_f5_once
}

send_f5_stop() {
  log "sending F5 to stop VoiceBar recording"
  send_f5_once
}

prepare_textedit_sink() {
  mkdir -p "$WORK_DIR"
  : >"$SINK_FILE"
  open -a TextEdit "$SINK_FILE"
  osascript <<'OSA'
tell application "TextEdit"
  activate
  if (count of documents) = 0 then
    make new document
  end if
  set text of front document to ""
end tell
delay 0.2
tell application "System Events"
  tell process "TextEdit"
    set frontmost to true
    keystroke "a" using command down
    key code 51
  end tell
end tell
OSA
  log "focused TextEdit paste sink: $SINK_FILE"
}

read_textedit_sink() {
  osascript <<'OSA'
tell application "TextEdit"
  if (count of documents) = 0 then
    return ""
  end if
  return text of front document
end tell
OSA
}

wait_for_sink_match() {
  local timeout_seconds="$1"
  local start_time
  local now
  local content
  start_time="$(date +%s)"

  while :; do
    content="$(read_textedit_sink 2>/dev/null || true)"
    printf '%s\n' "$content" >"$SINK_FILE"
    if sink_contains_verification "$content"; then
      log "paste sink matched expected phrase"
      return 0
    fi

    now="$(date +%s)"
    if (( now - start_time >= timeout_seconds )); then
      log "paste sink did not match within ${timeout_seconds}s; last content: $(printf '%s' "$content" | tr '\n' ' ')"
      return 1
    fi
    sleep 1
  done
}

wait_for_log_pattern() {
  local pattern="$1"
  local timeout_seconds="$2"
  local start_time
  local now
  start_time="$(date +%s)"

  while :; do
    if [ -f "$LOG_FILE" ] && grep -qF "$pattern" "$LOG_FILE"; then
      return 0
    fi
    if [ -n "${VERIFY_PID:-}" ] && ! kill -0 "$VERIFY_PID" >/dev/null 2>&1; then
      return 1
    fi
    now="$(date +%s)"
    if (( now - start_time >= timeout_seconds )); then
      return 1
    fi
    sleep 0.2
  done
}

wait_for_verify_runtime_prompt() {
  local relaunch_answered=0
  local start_time
  local now
  start_time="$(date +%s)"

  while :; do
    if [ -f "$LOG_FILE" ] && grep -qF "Press F5 in VoiceBar" "$LOG_FILE"; then
      BRANCH_BUILD_INSTALLED=1
      log "voicelayer-verify runtime prompt reached"
      return 0
    fi

    if [ "$relaunch_answered" -eq 0 ] \
      && [ -f "$LOG_FILE" ] \
      && grep -qF "Rebuild, stop the running VoiceBar" "$LOG_FILE"; then
      log "answering voicelayer-verify relaunch prompt"
      printf 'Y\n' >&3
      relaunch_answered=1
    fi

    if [ -n "${VERIFY_PID:-}" ] && ! kill -0 "$VERIFY_PID" >/dev/null 2>&1; then
      return 1
    fi

    now="$(date +%s)"
    if (( now - start_time >= 900 )); then
      return 1
    fi
    sleep 0.2
  done
}

start_verify_process() {
  rm -f "$LOG_FILE"
  mkdir -p "$WORK_DIR"
  VERIFY_FIFO="$(mktemp -u "$WORK_DIR/verify-stdin.XXXXXX")"
  mkfifo "$VERIFY_FIFO"
  exec 3<>"$VERIFY_FIFO"
  VERIFY_STDIN_OPEN=1

  (
    VOICELAYER_VERIFY_TESTER="$VERIFY_TESTER" \
      VOICELAYER_VERIFY_REPO_ROOT="$REPO_ROOT" \
      bash "$VERIFY_SCRIPT" --force <"$VERIFY_FIFO"
  ) > >(tee -a "$LOG_FILE") 2>&1 &
  VERIFY_PID="$!"
  log "started voicelayer-verify wrapper process pid=$VERIFY_PID"
}

close_verify_stdin() {
  if [ "$VERIFY_STDIN_OPEN" -eq 1 ]; then
    exec 3>&-
    exec 3<&-
    VERIFY_STDIN_OPEN=0
  fi
}

run_f5_capture_cycle() {
  prepare_textedit_sink
  start_audio_loop
  sleep 0.2
  send_f5_start_locked
  sleep "$RECORD_SECONDS"
  send_f5_stop
  stop_audio_loop

  if wait_for_sink_match "$PASTE_TIMEOUT_SECONDS"; then
    log "non-human paste proof passed; feeding Y to voicelayer-verify"
    printf 'Y\n' >&3
    return 0
  fi

  log "non-human paste proof failed; feeding n to voicelayer-verify"
  printf 'n\n' >&3 || true
  return 1
}

ensure_auto_provenance() {
  local artifact="$1"
  local hash="$2"
  local audio_file="$3"
  local tmp_artifact

  [ -f "$artifact" ] || die "artifact not found for provenance append: $artifact"
  tmp_artifact="$(mktemp "${artifact}.tmp.XXXXXX")"
  grep -v -E '^(Tester: auto-F5 \(programmatic, no human\)|Loop-Audio-SHA256:|Loop-Audio-File:)' \
    "$artifact" >"$tmp_artifact" || true
  format_auto_provenance "$hash" "$audio_file" >>"$tmp_artifact"
  mv "$tmp_artifact" "$artifact"
}

cleanup() {
  local status=$?
  set +e
  stop_audio_loop
  if [ -n "${VERIFY_PID:-}" ] && kill -0 "$VERIFY_PID" >/dev/null 2>&1; then
    kill "$VERIFY_PID" >/dev/null 2>&1 || true
    wait "$VERIFY_PID" >/dev/null 2>&1 || true
  fi
  close_verify_stdin
  [ -n "${VERIFY_FIFO:-}" ] && rm -f "$VERIFY_FIFO"
  restore_system_volume
  if [ "$status" -ne 0 ] && branch_build_was_installed; then
    restore_last_known_good_main_build \
      || log "WARNING: failed to restore installed app to main after rejected auto-F5 cycle"
  fi
  return "$status"
}

main() {
  require_command osascript
  require_command open
  require_command ioreg
  require_command pgrep
  require_command shasum
  [ -x "$VERIFY_SCRIPT" ] || die "voicelayer verifier not executable: $VERIFY_SCRIPT"

  trap cleanup EXIT

  assert_user_idle_window
  assert_no_recording_in_progress
  generate_loop_audio
  local hash
  hash="$(audio_hash)"
  log "loop audio sha256: $hash"

  capture_system_volume
  set_system_volume_for_capture

  start_verify_process
  if ! wait_for_verify_runtime_prompt; then
    die "voicelayer-verify did not reach the runtime F5 prompt; see $LOG_FILE"
  fi

  if ! run_f5_capture_cycle; then
    die "auto-F5 paste proof failed; see $SINK_FILE and $LOG_FILE"
  fi

  close_verify_stdin
  if ! wait "$VERIFY_PID"; then
    VERIFY_PID=""
    die "voicelayer-verify exited non-zero; see $LOG_FILE"
  fi
  VERIFY_PID=""

  local verify_log
  local artifact
  verify_log="$(<"$LOG_FILE")"
  artifact="$(artifact_path_from_verify_log "$verify_log")" \
    || die "could not find verifier artifact path in $LOG_FILE"

  ensure_auto_provenance "$artifact" "$hash" "$AUDIO_FILE"
  log "ensured auto provenance in artifact: $artifact"
  log "paste sink snapshot: $SINK_FILE"
  log "full run log: $LOG_FILE"
  printf 'AUTO_F5_ARTIFACT=%s\n' "$artifact"
  printf 'AUTO_F5_LOG=%s\n' "$LOG_FILE"
  printf 'AUTO_F5_SINK=%s\n' "$SINK_FILE"
}

if [ "${VOICELAYER_AUTO_F5_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
