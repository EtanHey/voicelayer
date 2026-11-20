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

## Target app relaunches with its accessibility tree off (T23)

On 18 Nov (M4, VoiceBar 2.4.3) T3 Code relaunched from its update button and every
automatic paste into the new process ended "Nothing to paste into; kept in History":
the ready-time capture got `focused_element_unavailable` for every take, while Shift+F5
typing into the same app worked. This model owns that capture (`Ready`), so it gains the
target app: `chromium`, `axOn` (its tree is on), `accepts` (the tree comes up within the
bound after AXManualAccessibility), `gen`/`enabledGen` (process lifetime, and the one an
earlier set was made for). New actors and steps:

- `Relaunch`: the app quits and relaunches before or during the take: new process, Chromium tree off.
- `Kick`: the F5 key-down recovery, asynchronous, at most once per take, for whatever is focused.
- `Ready` recovers once more when the focus is unreadable, then captures again. Still unreadable
  means no target, and `Deliver` turns that into the visible refusal with the words kept.

New properties: `RelaunchedTargetRecovered` (a relaunched Chromium app that honours the flag still
gets the transcript), `DeliveredOrVisiblyDeclined` (never a silent drop) and `NativeNeverTouched`
(AXManualAccessibility only on Chromium-family apps). `DeliversToReadyTimeFocus` now applies to a
ready focus that was readable after recovery; an unreadable one is the new properties' case.

| Config | Mutation | Required property |
|---|---|---|
| NoRecovery | main before T23: no recovery at all | RelaunchedTargetRecovered |
| KickOnlyMutant | key-down kick only, no ready-time recovery (relaunch mid-take) | RelaunchedTargetRecovered |
| CacheMutant | skip when this bundle was asked before (relaunch between takes) | RelaunchedTargetRecovered |
| SilentMutant | a refusal shows nothing | DeliveredOrVisiblyDeclined |
| AnyAppMutant | set the flag on non-Chromium apps too | NativeNeverTouched |

Conformance: `DictationFocusRecoveryTests.testReadyTimePasteModelFixedConformance` reads Fixed.cfg's
knobs and runs all 48 combinations of the app variables through the real VoiceState capture and paste
path with the production `DictationFocusRecovery`, against the model's Fixed outcome. The Swift
sources and tests are hashed into this receipt (`checks.json` sources).

Not modelled: why the tree is off (the 18 Nov root cause on the M4 is unproven; see the lane report),
how long Chromium takes to build it (`accepts` abstracts "within 20 × 0.1 s"), and macOS AX itself.

Run `PATH=/opt/homebrew/opt/openjdk/bin:$PATH bash formal/ready-time-paste/check.sh`
from the repo root. It uses pinned `formal/tlc.sh`, requires exact exit codes and
invariant names, and retains raw logs under `.build.noindex/ready-time-paste.*`.

| Configuration | Expected exit | Required result | Observed generated/distinct |
|---|---:|---|---:|
| Fixed | 0 | all six invariants pass | pre-T23: 935 / 305; T23 counts in results/run.json once recorded |
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
