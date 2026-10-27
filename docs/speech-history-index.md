# Speech History index

Speech metadata remains in `recordings/<day>/<id>/metadata.json`. Speech History
uses a disposable sibling directory, `recordings.speech-history-v1/`, to avoid
reading dictation metadata on each visit.

After core receipt/store bookkeeping, writers best-effort publish an empty file
named for the speech ID. Marker failures log a fixed diagnostic without filesystem
error text and never fail a saved receipt or block voice_ask. Settings rebuilds
missing membership; days with missing, unreadable, or malformed metadata remain
eligible for rescan after repair, even if their directory timestamps do not change.
These membership files survive terminal states. `recordings.speech-open/`, `recordings.speech-pending/`, and
`.speech-index-migration-v1` retain their existing recovery roles.

The Settings loader stores `.days.json` in the history index. It contains only
day modification timestamps, speech IDs, and per-entry metadata modification
timestamps and sizes. A missing, corrupt, old-format, or stale
checkpoint rebuilds affected days in the existing detached utility task. No
record metadata or audio is rewritten. Cancellation leaves the checkpoint
unpublished, and the next load retries. An unavailable index falls back to a
background scan without hiding archived records.

On subsequent loads, days with unchanged directory and metadata timestamps/sizes
use cached membership; writer membership
files are merged in so a publication concurrent with migration is retained.
Metadata is read fresh for displayed speech records, preserving status updates.
Deleted records are skipped. Settings shows “Loading…” in the header during its
first load, with the body spinner delayed by 200 ms. Loading cleanup is fenced
per task invocation, so a cancelled scan cannot clear a replacement load's state
when History is re-entered. Dictation and Ask history
retain their existing scanners.
