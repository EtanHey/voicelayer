#!/usr/bin/env bash
# Local MBP synthetic rendering only; never launches the installed app.
set -euo pipefail
record=0
case "${1:-}" in
  --record) record=1 ;;
  '') ;;
  *) echo 'Usage: scripts/voicebar-snapshots.sh [--record]' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo 'Too many arguments' >&2; exit 2; fi
if [ "${GITHUB_ACTIONS:-}" = true ]; then echo 'Snapshots: skipped on hosted CI'; exit 0; fi
if [ "$(uname -s)" != Darwin ] || ! system_profiler SPHardwareDataType | /usr/bin/grep -q 'Chip: Apple M4 Max'; then
  echo 'Snapshots require the MBP; the M1 runner renders blank.' >&2; exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/.build.noindex/snapshots"
export VOICEBAR_SNAPSHOTS=1
export VOICEBAR_SNAPSHOTS_RECORD="$record"
swift test --package-path "$root/flow-bar" --scratch-path "$root/.build.noindex/visual1-swift" \
  --filter 'SnapshotDiffTests|VoiceBarSnapshotTests'
echo "Gallery: $root/.build.noindex/snapshots/index.html"
