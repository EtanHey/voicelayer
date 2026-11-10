#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/voicebar-launchagent.sh"
if [[ "${1:-}" == --verify-only ]]; then
  shift
  voicebar_verify_launchd "${1:-/Applications/VoiceBar.app}" || {
    echo 'ERROR: resident VoiceBar is not owned by launchd' >&2; exit 1;
  }
else
  voicebar_start_launchd "${1:-/Applications/VoiceBar.app}"
fi
