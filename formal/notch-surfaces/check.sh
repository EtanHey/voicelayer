#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 -B formal/check-model.py formal/notch-surfaces
