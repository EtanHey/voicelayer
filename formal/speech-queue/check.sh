#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONDONTWRITEBYTECODE=1
python3 -B formal/speech-queue/test_graph_retention.py
python3 -B formal/setup-tlc.py
exec python3 -B formal/speech-queue/check.py "$@"
