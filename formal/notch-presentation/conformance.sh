#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -B formal/notch-presentation/conformance.py
export VOICEBAR_NOTCH_TLC_CASES="$PWD/.build.noindex/notch-presentation/conformance.json"
# The captain requires serialized Swift jobs, including this focused real-source replay.
exec "$HOME/.local/state/captain-2.2.61/heavy.sh" G swift test --package-path flow-bar \
  --scratch-path .build.noindex/swift --filter LaneGFormalConformanceTests
