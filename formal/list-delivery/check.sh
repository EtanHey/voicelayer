#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 -B "$root/formal/check-model.py" "$root/formal/list-delivery"
