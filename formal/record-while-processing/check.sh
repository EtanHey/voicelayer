#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -B formal/check-model.py formal/record-while-processing "$@"
python3 -B formal/record-while-processing/conformance.py "$@"
bash formal/record-while-processing-runtime/check.sh "$@"
bash formal/ptt-silence-timeout/check.sh "$@"
python3 -B formal/record-while-processing-runtime/conformance.py
python3 -B formal/record-while-processing/union_report.py "$@"
