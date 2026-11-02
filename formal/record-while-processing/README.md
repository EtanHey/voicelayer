# Record while processing: two-take lifecycle

Source baseline: `e75a4eb662a534665c36240916ab918a00aabf2c` (captain 2.2.61 integration base).
**Fixed PASS checks the intended design; it does not establish an implemented,
installed, or live N6/N7/N8 fix.** No application code is changed by this lane.

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
`ready` belongs to the Swift display-floor task: the daemon has already become
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

The current capture/archive handoff remains admission-busy and is collapsed before
another start can enter. Current has no concurrent A-decoding/B-recording state;
it can overlap A's deferred UI result with socket-started B.
Fixed releases capture ownership after archival and owns worker/delivery/cancel state
per take. Session booking must likewise separate microphone ownership from processing
before implementation can realize this design. The model is not a source refinement
of that future architecture, and does not claim the current global lock supports it.

`ProcessingSettles` requires fair decoder completion, cancellation settlement and
timer/delivery scheduling. It allows a failure, user cancellation, or known Current
supersession instead of a paste; Fixed separately forbids supersession. It does not
assert that a hung backend or permanently failing disk recovers.
Recording can remain open indefinitely while someone speaks; timeout is an optional
capture-end event, never a forced fairness assumption that cuts off speech.

## Action to code map (baseline line numbers)

| Model action/operator | Current implementation |
| --- | --- |
| `Init`, singleton phase, `Mic`, `Worker` | `src/recording-state.ts:5`, `:15`, `:118`, `:139`; `src/input.ts:3295` |
| `Record(t,"F5")` | `flow-bar/Sources/VoiceBar/VoiceBarCommandRouter.swift:133`, `:161`; `flow-bar/Sources/VoiceBarUI/VoiceState.swift:2458` |
| `Record(t,"socket")` | `src/socket-handlers.ts:442` (`recording` no-op / `transcribing` busy), `:462` (booking), `:494` (trusted `press_to_talk`) |
| Daemon ingress wiring | `src/mcp-server-daemon.ts:45`, `:226`, `:237` (native commands and speech-control commands share the handler) |
| `Capture(t,"stop"/"timeout")`, retention | `src/input.ts:3038`, `:3067` (archive before callbacks/STT), `:3155` (cancelled capture retained) |
| `Decode` | `src/input.ts:3295`, `:3302` (publish transcribing), `:3335` |
| `Complete` | `src/input.ts:3412`, `:3434`, `:3510`; `flow-bar/Sources/VoiceBarUI/VoiceState.swift:2919` |
| `Deliver`, current floor `Tick` | `flow-bar/Sources/VoiceBarUI/VoiceState.swift:1442`, `:3816`, `:3826`, `:3833`, `:3863` |
| `DropDeferred` on B's recording event | `src/input.ts:3530` (daemon idle after final); `flow-bar/Sources/VoiceBarUI/VoiceState.swift:2734`, `:3816` (cancel the ordinary deferred final) |
| `Fail` | `src/input.ts:3549` (failed archive row remains) |
| `Cancel`, Escape | `flow-bar/Sources/VoiceBar/VoiceBarCommandRouter.swift:84`, `:90`; `VoiceState.swift:1890`, `:1918`; `src/socket-handlers.ts:352` |
| Global signal race abstraction | `src/session-booking.ts:242`, `:249`, `:256`; `src/input.ts:709`, `:2364`, `:3156`, `:3434` |
| `ReapCancelled` | `src/input.ts:3434` (consume signal, discard transcript, idle after processing); recording cancellation/archival is collapsed into `Cancel` |
| `Arm`, guard `Tick`, `DismissStaleGuard`, scoped cancellation | Proposed identity-bound transaction; absent from current code. A future commit event must validate the same still-active take |

## Exact findings and mutation controls

| Config | Counterexample / classification |
| --- | --- |
| [OldSocketBusy](results/OldSocketBusy.log) | socket record A -> stop/archive A -> decode A -> socket record B: B stays fresh, A keeps transcribing, `N6StartsB` fails (`busy` in real daemon replay) |
| [OldF5CancelsA](results/OldF5CancelsA.log) | F5 A -> stop/archive A -> decode A -> F5 B: A becomes cancelling, B stays fresh, `N6PreservesA` fails. Current `handleHotkeyHoldStart` calls `handleCancel` |
| [OldUnguardedCancel](results/OldUnguardedCancel.log) | start A -> archive -> decode -> click cancel: A becomes cancelling with no guard/cooldown, `N7GuardedClick` fails |
| [OldDisplayFloor](results/OldDisplayFloor.log) | start A -> archive -> decode (`floor[A]=2`) -> final result: A is ready with zero dispatches, `N8ImmediatePaste` fails. Current default floor is 0.65 s |
| [OldDeferredFinalDrop](results/OldDeferredFinalDrop.log) | socket start A -> archive/decode -> final A held by Swift while daemon idle -> socket starts B -> recording event cancels A's deferred task: A is superseded with zero dispatches, `N8FinalNotSuperseded` fails |
| [ConcurrentGlobalCancel](results/ConcurrentGlobalCancel.log) | **Mutation of the proposed concurrent design**, not a reachable current bug: allow B while A processes, keep the current unscoped signal, then cancel B but consume it for A; `N7ScopedCancel` fails |
| [DropCancelledMutant](results/DropCancelledMutant.log) | **Synthetic retention mutation**, not a current finding: cancel an unarchived capture without retaining it; `D3EveryTakeKept` fails |

[Current](results/Current.log) checks types, one microphone/decoder, retention,
no duplicate/cancelled paste, ring consistency, and eventual processing settlement.
It deliberately omits failing acceptance rows. [Fixed](results/Fixed.log) adds all
N6/N7/N8 invariants. `results/coverage.json` requires reachable successful A-paste
during B-recording, B-cancel with A-processing, stale guards, timeout retention, and
an actual graph edge taking Escape during an armed cooldown; empty coverage fails.

`conformance.sh` replays both exhaustive Current socket-admission equivalence classes
through the real `handleSocketCommand` under the normal isolation preload. Only
`waitForInput`/booking/playback/broadcast edges are substituted, so it never records
or emits audio. It also verifies the real cancel signal is consumed once, without
a take ID. The native F5/direct-record/click/Escape counterexamples are exercised by
`LaneGFormalConformanceTests` via `formal/notch-presentation/conformance.sh`.
The Swift replay also runs a positive timer control and reproduces the deferred-final
loss on a new recording event. This is admission/projection/event-handler conformance, not an audio, paste, filesystem-durability,
or full-pipeline refinement proof. See the [conformance receipt](results/Conformance.log).
No fixed-runtime replay is claimed before implementation.
