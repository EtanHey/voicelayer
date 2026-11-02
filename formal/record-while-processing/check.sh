#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -B formal/check-model.py formal/record-while-processing
exec bash formal/record-while-processing-runtime/check.sh
