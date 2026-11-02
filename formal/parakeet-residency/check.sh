#!/bin/bash
set -euo pipefail
nice -n 19 python3 -m unittest discover -s "$(dirname "$0")" -p test_tlc_result.py
exec nice -n 19 python3 "$(dirname "$0")/check.py" "$@"
