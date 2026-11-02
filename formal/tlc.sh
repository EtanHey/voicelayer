#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
jar=$(python3 -B "$root/formal/setup-tlc.py")
exec nice -n 19 java -Xmx512m -XX:+UseParallelGC -cp "$jar" tlc2.TLC -noGenerateSpecTE "$@"
