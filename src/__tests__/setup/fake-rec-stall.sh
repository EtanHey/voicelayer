#!/bin/sh
# Fixed stalling wrapper for fake-rec.sh. Bun 1.3.9 snapshots the parent
# environment for Bun.spawn(), so environment changes made inside a running
# test are not inherited by a child unless the behavior is selected by the
# executable itself.
set -eu

VOICELAYER_TEST_FAKE_REC_STALL_AFTER_CHUNKS=16
export VOICELAYER_TEST_FAKE_REC_STALL_AFTER_CHUNKS
exec "$(dirname "$0")/fake-rec.sh" "$@"
