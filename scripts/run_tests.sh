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
daemon_pid=""

mkdir -p "$RUN_DIR"

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
  if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null
    wait "$daemon_pid" 2>/dev/null
  fi
  rm -f "$MCP_SOCKET" "$VOICEBAR_SOCKET" "$MCP_PID_FILE" "$DISABLE_FLAG"
}

print_log_tail() {
  local label="$1"
  local path="$2"

  if [ -s "$path" ]; then
    printf '\n--- %s (%s) ---\n' "$label" "$path"
    tail -n 80 "$path"
  fi
}

trap cleanup EXIT

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
swift build --package-path "$FLOW_BAR_DIR"
swift_build_status=$?
record_status "swift build" "$swift_build_status"

printf '\n== XCTest ==\n'
swift test --package-path "$FLOW_BAR_DIR"
swift_test_status=$?

if [ "${VOICELAYER_RUN_TESTS_FORCE_SWIFT_FAIL:-0}" = "1" ]; then
  printf '[forced] VOICELAYER_RUN_TESTS_FORCE_SWIFT_FAIL=1\n'
  swift_test_status=$((swift_test_status | 1))
fi
record_status "swift test" "$swift_test_status"

printf '\n== Bun MCP daemon boot ==\n'
(
  cd "$ROOT_DIR" || exit 1
  QA_VOICE_MCP_SOCKET_PATH="$MCP_SOCKET" \
    QA_VOICE_SOCKET_PATH="$VOICEBAR_SOCKET" \
    QA_VOICE_MCP_PID_PATH="$MCP_PID_FILE" \
    QA_VOICE_DISABLE_FLAG_PATH="$DISABLE_FLAG" \
    bun run src/mcp-server-daemon.ts
) >"$DAEMON_OUT" 2>"$DAEMON_ERR" &
daemon_pid=$!

daemon_status=1
for _ in $(seq 1 150); do
  if [ -S "$MCP_SOCKET" ]; then
    daemon_status=0
    break
  fi
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    daemon_status=1
    break
  fi
  sleep 0.1
done
record_status "bun MCP daemon boot" "$daemon_status"

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
  VOICELAYER_FIXTURE_DIR="$FIXTURE_DIR" bun test
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
