# Speech History index

Speech metadata remains in `recordings/<day>/<id>/metadata.json`. Speech History
uses a disposable sibling directory, `recordings.speech-history-v1/`, to avoid
reading dictation metadata on each visit.

Speech receipt publication and subsequent speech-store writes durably publish
an empty file named for the speech ID. These membership files survive terminal
states. `recordings.speech-open/`, `recordings.speech-pending/`, and
`.speech-index-migration-v1` retain their existing recovery roles.

The Settings loader stores `.days.json` in the history index. It contains only
day modification timestamps and speech IDs. A missing, corrupt, or stale
checkpoint rebuilds affected days in the existing detached utility task. No
record metadata or audio is rewritten. Cancellation leaves the checkpoint
unpublished, and the next load retries. An unavailable index falls back to a
background scan without hiding archived records.

On subsequent loads, unchanged days use cached membership; writer membership
files are merged in so a publication concurrent with migration is retained.
Metadata is read fresh for displayed speech records, preserving status updates.
Deleted records are skipped. Settings shows a loading indicator until its first
load completes. Dictation and Ask history retain their existing scanners.
