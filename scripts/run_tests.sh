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
  rm -f "$MCP_SOCKET" "$MCP_PID_FILE" "$DISABLE_FLAG"
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

printf '\n== Karabiner CLI hotkey injection smoke ==\n'
karabiner_status=0
KARABINER_CLI="${KARABINER_CLI:-karabiner_cli}"
if ! command -v "$KARABINER_CLI" >/dev/null 2>&1; then
  printf '[fail] karabiner_cli not found: %s\n' "$KARABINER_CLI"
  karabiner_status=1
else
  # karabiner_cli does not synthesize physical keys; this toggles a dedicated
  # test variable through the same supported Karabiner control plane.
  "$KARABINER_CLI" --set-variables '{"voicebar_p4a_f6_down":1}'
  karabiner_down_status=$?
  "$KARABINER_CLI" --set-variables '{"voicebar_p4a_f6_down":0}'
  karabiner_up_status=$?
  karabiner_status=$((karabiner_down_status | karabiner_up_status))
fi
record_status "karabiner_cli variable injection" "$karabiner_status"

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
