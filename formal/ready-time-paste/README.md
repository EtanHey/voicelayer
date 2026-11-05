# Ready-time paste

Status: bounded protocol proof, not native macOS acceptance.

Each model run describes one locally admitted take. An unknown final recovered
by a fresh app instance stays in History rather than risking a second write;
Swift guards cover that recovery boundary separately.

`Record` captures the old-policy start focus. `Move` may cycle arbitrarily often
before `Ready`. `Ready` captures the new-policy input; `Deliver` dispatches one
attempt (or retains text when none/secure), then `Complete` records completion.
Focus may move again after dispatch, including before completion; it cannot
retarget the captured destination. The selection-to-dispatch phase has no timer
or activation hop, matching the main-actor production path. Secure state is part
of the target identity; synchronous pre-write checks are abstracted by `Ready`.
A potentially applied/uncertain write consumes the attempt just as a success does.

Run `PATH=/opt/homebrew/opt/openjdk/bin:$PATH bash formal/ready-time-paste/check.sh`
from the repo root. It uses pinned `formal/tlc.sh`, requires exact exit codes and
invariant names, and retains raw logs under `.build.noindex/ready-time-paste.*`.

| Configuration | Expected exit | Required result | Observed generated/distinct |
|---|---:|---|---:|
| Fixed | 0 | all three invariants pass | 935 / 305 |
| Old | 12 | DeliversToReadyTimeFocus fails | 166 / 61 |
| DoubleMutant | 12 | DeliveredAtMostOnce fails | 175 / 69 |
| SecureMutant | 12 | NeverIntoSecureField fails | 140 / 55 |

TLC2 2026.10.30.154139 (rev 090e85c), one worker, seed 1, fingerprint 0. The old counterexample records in
one input, moves to another valid input, then refuses the ready-time destination.
These are invariants over terminal delivery states, not liveness guarantees:
we check completion when the daemon supplies a final, not eventual transcription.

The model represents dispatch to a selected target, not OS delivery/readback.
Native AX and VoiceBar's local field editor retain the captured object. Automatic
rich-host/terminal typing posts the complete batch to the captured PID, never to
a newly frontmost process. macOS/host routing within that process and the
check-to-post window remain native acceptance concerns; this model does not
certify those APIs, host focus, Accessibility permission, or visible text.
