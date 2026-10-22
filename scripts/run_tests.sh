#!/usr/bin/env bash

# VoiceLayer cross-language regression gate.
# Do not use `set -e`: Phase 4 requires explicit bitwise-OR aggregation so
# Swift and Bun failures are both observed before returning one pass/fail bit.
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW_BAR_DIR="$ROOT_DIR/flow-bar"
FIXTURE_DIR="$FLOW_BAR_DIR/Tests/VoiceBarTests/Fixtures"
RUN_DIR="${TMPDIR:-/tmp}/voicelayer-run-tests.$$"
MCP_SOCKET="$RUN_DIR/voicelayer-mcp.sock"
VOICEBAR_SOCKET="$RUN_DIR/voicelayer.sock"
MCP_PID_FILE="$RUN_DIR/voicelayer-mcp.pid"
DISABLE_FLAG="$RUN_DIR/voicelayer-disabled"
DAEMON_OUT="$RUN_DIR/mcp-daemon.out.log"
DAEMON_ERR="$RUN_DIR/mcp-daemon.err.log"

exit_status=0
supervisor_pid=""

record_status() {
  local label="$1"
  local status="$2"

  if [ "$status" -eq 0 ]; then
    printf '[pass] %s\n' "$label"
  else
    printf '[fail] %s exited %s\n' "$label" "$status"
  fi

  exit_status=$((exit_status | status))
}

cleanup() {
  local status=$?
  trap '' HUP INT TERM
  if [ -n "$supervisor_pid" ]; then
    kill "$supervisor_pid" 2>/dev/null
    wait "$supervisor_pid" 2>/dev/null
  fi
  # The detached supervisor may itself have been SIGKILLed. Read its child's
  # persisted identity and reap the verified run group BEFORE deleting state.
  if ! python3 "$ROOT_DIR/scripts/supervise-test-daemon.py" --cleanup "$RUN_DIR"; then
    printf '[fail] daemon cleanup failed; retaining %s\n' "$RUN_DIR" >&2
    exit 1
  fi
  # Opt in to retaining logs/state for debugging; never retain processes.
  if [ "${VOICELAYER_RUN_TESTS_KEEP_RUN_DIR:-0}" != "1" ]; then
    rm -rf "$RUN_DIR"
  fi
  return "$status"
}

print_log_tail() {
  local label="$1"
  local path="$2"

  if [ -s "$path" ]; then
    printf '\n--- %s (%s) ---\n' "$label" "$path"
    tail -n 80 "$path"
  fi
}

# Never adopt another run's directory (including after PID reuse). Establish
# detached cleanup ownership before any Swift phase can run.
python3 "$ROOT_DIR/scripts/supervise-test-daemon.py" --sweep || exit 1
mkdir -m 700 "$RUN_DIR" || exit 1
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

(
  cd "$ROOT_DIR" || exit 1
  # Keep HOME-derived logs/caches and all runtime state inside this smoke run.
  exec env HOME="$RUN_DIR" \
    VOICELAYER_STATE_DIR="$RUN_DIR/state" \
    VOICELAYER_TMP_ROOT="$RUN_DIR" \
    VOICELAYER_CONTROL_LAYER_BASE="$RUN_DIR/journal" \
    VOICELAYER_MCP_SOCKET_PATH="$MCP_SOCKET" \
    VOICELAYER_SOCKET_PATH="$VOICEBAR_SOCKET" \
    QA_VOICE_STT_BACKEND=wispr \
    QA_VOICE_STT_POLISH=off \
    QA_VOICE_MCP_SOCKET_PATH="$MCP_SOCKET" \
    QA_VOICE_SOCKET_PATH="$VOICEBAR_SOCKET" \
    QA_VOICE_MCP_PID_PATH="$MCP_PID_FILE" \
    QA_VOICE_MCP_HEARTBEAT_PATH="$RUN_DIR/voicelayer-mcp.heartbeat" \
    QA_VOICE_DISABLE_FLAG_PATH="$DISABLE_FLAG" \
    VOICELAYER_ALLOW_ORPHAN_DAEMON=1 \
    python3 "$ROOT_DIR/scripts/supervise-test-daemon.py" "$$" "$RUN_DIR" \
      bun run src/mcp-server-daemon.ts
) >"$DAEMON_OUT" 2>"$DAEMON_ERR" &
supervisor_pid=$!
for _ in $(seq 1 100); do
  if [ -f "$RUN_DIR/supervisor-ready" ] || ! kill -0 "$supervisor_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [ ! -f "$RUN_DIR/supervisor-ready" ]; then
  printf '[fail] detached cleanup supervisor did not become ready\n'
  exit 1
fi

printf 'VoiceLayer regression gate\n'
printf 'repo: %s\n' "$ROOT_DIR"
printf 'fixtures: %s\n' "$FIXTURE_DIR"

missing_fixture=0
for fixture in zero_rms.wav clean_speech.wav high_noise.wav; do
  if [ ! -f "$FIXTURE_DIR/$fixture" ]; then
    printf '[fail] missing fixture: %s\n' "$FIXTURE_DIR/$fixture"
    missing_fixture=1
  else
    printf '[ok] fixture present: %s\n' "$fixture"
  fi
done
record_status "fixture inventory" "$missing_fixture"

printf '\n== Swift build ==\n'
swift build --scratch-path "$ROOT_DIR/.build.noindex/swift" --package-path "$FLOW_BAR_DIR"
swift_build_status=$?
record_status "swift build" "$swift_build_status"

printf '\n== XCTest ==\n'
VOICEBAR_SNAPSHOTS=1 VOICEBAR_SNAPSHOTS_RECORD=0 swift test --scratch-path "$ROOT_DIR/.build.noindex/swift" --package-path "$FLOW_BAR_DIR"
swift_test_status=$?

if [ "${VOICELAYER_RUN_TESTS_FORCE_SWIFT_FAIL:-0}" = "1" ]; then
  printf '[forced] VOICELAYER_RUN_TESTS_FORCE_SWIFT_FAIL=1\n'
  swift_test_status=$((swift_test_status | 1))
fi
record_status "swift test" "$swift_test_status"

printf '\n== Bun MCP daemon boot ==\n'
# Start exactly once, after Swift; the early supervisor has only been cleaning.
kill -USR2 "$supervisor_pid" 2>/dev/null

daemon_status=1
for _ in $(seq 1 150); do
  if [ -S "$MCP_SOCKET" ]; then
    daemon_status=0
    break
  fi
  if [ -f "$RUN_DIR/daemon-reaped" ] || ! kill -0 "$supervisor_pid" 2>/dev/null; then
    daemon_status=1
    break
  fi
  sleep 0.1
done
record_status "bun MCP daemon boot" "$daemon_status"

# Boot smoke is complete; do not leave its daemon alive during the test suites.
# Its periodic log rotator still targets production /tmp logs.
# USR1 stops/reaps the daemon group; the supervisor remains until EXIT so it
# can remove RUN_DIR even if the shell is killed during the later Bun suite.
kill -USR1 "$supervisor_pid" 2>/dev/null
while [ ! -f "$RUN_DIR/daemon-reaped" ] && kill -0 "$supervisor_pid" 2>/dev/null; do
  sleep 0.05
done
if ! kill -0 "$supervisor_pid" 2>/dev/null; then
  printf '[fail] cleanup supervisor exited during daemon smoke\n'
  exit_status=$((exit_status | 1))
fi

printf '\n== F5 hidutil LaunchAgent smoke ==\n'
hidutil_plist_status=0
HIDUTIL_PLIST="$ROOT_DIR/launchd/com.voicelayer.f5-to-f18-hidutil.plist"
HIDUTIL_HELPER="$ROOT_DIR/scripts/apply-voicebar-f5-hidutil.sh"
if [ ! -f "$HIDUTIL_PLIST" ]; then
  printf '[fail] missing hidutil plist: %s\n' "$HIDUTIL_PLIST"
  hidutil_plist_status=1
elif ! plutil -lint "$HIDUTIL_PLIST" >/dev/null; then
  printf '[fail] invalid hidutil plist: %s\n' "$HIDUTIL_PLIST"
  hidutil_plist_status=1
elif ! grep -q 'apply-voicebar-f5-hidutil.sh' "$HIDUTIL_PLIST"; then
  printf '[fail] hidutil plist does not run merge helper\n'
  hidutil_plist_status=1
elif [ ! -f "$HIDUTIL_HELPER" ]; then
  printf '[fail] missing hidutil helper: %s\n' "$HIDUTIL_HELPER"
  hidutil_plist_status=1
elif ! grep -q '30064771134' "$HIDUTIL_HELPER" || \
  ! grep -q '51539607759' "$HIDUTIL_HELPER" || \
  ! grep -q '30064771181' "$HIDUTIL_HELPER" || \
  ! grep -q 'preserved.push' "$HIDUTIL_HELPER"; then
  printf '[fail] hidutil helper does not merge F5/Dictation to F18\n'
  hidutil_plist_status=1
fi
record_status "hidutil F5 relay plist" "$hidutil_plist_status"

printf '\n== Bun tests ==\n'
(
  cd "$ROOT_DIR" || exit 1
  # Bun 1.3.9 has no discovery-ignore option. Explicit directories retain all
  # tracked Bun tests without scanning docs.local (even its nested src/tests).
  # https://github.com/oven-sh/bun/blob/bun-v1.3.9/docs/test/discovery.mdx
  VOICELAYER_FIXTURE_DIR="$FIXTURE_DIR" bun test ./src ./tests ./site
)
bun_status=$?

if [ "${VOICELAYER_RUN_TESTS_FORCE_BUN_FAIL:-0}" = "1" ]; then
  printf '[forced] VOICELAYER_RUN_TESTS_FORCE_BUN_FAIL=1\n'
  bun_status=$((bun_status | 1))
fi
record_status "bun test" "$bun_status"

printf '\n== Aggregate ==\n'
printf 'bitwise_or_exit=%s\n' "$exit_status"

if [ "$exit_status" -ne 0 ]; then
  print_log_tail "MCP daemon stdout" "$DAEMON_OUT"
  print_log_tail "MCP daemon stderr" "$DAEMON_ERR"
  exit "$exit_status"
fi

printf 'VoiceLayer regression gate passed.\n'
exit 0
