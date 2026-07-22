#!/usr/bin/env bash
# Validate detached, exact-head runtime evidence for daemon-sensitive changes.

set -euo pipefail

usage() {
  printf 'Usage: %s <base-sha> <head-sha> <allowed-signers-file>\n' "$0" >&2
}

if [ "$#" -ne 3 ]; then
  usage
  exit 2
fi

base_sha="$1"
head_sha="$2"
allowed_signers_file="$3"

case "$base_sha" in
  *[!0-9a-f]*|'')
    printf '[daemon-proof] invalid base sha: %s\n' "$base_sha" >&2
    exit 2
    ;;
esac
case "$head_sha" in
  *[!0-9a-f]*|'')
    printf '[daemon-proof] invalid head sha: %s\n' "$head_sha" >&2
    exit 2
    ;;
esac
if [ "${#base_sha}" -ne 40 ] || [ "${#head_sha}" -ne 40 ]; then
  printf '[daemon-proof] base and head must be full 40-character commit shas.\n' >&2
  exit 2
fi

if ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
  printf '[daemon-proof] base commit is unavailable: %s\n' "$base_sha" >&2
  exit 2
fi
if ! git cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
  printf '[daemon-proof] head commit is unavailable: %s\n' "$head_sha" >&2
  exit 2
fi
if [ ! -s "$allowed_signers_file" ]; then
  printf '[daemon-proof] allowed signers file is missing or empty: %s\n' "$allowed_signers_file" >&2
  exit 2
fi

daemon_path_matches() {
  case "$1" in
    flow-bar/*) return 0 ;;
    launchd/*) return 0 ;;
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
  esac
  return 1
}

changed_files="$(mktemp "${TMPDIR:-/tmp}/voicelayer-daemon-proof.changed.XXXXXX")"
daemon_files="$(mktemp "${TMPDIR:-/tmp}/voicelayer-daemon-proof.daemon.XXXXXX")"
cleanup() {
  rm -f "$changed_files" "$daemon_files"
}
trap cleanup EXIT INT TERM

git diff --name-only "$base_sha" "$head_sha" >"$changed_files"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if daemon_path_matches "$file"; then
    printf '%s\n' "$file" >>"$daemon_files"
  fi
done <"$changed_files"

if [ ! -s "$daemon_files" ]; then
  printf '[daemon-proof] no daemon/socket/MCP files changed; runtime gate not required.\n'
  exit 0
fi

printf '[daemon-proof] daemon/socket/MCP files changed:\n'
sed 's/^/[daemon-proof]   - /' "$daemon_files"

tag_name="runtime-verified/$head_sha"
tag_ref="refs/tags/$tag_name"
if ! git show-ref --verify --quiet "$tag_ref"; then
  printf '[daemon-proof] missing signed runtime verification tag for %s (%s).\n' \
    "$head_sha" "$tag_name" >&2
  exit 1
fi

tag_target="$(git rev-list -n 1 "$tag_ref")"
if [ "$tag_target" != "$head_sha" ]; then
  printf '[daemon-proof] runtime verification tag does not target head sha: expected %s, got %s.\n' \
    "$head_sha" "$tag_target" >&2
  exit 1
fi

marker="Verified-Runtime: $head_sha"
tag_contents="$(git for-each-ref --format='%(contents)' "$tag_ref")"
if ! grep -Fqx "$marker" <<<"$tag_contents"; then
  printf '[daemon-proof] runtime verification tag is missing the exact head marker: %s.\n' \
    "$marker" >&2
  exit 1
fi

verify_output="$(mktemp "${TMPDIR:-/tmp}/voicelayer-daemon-proof.verify.XXXXXX")"
trap 'rm -f "$changed_files" "$daemon_files" "$verify_output"' EXIT INT TERM
if ! git \
  -c gpg.format=ssh \
  -c "gpg.ssh.allowedSignersFile=$allowed_signers_file" \
  verify-tag "$tag_ref" >"$verify_output" 2>&1; then
  printf '[daemon-proof] runtime verification tag signature verification failed.\n' >&2
  sed 's/^/[daemon-proof]   /' "$verify_output" >&2
  exit 1
fi

printf '[daemon-proof] signed runtime verification accepted for %s.\n' "$head_sha"
