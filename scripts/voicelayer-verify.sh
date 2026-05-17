#!/usr/bin/env bash
# Runtime verification gate for VoiceLayer daemon/socket/MCP changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="${VOICELAYER_VERIFY_REPO_ROOT:-$DEFAULT_REPO_ROOT}"
VERIFY_DIR="$REPO_ROOT/.verified"
MCP_SOCKET_PATH="${QA_VOICE_MCP_SOCKET_PATH:-/tmp/voicelayer-mcp.sock}"
FORCE=0

usage() {
  cat <<'USAGE'
Usage: scripts/voicelayer-verify.sh [--force]

Rebuilds VoiceBar.app and requires a real F5 dictation/paste smoke test when
the current branch touches VoiceLayer daemon/socket/MCP surfaces.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
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
    src/resolve-binary.ts) return 0 ;;
    src/socket-*.ts) return 0 ;;
    src/socket-client.ts) return 0 ;;
    src/socket-handlers.ts) return 0 ;;
    src/socket-protocol.ts) return 0 ;;
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
  printf '[voicelayer-verify] stopping old VoiceBar process(es)...\n'
  pkill -x VoiceBar 2>/dev/null || true
  for _ in $(seq 1 100); do
    if ! pgrep -x VoiceBar >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  if pgrep -x VoiceBar >/dev/null 2>&1; then
    printf '[voicelayer-verify] VoiceBar did not stop cleanly; no artifact written.\n' >&2
    exit 1
  fi
  daemon_pids="$(
    {
      lsof -nP -U 2>/dev/null | awk -v socket="$MCP_SOCKET_PATH" '$NF == socket { print $2 }'
      pgrep -f 'mcp-server-daemon\\.ts' 2>/dev/null || true
    } | sort -n | uniq | tr '\n' ' '
  )"
  if [ -n "$daemon_pids" ]; then
    printf '[voicelayer-verify] stopping old daemon process(es): %s\n' "$daemon_pids"
    # shellcheck disable=SC2086
    kill -TERM $daemon_pids 2>/dev/null || true
    for _ in $(seq 1 100); do
      still_running=""
      for pid in $daemon_pids; do
        if kill -0 "$pid" 2>/dev/null; then
          still_running=1
          break
        fi
      done
      [ -z "$still_running" ] && break
      sleep 0.1
    done
    still_running_pids=""
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
  fi
  printf '[voicelayer-verify] relaunching VoiceBar.app...\n'
  open -a VoiceBar
  sleep 1
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
