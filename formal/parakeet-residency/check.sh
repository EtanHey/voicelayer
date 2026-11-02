#!/bin/bash
set -euo pipefail
exec nice -n 19 python3 "$(dirname "$0")/check.py" "$@"
