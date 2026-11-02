#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -B formal/record-while-processing/conformance.py
export VOICELAYER_RECORD_TLC_CASES="$PWD/.build.noindex/record-while-processing/conformance.json"
exec nice -n 19 bun test formal/record-while-processing/conformance.test.ts
