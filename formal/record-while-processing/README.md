# Recording during processing — availability, identity and delivery

`Current.cfg` models the source policy starting at
`e75a4eb662a534665c36240916ab918a00aabf2c`. `Fixed.cfg` preserves the merged ownership
policy and specifies the 11:00Z D3 silence-only design.
A model PASS does not establish installed or live acceptance.

```sh
bash formal/record-while-processing/check.sh
bash formal/record-while-processing/conformance.sh
```

Default checks run every exact-property mutant and the event-anchored witness
queries, then generate both corpora. Logs and graphs stay in `.build.noindex/`;
`check.sh --record` explicitly refreshes normalized committed evidence and the
checksum-bound corpus. The versioned TLC jar is verified against `formal/tlc.lock.json`.
No positive graph is truncated by a state/depth constraint.

## State and contracts

Two identities A/B each own their capture, decoder/delivery phase, speech flag,
retained audio, cancellation request and dispatch count. There is one microphone
and one decoder. Cancellation keeps decoder ownership until completion or reap.
A Swift display-floor result (`ready`) is distinct from a decoder: the daemon is
already idle, so a socket-started B can supersede A's deferred UI result in Current.

N6/N7/N8 are **state/action contracts**, not violation-history flags. `ENABLED`
requires that the operation exists, and a second enabled-action query excludes
bad postconditions. Consequently disabling Record, holding Complete, or disabling
Cancel(B) cannot dodge the acceptance checks. The runner also requires these
negated reachability queries to fail on Fixed:

- `WitnessOverlapPaste`: an actual `result(A)` event must occur while B records.
- `WitnessScopedCancel`: an actual click/Escape for B must occur while A decodes.

These are event-anchored TLC gates, not unordered state counts in a later Python check.
Every positive invariant and temporal property has a targeted failing mutant;
[the table](results/MUTANTS.md) records the exact property/config relation.

- N6 requires a qualified new F5/socket start to record B while A processes and
  preserve A. Current's native F5 cancels A; its direct socket route replies busy.
- N7 requires identity-scoped cancel commands. Current uses the actual global,
  identity-free primitive; its possible recipient is nondeterministic among live
  backend consumers. Fixed validates a take ID, rejects stale IDs, and preserves
  unrelated takes. Processing cancellation arms a cooldown guard/ring; recording
  cancellation is immediate. Escape targets the foreground recording when present.
- N8 requires captured takes to enter an available decoder without waiting for
  the microphone, then Complete to dispatch immediately, including overlap.
  A separate invariant rejects superseded finals. `deliveries` is a dispatch count,
  not proof that a host inserted characters.
- `cancelRequested` survives phase changes. Complete can race cancellation while
  the phase is `cancelling`; it must consume that request rather than paste. The
  paste-after-cancel mutant deliberately ignores the token and fails `NoCancelledPaste`.
- D3 retains stopped, cancelled, timed-out and failed captures. Archive writes are
  assumed successful; byte durability and disk failures are not proved here.
- `talking[t]` changes through speech/silence events. Fixed silence timeout is enabled only
  after ten minutes of continuous silence; speech renews that deadline and there is no recording-length cap. `OldSpeechTimeout` exposes the Current PTT wall-clock timeout; the
  fixed policy's timeout-while-speaking mutant must fail `NoTimeoutWhileTalking`.

`ProcessingSettles` assumes fair decode, result, cancellation-reap and timer work.
`OverlapPastes` starts from captured **or** transcribing A and additionally
requires decode/result availability during B's recording, plus dispatch or an explicit
failure/user cancellation; supersession is not success. `EventuallyIdle` is a
**conditional drain** property after both takes have finished capture. Its idle set excludes captured work
as well as recording/decoding/delivery work. It does not
force a live speaker to stop or make recording terminate by fairness. Each of
these temporal properties has a mutant that fails on that exact named property.

## Default source conformance and integration seam

Both policy graphs export real socket/click/Escape contexts, outcomes and cancel
signal tokens. The harness does not recompute expected replies from a phase rule.
It calls the production `handleSocketCommand`, checks its reply and signal identity,
and rejects an unscoped stop signal for a scoped cancellation. Recording/playback
edges are silent fixtures under the normal isolation preload. `corpus.json` and its
hash allow the same tests to run by default without a prior TLC invocation.

`runtime-adapter.ts` is Lane I's fixture seam: seed its owned take registry from
`row.before` and `captureIds`, and point the signal observer at its new cancellation
primitive. Decision logic stays in the real handler; do not stub admission/cancel.
`runtime-contract.json` holds the wire ID field and Current/Fixed implementation
policy. Baseline Fixed gaps have exact sorted divergence SHA-256/count pins in
`results/conformance.json`, asserted by ordinary mandatory Bun tests. Each tag
includes the entire model context and expected/observed outcome, so model changes
on already-divergent contexts also fail. Swift pins each Fixed family outside
its strict `XCTExpectFailure` wrapper. Switching the
policy to `fixed` makes them ordinary mandatory passes; Current then remains an
executed historical comparison with a required mismatch. Neither corpus is skipped.

The Swift harness uses graph-derived F5, click, Escape and ordered delivery paths
from both policies. It includes Current's deferred-final drop and Fixed's A-result
then B-start control. These are native event-handler / command-boundary checks,
not audio or complete backend refinement proofs. Lane I may adapt those event-ID
bindings in the same Swift harness when its ownership API lands.

## Source map

| Model action | Baseline code |
| --- | --- |
| Record F5 | `flow-bar/Sources/VoiceBar/VoiceBarCommandRouter.swift:133`, `:161`; `VoiceState.swift:2458` |
| Record socket / booking / trusted PTT | `src/socket-handlers.ts:442`, `:462`, `:494` |
| Daemon ingress | `src/mcp-server-daemon.ts:45`, `:226`, `:237` |
| Capture / archive / cancelled capture | `src/input.ts:3038`, `:3067`, `:3155` |
| Speech and Current PTT timer | `src/input.ts:2547`, `:2574` |
| Decode / completed result | `src/input.ts:3295`, `:3412`, `:3510` |
| UI display floor and deliver | `flow-bar/Sources/VoiceBarUI/VoiceState.swift:1442`, `:3816`, `:3863` |
| Deferred result superseded by recording | `src/input.ts:3530`; `VoiceState.swift:2734` |
| Cancel / global signal / consumer | `src/socket-handlers.ts:352`; `src/session-booking.ts:249`; `src/input.ts:709`, `:3434` |
| Guard / scoped ID / silence-only timeout | Fixed design; implementing lane owns application changes |

Current failures, all exact-property checks: native F5 cancels A, socket start is
busy, processing click lacks a guard, result delivery waits for a cosmetic floor,
new recording drops a deferred final, and PTT timeout is allowed during speech.
See normalized traces, [run.json](results/run.json), and [MUTANTS.md](results/MUTANTS.md).

## D3 ruling — 2026-11-02 11:00Z

Current evidence: [D3 receipt](results/D3-11-00Z.json),
[full union mutant table](results/UNION-MUTANTS.md), and
[recording replay log](results/Conformance.log). Earlier FIX-ROUND/Verification
receipts retain historical evidence; their cap policy is superseded here.

Automatic stopping requires **10 minutes of continuous silence**, at the beginning
or in the middle of a take. Every speech event renews that deadline. Recurring or
continuous speech can keep recording indefinitely; elapsed recording time never
forces a stop. Explicit Stop/Cancel and terminal capture errors remain separate.

`ProductClock.cfg` uses one-minute clock steps and `SilenceLimit = 10`. The full
two-take graph uses a two-step silence abstraction. `ObservationLimit` only bounds
a saturated monitor used to observe recordings past the former cap and to inject
the cap regression; it is never a stopping condition in Fixed. Fairness does not
force speech to stop or force a recording to end.

`SpeechRenewsDeadline`, `NoTimeoutWhileTalking`, `NoEarlySilenceTimeout` and
`SilenceTimesOut` retain the renewal, safety and continuous-silence service/progress
contracts. `RecurringSpeechNeverTimesOut` forbids every automatic stop when the
silence deadline has not been reached, including between recurring speech events.
`MutReintroducedCap` adds a 20-minute wall-clock stop and MUST fail that property.
`WitnessSpeechPastFormerCap` requires an actively speaking recording beyond the
former cap; `WitnessSpeechSilenceTimeout` requires speech → silence → ten quiet
ticks → timeout. Both are event/state reachability queries required to fail.

The superseded `CapAlwaysFires` and `CaptureWithinCap` obligations and their four
mutants are removed by the explicit ruling. All other G/I properties and configs,
including newest-target Escape, stale-guard cleanup and the N8 refinement, remain.
The PTT companion also removes `CapStops`/`NoCapMutant`, adds the no-cap regression
and silence-progress mutants, and preserves full archive and raw-text equality.
RuntimeOwnership's acknowledgement, readability, target and focus contracts are
unchanged.

N8 starts at captured A, not only transcribing A. Enabled decode/result contracts
and OverlapPastes prevent holding A behind a recording B that may now last
indefinitely. EventuallyIdle is conditional on captures ending; it never requires
a live speaker to stop. Every acceptance property has an exact failing mutant.

The source replay covers owned admission/cancel/delivery. The new ten-minute
clock policy is a design-level formal check here; this focused replay does not
wait through real microphone/silence intervals or establish installed timing.

## Merged Lane I ownership refinement and source map

`runtime-adapter.ts` seeds the production owned queue with silent recorder and
blocked-decoder fixtures; it observes the real per-take AbortSignal. Admission
and cancellation are never mocked. Fixed wire requests represent the native
resolved target ID or an unknown stale ID; arbitrary IDs for another active
take remain ordinary explicit socket cancellation requests. The native replay
checks stale guards and foreground selection before a command is emitted.
`runtime-contract.json` selects `fixed`; Fixed is a mandatory pass and Current
is an executed strict historical mismatch. No corpus uses an opt-in gate.

`conformance.sh` runs Bun socket replay and Swift LaneG/LaneI replay by default,
with the whole replay through heavy.sh (reusing an ancestor slot to avoid nested-lock deadlock). The Swift corpus includes F5, guarded click,
Escape, all distinct Fixed cancellation contexts, immediate final dispatch,
and the deferred-final-not-dropped trace. Unrelated notch cases are excluded from this recording-only replay. These checks do
not exercise a real mic, input synthesis, or the installed application.

## Source map

| Model action / property | Merged production code |
| --- | --- |
| Record F5; visible drain rejection | `VoiceBarCommandRouter.swift:135`, `:164`; `VoiceState.swift:2586`, `:3395` |
| Record socket; capable/legacy ACK policy | `src/socket-handlers.ts:463`, `:516` |
| Mic/decoder ownership; bounded failed capture | `src/recording-take-queue.ts:84`, `:112`; `src/recording-jobs.ts:63` |
| Capture exit proof; full archive; decode queue | `src/input.ts:2663`, `:3035`, `:3363` |
| Speech renewal implementation before the 11:00Z D3 policy update | `src/input.ts:2571`, `:2595`, `:2680`, `:2809` |
| Immediate final; no cosmetic floor | `VoiceState.swift:2654`, `:4063`, `:4254` |
| Scoped cancel / durable take signal | `src/socket-handlers.ts:363`; `src/recording-jobs.ts:115` |
| Guard/cooldown; newest Escape; stale guard | `VoiceState.swift:1019`, `:2009`, `:2667` |
| Captured app/window/element delivery | `VoiceState.swift:2643`, `:4588`; `CommandModeAXHelper.swift:97`; `SynthesizedKeyEvents.swift:9` |
| Delivery ACK bound and unverified persistence | `src/recording-jobs.ts:143`; `VoiceState.swift:4776` |
| Disconnect/new owner reset | `VoiceState.swift:3399`, `:3412`; `SocketServer.swift:497` |
| Transcript commit then Lane D gate evidence | `src/input.ts:3581`, `:4365`, `:4538`, `:4661` |

The ownership supplement checks acknowledgement settlement without fair ACK
arrival, captured-target delivery, focus custody, drain notice and mic release.
The PTT supplement checks raw sequence retention, speech renewal, ten-minute silence and the absence of a cap.
All properties in both supplements have their own exact-property failing mutants.

Current failures, all exact-property checks: native F5 cancels A, socket start is
busy, processing click lacks a guard, result delivery waits for a cosmetic floor,
new recording drops a deferred final, and PTT timeout is allowed during speech.
See normalized traces, [run.json](results/run.json), and [MUTANTS.md](results/MUTANTS.md).

## F6 identity readability refinement (lead ruling, review I2)

AX identity can be unreadable at record start in Electron/T3 and Ghostty/cmux.
Readable-and-different is a mismatch. Unreadable is a distinct case: delivery may
use guarded typing only while the captured app PID/bundle is still frontmost and
no other take is recording (including a pending new take). A readable identity
still requires the captured window and element. Owned delivery never activates
an app. The ownership supplement now varies readability at Record and checks
both allowed single-take fallback and forbidden fallback during B. The exact
property/mutant table is regenerated by the union checker. All ownership/readability, retention and decode contracts are retained. Only
the three superseded cap obligations and their five old mutants are retired by
the 11:00Z D3 ruling; ProductClock now uses the ten-minute silence deadline.

X selects the newest processing take and arms/commits that take's own guard.
Escape retains its shown-take bypass; neither path can borrow another guard.
