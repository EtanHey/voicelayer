#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -B formal/check-model.py formal/notch-presentation "$@"
python3 -B formal/notch-presentation/conformance.py "$@"
