#!/bin/sh
# Fake `rec` — a drop-in stand-in for sox that NEVER opens the microphone.
#
# AIDEV-NOTE: R-014. Selected by VOICELAYER_TEST_FAKE_REC=1 (see
# src/recorder-binary.ts). Two shapes are honoured, matching the only two ways
# VoiceLayer spawns rec:
#   rec -n trim 0 0            → the device probe: print a sox preamble, exit.
#   rec -V2 -r R -c C … -q -   → the capture: stream 16-bit silence to stdout
#                                at roughly real time until stdout closes.
#
# VOICELAYER_TEST_FAKE_REC_STALL_AFTER_CHUNKS=N makes the capture emit exactly
# N chunks and then keep stdout open without producing more bytes. This is the
# real-child-pipe fixture for recorder-stall durability tests; it still never
# opens a microphone.
set -u

RATE=16000
CHANNELS=1
PROBE=0

prev=""
for arg in "$@"; do
  case "$prev" in
    -r) RATE=$arg ;;
    -c) CHANNELS=$arg ;;
  esac
  case "$arg" in
    trim) PROBE=1 ;;
  esac
  prev=$arg
done

if [ "$PROBE" -eq 1 ]; then
  # Same field names parseNativeInputFormat() reads, on stderr like sox.
  printf 'Input File     : '\''default'\''\nChannels       : %s\nSample Rate    : %s\n' \
    "$CHANNELS" "$RATE" >&2
  exit 0
fi

# 50 ms of silence per iteration: rate * channels * 2 bytes/sample * 0.05 s.
CHUNK=$(( RATE * CHANNELS / 10 ))
[ "$CHUNK" -gt 0 ] || CHUNK=1600
STALL_AFTER_CHUNKS=${VOICELAYER_TEST_FAKE_REC_STALL_AFTER_CHUNKS:-0}
CHUNKS_WRITTEN=0

while :; do
  dd if=/dev/zero bs="$CHUNK" count=1 2>/dev/null || exit 0
  CHUNKS_WRITTEN=$(( CHUNKS_WRITTEN + 1 ))
  if [ "$STALL_AFTER_CHUNKS" -gt 0 ] && [ "$CHUNKS_WRITTEN" -ge "$STALL_AFTER_CHUNKS" ]; then
    # `exec` keeps this process (and its stdout pipe) alive without leaving an
    # orphan child when VoiceLayer terminates the recorder.
    exec sleep 86400
  fi
  sleep 0.05 || exit 0
done
