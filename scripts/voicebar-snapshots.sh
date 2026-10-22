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
  --filter 'SnapshotDiffTests|VoiceBarSnapshotTests' 2>&1 | tee "$root/.build.noindex/snapshots/last-run.log"
if /usr/bin/grep -Eq 'VoiceBarSnapshotTests.*skipped|SKIP:|Test Suite.*skipped' "$root/.build.noindex/snapshots/last-run.log"; then
  echo 'SKIP: snapshot catalog was not compared; this is not a passing snapshot run.' >&2
  exit 77
fi
if [ "$record" = 1 ]; then
  # These states intentionally have identical pixels; behavioral assertions remain.
  for alias in last-item teleprompter-collapsed snoozed; do
    rm -f "$root/flow-bar/Tests/VoiceBarUITests/Snapshots/$alias-dark.png" \
      "$root/flow-bar/Tests/VoiceBarUITests/Snapshots/$alias-light.png"
  done
fi
echo "Gallery: $root/.build.noindex/snapshots/index.html"
