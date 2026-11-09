#!/bin/sh
# Slow-opening wrapper for fake-rec.sh: the capture shape delivers its first PCM
# only after 400 ms, like a microphone that is slow to open (for example a
# Bluetooth profile switch right after the previous take). The device probe stays
# immediate. It never opens a microphone.
set -eu

for arg in "$@"; do
  if [ "$arg" = "trim" ]; then exec "$(dirname "$0")/fake-rec.sh" "$@"; fi
done
sleep 0.4 || exit 0
exec "$(dirname "$0")/fake-rec.sh" "$@"
