# Record while processing: two-take lifecycle

Historical source baseline: `e75a4eb662a534665c36240916ab918a00aabf2c`.
Lane I implements the fixed admission, take cancellation and final dispatch on
integration base `01ca5dec`. Fixed PASS is model evidence; the conformance replay
below exercises the new real handlers. Neither establishes installed/live acceptance.

```sh
bash formal/record-while-processing/check.sh
bash formal/record-while-processing/conformance.sh
```

The shared runner uses `nice -n 19 java -Xmx512m -XX:+UseParallelGC -cp
~/.cache/tla/tla2tools.jar tlc2.TLC`, one worker, seed 1, fingerprint 0,
and temporary state directories under this worktree's `.build.noindex/`.
Logs in `results/` include the installed TLC 2.19 version and full counterexamples.
Expected failures require exit 12 and the exact named invariant, not merely nonzero exit.
No state/depth constraints truncate either positive graph; weak fairness is checked.
`results/run.json` records source, spec, config, runner and TLC-jar SHA-256 hashes,
and refuses a receipt if source/spec/config/runner changes during checking.

## State and intended contract

Two stable identities, A and B, each progress through fresh, recording, captured,
transcribing, ready-for-delivery, cancelling, pasted, cancelled, failed, or superseded.
There is one microphone and one decoder. Captured takes form a bounded pending set;
FIFO scheduling is not asserted. A decoder remains occupied while cancellation
settles, rather than pretending a cancellation immediately makes resources safe.
In the historical model, `ready` belongs to the Swift display-floor task: the daemon has already become
idle and released the decoder. Socket record can enter this window even though
native F5 still sees transcribing mode. These are separate ownership boundaries.

- N6: a qualified new F5 start or trusted socket record request must start B while
  A processes, preserving A. Current distinguishes the two actual ingress routes:
  native F5 cancels A; a direct socket `record` is rejected with `busy`.
- N7: cancelling recording B targets only B and leaves processing A intact.
  Cancelling processing A is a transaction with an identity-bound guard, a two-step
  cooldown/ring, then a commit. The model does not choose the physical confirmation
  gesture or a real duration. Escape bypasses the guard and cancels the foreground
  recording when present, otherwise the active processing take.
  Stale A guards cannot cancel a later B; cancelling B preserves an unrelated A guard.
- N8: a successful, eligible final result dispatches its paste immediately, including
  while B records. `deliveries` counts dispatches, **not** successful AX/keyboard
  insertion observed in another app. The model excludes the current cosmetic
  minimum-display wait in Fixed, and checks it as a separate Current failure.
  `N8FinalNotSuperseded` also catches a new recording event cancelling A's deferred
  final before its timer fires. Its audio remains archived; the dropped item is delivery.
- D3: every completed/cancelled/timed-out/failed take remains retained. Archive writes
  are assumed successful. Capture-to-archive is an atomic boundary here; incremental
  WAV durability, disk errors, recorder crashes and byte-level audio fidelity are not proved.

The historical capture/archive handoff was admission-busy and is collapsed before
another start can enter. The historical Current design has no concurrent A-decoding/B-recording state;
it can overlap A's deferred UI result with socket-started B.
Fixed releases capture ownership after archival and owns worker/delivery/cancel state
per take. The implementation keeps the cross-process session booking while a process owns jobs,
and separately releases its microphone only after archival, recorder exit and VAD
settlement. `recording_jobs` snapshots project these owners; old completion cannot
publish idle over a new capture. Only this managed concurrent path admits B over A.
Legacy unowned processing remains admission-busy, and no new concurrent owner uses
the legacy cancel file.

`ProcessingSettles` requires fair decoder completion, cancellation settlement and
timer/delivery scheduling. It allows a failure, user cancellation, or known Current
supersession instead of a paste; Fixed separately forbids supersession. It does not
assert that a hung backend or permanently failing disk recovers.
Recording can remain open indefinitely while someone speaks; timeout is an optional
capture-end event, never a forced fairness assumption that cuts off speech.

## Action to code map (Lane I implementation)

| Model action/operator | Implemented code |
| --- | --- |
| `Init`, `Mic`, `Worker` | `src/recording-take-queue.ts:24` (`capture`, entries, serialized worker tail); `src/recording-jobs.ts:14` (aggregate snapshots) |
| `Record(t,"F5")` | `VoiceBarCommandRouter.swift:135`, `:163`; `VoiceState.swift:2570` (original target per new take) |
| `Record(t,"socket")` | `src/socket-handlers.ts:462`, `:514`; `src/recording-jobs.ts:30`, `:48` (mic-free admission; missing trusted take ID assigned at ingress) |
| `Capture(t,"stop"/"timeout")`, D3 | `src/input.ts:3132` (full WAV archive before processing), `:3218` (cancelled archive kept), `:3026` and `:3087` (failed/empty take retained); `src/recording-take-queue.ts:65` (draining fence) |
| `Decode` | `src/input.ts:3356`; `src/recording-take-queue.ts:97` (live and History share one worker) |
| `Complete`, immediate dispatch | `src/input.ts:3575`; `src/recording-jobs.ts:111`; `VoiceState.swift:2640`, `:2719` (owned final bypasses foreground capture and cosmetic floor), `:3122` (legacy final synchronous) |
| `Deliver`, historical floor `Tick`/`DropDeferred` | There is no deferred-final task in the new source. `VoiceState.swift:4010` handles legacy final immediately; owned final dispatch is identity-bound. The historical actions remain only in Old* controls |
| `Fail` | `src/input.ts:3610` (archive reason updated, audio kept); queue settlement removes only the failed owner |
| `Cancel`, Escape | `VoiceState.swift:1990` (mic-first scoped target), `VoiceBarCommandRouter.swift:91` and `VoiceBarApp.swift:1566` (Escape bypasses click guard); `src/socket-handlers.ts:362` (take cancel never writes global cancel file) |
| `Arm`, guard `Tick`, `DismissStaleGuard` | `VoiceState.swift:1010`, `:1019`, `:2651`; two 325 ms ticks publish ring progress; snapshots dismiss retired identities |
| Guarded commit | `VoiceState.swift:1030` requires same ID, completed cooldown and still-processing take; a stale A guard cannot target B |
| Scoped signal, `ReapCancelled` | `src/recording-jobs.ts:46`, `:83` (per-take AbortController); `src/input.ts:713`, `:3497` (owned jobs ignore the global legacy file); worker is retained until the cancelled decode settles |
| Producer routing / reconnect | `SocketServer.swift:420`, `:563` (take→producer); `src/socket-client.ts:261`, `src/recording-jobs.ts:132` (command-owner snapshots and pending delivery replay) |

Concrete `capturing`/`draining` refines abstract `recording`; archived `queued`
refines `captured`; active decoder refines `transcribing`. An aborted worker
refines `cancelling`. `Complete` is a paste **dispatch**, never proof of insertion.
The concrete worker queue retains its slot through the matching delivery ACK to
preserve order. That post-dispatch wait stutters at abstract `pasted`; the model
allows a following decode earlier than this stricter implementation does.
Processing liveness assumes decoder settlement and eventual delivery ACK, including
reconnection. It does not assert recovery from a hung backend/AX write or disk fault.
Archival failures and unconfirmed recorder exit retain admission for recovery.

The PTT silence-budget addition has its own speech-bearing model and exact-property
mutants in [ptt-silence-timeout](../ptt-silence-timeout/README.md), separate from
Lane G's lifecycle operator edits.

## Exact findings and mutation controls

| Config | Counterexample / classification |
| --- | --- |
| [OldSocketBusy](results/OldSocketBusy.log) | socket record A -> stop/archive A -> decode A -> socket record B: B stays fresh, A keeps transcribing, `N6StartsB` fails (`busy` in real daemon replay) |
| [OldF5CancelsA](results/OldF5CancelsA.log) | F5 A -> stop/archive A -> decode A -> F5 B: A becomes cancelling, B stays fresh, `N6PreservesA` fails. Historical `handleHotkeyHoldStart` called `handleCancel` |
| [OldUnguardedCancel](results/OldUnguardedCancel.log) | start A -> archive -> decode -> click cancel: A becomes cancelling with no guard/cooldown, `N7GuardedClick` fails |
| [OldDisplayFloor](results/OldDisplayFloor.log) | start A -> archive -> decode (`floor[A]=2`) -> final result: A is ready with zero dispatches, `N8ImmediatePaste` fails. Historical default floor was 0.65 s |
| [OldDeferredFinalDrop](results/OldDeferredFinalDrop.log) | socket start A -> archive/decode -> final A held by Swift while daemon idle -> socket starts B -> recording event cancels A's deferred task: A is superseded with zero dispatches, `N8FinalNotSuperseded` fails |
| [ConcurrentGlobalCancel](results/ConcurrentGlobalCancel.log) | **Mutation of the proposed concurrent design**, not a reachable current bug: allow B while A processes, keep the current unscoped signal, then cancel B but consume it for A; `N7ScopedCancel` fails |
| [DropCancelledMutant](results/DropCancelledMutant.log) | **Synthetic retention mutation**, not a current finding: cancel an unarchived capture without retaining it; `D3EveryTakeKept` fails |

[Current](results/Current.log) checks types, one microphone/decoder, retention,
no duplicate/cancelled paste, ring consistency, and eventual processing settlement.
It deliberately omits failing acceptance rows. [Fixed](results/Fixed.log) adds all
N6/N7/N8 invariants. `results/coverage.json` requires reachable successful A-paste
during B-recording, B-cancel with A-processing, stale guards, timeout retention, and
an actual graph edge taking Escape during an armed cooldown; empty coverage fails.

`conformance.sh` extracts all fixed socket-admission equivalence classes and five
cancellation edge classes from the complete TLC graph. Bun replays admission over
live and History jobs through real `handleSocketCommand`/queue ownership, including
trusted requests without an explicit take ID, scoped B cancel preserving A, stale A
cancel after a later take, and an owned take ignoring an unrelated global signal.
Only recorder/booking/playback/broadcast IO is substituted; no mic/audio is used.
Swift `LaneGFormalConformanceTests` replays the fixed native hold/tap/direct/toggle/
start paths, those five cancellation classes, guard/ring cooldown and stale identity,
Escape's foreground priority, and raw final dispatch while B records. A legacy
positive-display-duration test verifies immediate final retention across B's event.
These are handler/queue/projection proofs, not installed, actual paste or VAD proofs.
See [Conformance.log](results/Conformance.log).

No existing lifecycle invariant or temporal operator changed in Lane I. Lane G owns
the standing-rule mutation expansion for that model. Historical controls still
require the exact named invariant and exit 12; the separate PTT model has a mutant
for each of its four properties and refuses any unexpected pass.

## Lane I, part 1: N8 implementation

Final transcription events now retain words and dispatch paste synchronously through
`VoiceState.handleFinalTranscription`; there is no deferred final task for a new
recording to cancel. The historical display-duration setting cannot delay delivery.
`N8Fixed.cfg` checks immediate delivery with the old admission/cancel policies, so
this part does not imply N6/N7 implementation. Old display-floor and deferred-drop
configs remain expected FAIL controls. Swift tests replay immediate retention and
new recording events, receipt retention, late History results and paste dispatch.
