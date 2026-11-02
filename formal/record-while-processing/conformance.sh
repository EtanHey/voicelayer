#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -B formal/record-while-processing/conformance.py
export VOICELAYER_RECORD_TLC_CASES="$PWD/.build.noindex/record-while-processing/conformance.json"
nice -n 19 bun test formal/record-while-processing/conformance.test.ts
export VOICEBAR_RECORD_TLC_CASES="$VOICELAYER_RECORD_TLC_CASES"
exec "$HOME/.local/state/captain-2.2.61/heavy.sh" I swift test --package-path flow-bar \
  --scratch-path .build.noindex/swift --filter 'LaneGFormalConformanceTests/testTLC(Fixed|Scoped|Stale|Immediate|Final)'
