# R2-01 implementation and proof boundary

Status: logic implemented. Source changes are made on M4; final model/runtime and
multi-file verification runs on M1 through the captain lock under the 11:30Z ruling.
No view changes, installation, runtime swap, audio emission, microphone acceptance,
push, or release claim.

## Ownership

The daemon owns the pause. `pauseForF5Capture` parks the current read, holds promotion,
and provides a physical player-exit barrier before microphone admission. Its settlement
is bound to the read identity and is idempotent. A manual `pause` converts `f5` to `user`;
settlement never resumes a user pause or a stopped/replaced read. If automatic resume
is refused (including a foreign persisted busy state), the owned read stops cleanly:
its park is released, its text/History retained, and VoiceBar shows the existing compact
"Speech stopped" note. No retry or inaccessible F5-owned park remains. A runtime
mutant that removes this terminal fallback must fail the refused-resume guard.

`f5-capture.ts` is the only adapter to Lane I. Lane I owns the take IDs, microphone,
FIFO processing, archival, cancellation and native delivery acknowledgement. The
adapter holds one read across its set of outstanding takes, including their paste
acknowledgements, and releases it once the final take settles. It does not implement
another recorder or transcription queue. A physical release before the old player
exits is buffered until the admitted take opens its microphone.

Preparing reads use the same owner before a first audio chunk exists. The first chunk
is admitted parked; Stop prevents it starting, and manual pause keeps it parked.

The router tracks the physical key separately from capture completion and binds the
release to the take it started. Key-up cannot stop resumed speech or a newer take.
Double-tap remains locked. F5 while transcribing uses Lane I's existing N6 admission.
VoiceState restores a manual pause as paused; only the daemon resumes audio. Late
recording-idle events cannot undo a later speech or user-pause state.

The pause cursor uses the containing display word from clone alignment or Edge timing,
with an estimate when neither is available. It retains the word index and chunk-local
and global offsets. Resume cuts from that offset; it never trims a transcript tail.
The record command carries VoiceBar's press-time playback clock, so IPC delay does
not choose a later word.

## Existing manual control and deferred UI

`VoiceState.pauseSpeechDuringCapture()` emits the existing scoped socket `pause` command.
The existing daemon socket `pause` command is a real reachable manual control during
capture and converts the owner. No existing view/keyboard/menu binding for this new
VoiceState method was added; tests and the native-command replay call the method.
`stopSpeechDuringCapture()` also has no UI caller yet (2.3 list). Escape during the
pause cancels the take, not the read.

During any F5 dictation, even with no speech, Option+F5 / `speak_text` queues behind
the capture rather than rejecting busy. An unscoped `stop` with no `take_id` keeps
its legacy speech-stop effect unless an F5-owned capture is active; then it targets
that take through Lane I (including an opening take), leaving narration parked.
A daemon or VoiceBar restart mid-pause drops the read; it is neither stuck paused
nor wrongly resumed. Reads/loans are not restored across process lifetimes.

The previously described UI location is `BarView.swift:506-530`, recording leading
controls, visible only while an F5-owned read is parked during capture. Per the
08:22Z captain ruling, **no new recording-wing button ships in 2.2.61**. It belongs
on the 2.3 notch list, coordinated with Lane A/N1 by a Claude UI worker.

## Verification boundary

`check.sh` retains the queue/History/admission replays and additionally projects TLC
capture-end edges from both Fixed graphs onto R2-01 runtime scenarios. Every distinct
projected combination of initial read, the independent press-position ghost, ownership,
Stop, queued count, outcome and active-take completion order is run with tap, hold and
double gestures. Active take identities are normalized to one or two outstanding takes;
the replay does not claim to reproduce TLC scheduling or every intermediate prefix.
Two-take rows open B while A is processing, test partial settlement without resuming,
then finish the remaining take. The daemon fixture preserves Lane I FIFO when
B’s input result arrives first; the native projection feeds both partial job-removal
snapshots. A separate real-adapter guard makes B fail before archival while A is
processing, verifies B actually leaves the take set without resuming, then verifies
one resume after A ends. User ownership is exercised both before F5 and through conversion
during capture. Every Current counterexample contributes its
actual input prefix. Native Swift emits commands through the real router/VoiceState;
the paired Bun replay parses those commands and drives the real daemon handlers,
PlaybackQueueManager, long-read synthesis lifecycle and Lane I take settlement.
Native symbolic playback IDs are rebound to each fresh daemon player identity.
Synthesis/player/decoder/recorder I/O uses owned fakes; the microphone is never opened
and no audio plays. The end-of-read sentinel completes without spawning another player.

This is a bounded scenario projection, not an exhaustive transition/refinement proof.
R2-03 queue presentation and R2-05 initial timing remain separate implementation work:
their Current prepare/start prefixes are included here without claiming those runtime
invariants pass. Two-take N6/paste acknowledgement, late settlement, physical release
after settlement, clone timing, nonzero chunks, quiescence and preparing-with-no-chunk
also have focused real-logic guards. The native projection waits for the already-queued
main-thread restore using a FIFO continuation barrier on MainActor, not a timed
RunLoop pump; the product's asynchronous restore is unchanged. Refused resume and
restart/drop are runtime boundary guards beyond the model's successful-resume assumption.

The implementation includes F-model round 2 `2b41acda` and its G1 supervised-budget
follow-up `af8f1457` (repository-pinned TLC v1.8.0), plus approved Lane I FIXED-2 `4dd30fd1`. The original `9884ffa7`
model cannot establish the revised M1-M4/D-S4 contract. Gate outcomes and immutable
source hashes belong to the lane receipt and generated check artifacts. Installed
interaction/audio/permission proof belongs to the captain.

Every final paired gate runs the complete pause/runtime files and all changed
socket/handler caller files (idempotency, socket residency, whisper residency,
update-gate round1, error recovery, CLICK2 groundwork and recording review regressions),
plus the approved integration repairs for the private-safety VM and MCP Ask schema.
The full paused-Ask suite supplies explicit prompt word timings at its nonzero
4200ms pause position, preserving every physical-exit, trim-failure and watchdog assertion.
The lead-authorized shared fix 8093e582 (#673) is consumed unchanged; cross-vendor
review is pending. Its two installer test files also run in full and are hashed,
preserving every process-read and reads-under-lock assertion.
CLICK2 asserts exact
containing-word offsets from explicit timing fixtures and one paused confirmation
per preparation/admitted-chunk phase; repeated commands add no confirmation.
Capture-start assertions await their event;
teardown waits for both Lane I jobs and the deferred F5 loan using the original
2-second bound. The full Bun suite is a separate final check; known SSH-generated
speech-fixture failures are reported for GUI verification, never silently passed.
