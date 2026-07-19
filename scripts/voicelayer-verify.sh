#!/usr/bin/env bash
# Runtime verification gate for VoiceLayer daemon/socket/MCP changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPO_ROOT="${VOICELAYER_VERIFY_REPO_ROOT:-$DEFAULT_REPO_ROOT}"
VERIFY_DIR="$REPO_ROOT/.verified"
MCP_SOCKET_PATH="${QA_VOICE_MCP_SOCKET_PATH:-/tmp/voicelayer-mcp.sock}"
VOICEBAR_LAUNCHD_LABEL="com.voicelayer.voicebar"
FORCE=0
VERIFY_MODE="${VOICELAYER_VERIFY_MODE:-interactive}"
CORPUS_COUNT="${VOICELAYER_VERIFY_CORPUS_COUNT:-10}"

usage() {
  cat <<'USAGE'
Usage: scripts/voicelayer-verify.sh [--force] [--corpus [N]]

Rebuilds VoiceBar.app and requires a real F5 dictation/paste smoke test when
the current branch touches VoiceLayer daemon/socket/MCP surfaces.

--corpus [N] boots an isolated daemon, replays the first N recordings from the
pinned scripts/corpus-replay-manifest.txt set (default: 10), runs the
interaction-event and F5-finish-paste-into-terminal legs, and requires no human
input. Override the frozen set with VOICELAYER_VERIFY_CORPUS_MANIFEST when
intentionally certifying another corpus.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --corpus)
      VERIFY_MODE="corpus"
      if [ "${2:-}" != "" ] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        CORPUS_COUNT="$2"
        shift 2
      else
        shift
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '[voicelayer-verify] unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$VERIFY_MODE" != "interactive" ] && [ "$VERIFY_MODE" != "corpus" ]; then
  printf '[voicelayer-verify] unknown VOICELAYER_VERIFY_MODE: %s\n' "$VERIFY_MODE" >&2
  exit 2
fi
if [ "$VERIFY_MODE" = "corpus" ] && ! [[ "$CORPUS_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  printf '[voicelayer-verify] corpus count must be a positive integer: %s\n' "$CORPUS_COUNT" >&2
  exit 2
fi

REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
DEFAULT_GIT_DIR="$(git -C "$DEFAULT_REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
VERIFY_GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ "$VERIFY_MODE" = "corpus" ] && {
  [ "$REPO_ROOT" = "$DEFAULT_REPO_ROOT" ] ||
    { [ -n "$DEFAULT_GIT_DIR" ] && [ "$VERIFY_GIT_DIR" = "$DEFAULT_GIT_DIR" ]; };
} && {
  [ -n "${VOICELAYER_VERIFY_CORPUS_RUNNER:-}" ] ||
    [ -n "${VOICELAYER_VERIFY_INTERACTION_RUNNER:-}" ];
}; then
  printf '[voicelayer-verify] runner overrides are test-only and cannot certify this repository.\n' >&2
  exit 2
fi

cd "$REPO_ROOT"

daemon_path_matches() {
  case "$1" in
    flow-bar/*) return 0 ;;
    src/whisper-server.ts) return 0 ;;
    src/mcp-server*.ts) return 0 ;;
    src/mcp-daemon.ts) return 0 ;;
    src/mcp-framing.ts) return 0 ;;
    src/mcp-handler.ts) return 0 ;;
    src/mcp-socket-owner.ts) return 0 ;;
    src/mcp-tools.ts) return 0 ;;
    src/daemon.ts) return 0 ;;
    src/daemon-health.ts) return 0 ;;
    src/log-rotation.ts) return 0 ;;
    src/paths.ts) return 0 ;;
    src/process-lock.ts) return 0 ;;
    src/recording-state.ts) return 0 ;;
    src/resolve-binary.ts) return 0 ;;
    src/socket-*.ts) return 0 ;;
    src/voicesdk/*) return 0 ;;
    src/soundlayer/*) return 0 ;;
    src/cli/voicelayer.sh) return 0 ;;
    launchd/*) return 0 ;;
  esac
  return 1
}

changed_files() {
  if [ -n "${VOICELAYER_VERIFY_CHANGED_FILES_FILE:-}" ]; then
    cat "$VOICELAYER_VERIFY_CHANGED_FILES_FILE"
    return
  fi

  local base_ref="${VOICELAYER_VERIFY_BASE_REF:-}"
  if [ -z "$base_ref" ]; then
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
      base_ref="origin/main"
    elif git rev-parse --verify main >/dev/null 2>&1; then
      base_ref="main"
    else
      base_ref="HEAD~1"
    fi
  fi

  local merge_base
  if merge_base="$(git merge-base HEAD "$base_ref" 2>/dev/null)"; then
    git diff --name-only "$merge_base...HEAD"
  else
    git diff --name-only "$base_ref...HEAD"
  fi
}

assert_corpus_tree_clean() {
  local status
  status="$(git status --porcelain --untracked-files=all)"
  if [ -n "$status" ]; then
    printf '[voicelayer-verify] corpus certification refuses a dirty worktree:\n' >&2
    printf '%s\n' "$status" | sed 's/^/[voicelayer-verify]   /' >&2
    return 1
  fi
  if [ "$(git rev-parse HEAD)" != "$sha" ]; then
    printf '[voicelayer-verify] HEAD changed during corpus verification; no artifact written.\n' >&2
    return 1
  fi
}

is_voicebar_launchd_managed() {
  command -v launchctl >/dev/null 2>&1 || return 1
  launchctl list "$VOICEBAR_LAUNCHD_LABEL" >/dev/null 2>&1
}

wait_for_old_voicebar_pids_to_exit() {
  local old_pids="$1"
  for _ in $(seq 1 100); do
    local still_running=""
    for pid in $old_pids; do
      if kill -0 "$pid" 2>/dev/null; then
        still_running=1
        break
      fi
    done
    [ -z "$still_running" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_voicebar_stop() {
  local old_pids="$1"
  if is_voicebar_launchd_managed; then
    printf '[voicelayer-verify] VoiceBar is launchd-managed; waiting for old PID(s) to exit.\n'
    wait_for_old_voicebar_pids_to_exit "$old_pids"
    return $?
  fi

  for _ in $(seq 1 100); do
    if ! pgrep -x VoiceBar >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_launchd_voicebar_relaunch() {
  local old_pids="$1"
  for _ in $(seq 1 100); do
    local new_pids=""
    local pid
    for pid in $(pgrep -x VoiceBar 2>/dev/null || true); do
      local is_old=""
      local old_pid
      for old_pid in $old_pids; do
        if [ "$pid" = "$old_pid" ]; then
          is_old=1
          break
        fi
      done
      if [ -z "$is_old" ]; then
        new_pids="${new_pids}${pid} "
      fi
    done
    if [ -n "$new_pids" ]; then
      printf '%s\n' "$new_pids"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

find_daemon_pids() {
  {
    lsof -nP -U 2>/dev/null | awk -v socket="$MCP_SOCKET_PATH" '$NF == socket { print $2 }'
    pgrep -f 'mcp-server-daemon\\.ts' 2>/dev/null || true
  } | sort -n | uniq | tr '\n' ' '
}

stop_daemon_pids() {
  local daemon_pids="$1"
  if [ -z "$daemon_pids" ]; then
    return 0
  fi

  printf '[voicelayer-verify] stopping old daemon process(es): %s\n' "$daemon_pids"
  # shellcheck disable=SC2086
  kill -TERM $daemon_pids 2>/dev/null || true
  for _ in $(seq 1 100); do
    local still_running=""
    local pid
    for pid in $daemon_pids; do
      if kill -0 "$pid" 2>/dev/null; then
        still_running=1
        break
      fi
    done
    [ -z "$still_running" ] && break
    sleep 0.1
  done
  local still_running_pids=""
  local pid
  for pid in $daemon_pids; do
    if kill -0 "$pid" 2>/dev/null; then
      still_running_pids="${still_running_pids}${pid} "
    fi
  done
  if [ -n "$still_running_pids" ]; then
    printf '[voicelayer-verify] daemon did not stop after SIGTERM; sending SIGKILL to: %s\n' "$still_running_pids"
    # shellcheck disable=SC2086
    kill -KILL $still_running_pids 2>/dev/null || true
  fi
}

needs_verification=0
daemon_files=""
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if daemon_path_matches "$file"; then
    needs_verification=1
    daemon_files="${daemon_files}${file}"$'\n'
  fi
done < <(changed_files)

if [ "$FORCE" -eq 1 ]; then
  needs_verification=1
  if [ -z "$daemon_files" ]; then
    daemon_files="forced-runtime-verification"$'\n'
  fi
fi

if [ "$needs_verification" -eq 0 ]; then
  printf '[voicelayer-verify] no daemon verification required for this branch.\n'
  exit 0
fi

branch="$(git branch --show-current 2>/dev/null || true)"
if [ -z "$branch" ]; then
  branch="detached"
fi
sha="$(git rev-parse HEAD)"
short_sha="$(git rev-parse --short HEAD)"
safe_branch="$(printf '%s' "$branch" | tr '/' '-' | tr '[:space:]' '-' | tr -cd 'A-Za-z0-9._-')"
tester="${VOICELAYER_VERIFY_TESTER:-$(git config user.name 2>/dev/null || true)}"
if [ -z "$tester" ]; then
  tester="${USER:-unknown}"
fi

printf '[voicelayer-verify] daemon/socket/MCP verification required for:\n'
printf '%s' "$daemon_files" | sed 's/^/[voicelayer-verify]   - /'

if [ "$VERIFY_MODE" = "corpus" ]; then
  corpus_root="${VOICELAYER_VERIFY_CORPUS_ROOT:-${HOME:-}/.local/share/voicelayer/recordings}"
  corpus_manifest="${VOICELAYER_VERIFY_CORPUS_MANIFEST:-$REPO_ROOT/scripts/corpus-replay-manifest.txt}"
  corpus_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/voicelayer-corpus-verify.XXXXXX")"
  artifact="$VERIFY_DIR/verified-runtime-${safe_branch}-${short_sha}.txt"
  rm -f "$artifact"
  # shellcheck disable=SC2329 # Invoked indirectly by the trap below.
  cleanup_corpus_verify() {
    rm -rf "$corpus_work_dir"
  }
  trap cleanup_corpus_verify EXIT INT TERM

  export VOICELAYER_SOCKET_PATH="$corpus_work_dir/voicebar.sock"
  export VOICELAYER_MCP_SOCKET_PATH="$corpus_work_dir/mcp.sock"
  export VOICELAYER_VERIFY_WORK_DIR="$corpus_work_dir"
  export QA_VOICE_SOCKET_PATH="$VOICELAYER_SOCKET_PATH"
  export QA_VOICE_MCP_SOCKET_PATH="$VOICELAYER_MCP_SOCKET_PATH"

  assert_corpus_tree_clean

  printf '[voicelayer-verify] corpus mode: %s deterministic specimen(s)\n' "$CORPUS_COUNT"
  printf '[voicelayer-verify] pinned corpus manifest: %s\n' "$corpus_manifest"
  printf '[voicelayer-verify] isolated VoiceBar socket: %s\n' "$VOICELAYER_SOCKET_PATH"
  printf '[voicelayer-verify] isolated MCP socket: %s\n' "$VOICELAYER_MCP_SOCKET_PATH"

  if [ -n "${VOICELAYER_VERIFY_CORPUS_RUNNER:-}" ]; then
    "$VOICELAYER_VERIFY_CORPUS_RUNNER" "$CORPUS_COUNT" "$corpus_root" "$corpus_manifest"
  else
    bun run "$REPO_ROOT/src/corpus-replay-verify.ts" \
      --count "$CORPUS_COUNT" \
      --corpus-root "$corpus_root" \
      --manifest "$corpus_manifest" \
      --work-dir "$corpus_work_dir" \
      --repo-root "$REPO_ROOT"
  fi
  printf '[voicelayer-verify] F5 finish-paste terminal gate: PASS\n'
  printf '[voicelayer-verify] F5 very-long finish-paste terminal gate: PASS\n'

  assert_corpus_tree_clean

  mkdir -p "$VERIFY_DIR"
  tmp_artifact="${artifact}.tmp.$$"
  {
    printf 'Verified-Runtime: %s\n' "$sha"
    printf 'timestamp: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'branch: %s\n' "$branch"
    printf 'sha: %s\n' "$sha"
    printf 'short_sha: %s\n' "$short_sha"
    printf 'tester: %s\n' "$tester"
    printf 'verification_mode: corpus\n'
    printf 'f5_finish_paste_terminal: pass\n'
    printf 'f5_finish_paste_terminal_very_long: pass\n'
    printf 'corpus_count: %s\n' "$CORPUS_COUNT"
    printf 'corpus_manifest: %s\n' "$corpus_manifest"
    printf 'daemon_files:\n'
    printf '%s' "$daemon_files" | sed 's/^/- /'
  } >"$tmp_artifact"
  mv "$tmp_artifact" "$artifact"

  printf '[voicelayer-verify] wrote runtime artifact: %s\n' "$artifact"
  printf 'Verified-Runtime: %s\n' "$sha"
  exit 0
fi

running_pids="$(pgrep -x VoiceBar 2>/dev/null || true)"
if [ -n "$running_pids" ] && [ "${VOICELAYER_VERIFY_SKIP_RELAUNCH:-0}" != "1" ]; then
  printf '[voicelayer-verify] VoiceBar is running with PID(s): %s\n' "$(printf '%s' "$running_pids" | tr '\n' ' ')"
  printf 'Rebuild, stop the running VoiceBar, and relaunch the fresh app? (y/N) '
  if ! IFS= read -r -t 300 relaunch_answer; then
    printf '\n[voicelayer-verify] timed out waiting for relaunch confirmation.\n' >&2
    exit 1
  fi
  case "$relaunch_answer" in
    y|Y|yes|YES) ;;
    *)
      printf '[voicelayer-verify] relaunch confirmation rejected; no artifact written.\n' >&2
      exit 1
      ;;
  esac
fi

if [ "${VOICELAYER_VERIFY_SKIP_BUILD:-0}" = "1" ]; then
  printf '[voicelayer-verify] VOICELAYER_VERIFY_SKIP_BUILD=1; skipping build.\n'
else
  printf '[voicelayer-verify] rebuilding VoiceBar.app...\n'
  (cd "$REPO_ROOT/flow-bar" && ./build-app.sh)
fi

if [ -n "$running_pids" ] && [ "${VOICELAYER_VERIFY_SKIP_RELAUNCH:-0}" != "1" ]; then
  launchd_managed=0
  if is_voicebar_launchd_managed; then
    launchd_managed=1
  fi
  daemon_pids="$(find_daemon_pids)"

  printf '[voicelayer-verify] stopping old VoiceBar process(es)...\n'
  pkill -x VoiceBar 2>/dev/null || true
  if ! wait_for_voicebar_stop "$running_pids"; then
    printf '[voicelayer-verify] VoiceBar did not stop cleanly; no artifact written.\n' >&2
    exit 1
  fi

  stop_daemon_pids "$daemon_pids"

  if [ "$launchd_managed" -eq 1 ]; then
    if ! new_pids="$(wait_for_launchd_voicebar_relaunch "$running_pids")"; then
      printf '[voicelayer-verify] launchd did not relaunch VoiceBar; no artifact written.\n' >&2
      exit 1
    fi
    printf '[voicelayer-verify] launchd relaunched VoiceBar with PID(s): %s\n' "$new_pids"
  else
    printf '[voicelayer-verify] relaunching VoiceBar.app...\n'
    open -a VoiceBar
    sleep 1
  fi
fi

printf "Press F5 in VoiceBar, speak 'verification test', release, confirm paste fired (Y/n) "
if ! IFS= read -r -t 300 answer; then
  printf '\n[voicelayer-verify] timed out waiting for runtime confirmation; no artifact written.\n' >&2
  exit 1
fi

case "$answer" in
  ""|y|Y|yes|YES) ;;
  *)
    printf '[voicelayer-verify] runtime verification rejected; no artifact written.\n' >&2
    exit 1
    ;;
esac

mkdir -p "$VERIFY_DIR"
artifact="$VERIFY_DIR/verified-runtime-${safe_branch}-${short_sha}.txt"
tmp_artifact="${artifact}.tmp.$$"
{
  printf 'Verified-Runtime: %s\n' "$sha"
  printf 'timestamp: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'branch: %s\n' "$branch"
  printf 'sha: %s\n' "$sha"
  printf 'short_sha: %s\n' "$short_sha"
  printf 'tester: %s\n' "$tester"
  printf 'daemon_files:\n'
  printf '%s' "$daemon_files" | sed 's/^/- /'
} >"$tmp_artifact"
mv "$tmp_artifact" "$artifact"

printf '[voicelayer-verify] wrote runtime artifact: %s\n' "$artifact"
printf 'Verified-Runtime: %s\n' "$sha"
