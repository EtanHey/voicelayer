# Recording during processing — availability, identity and delivery

`Current.cfg` models the source policy starting at
`e75a4eb662a534665c36240916ab918a00aabf2c`. `Fixed.cfg` refines the merged Lane I code; it is the mandatory runtime policy.
A model PASS does not establish installed or live acceptance.

```sh
bash formal/record-while-processing/check.sh
bash formal/record-while-processing/conformance.sh
```

Default checks run the full union of Lane G and Lane I exact-property mutants
and event-anchored witness queries, then generate both corpora. The runtime
ownership and PTT silence/cap modules are composed by the root check script.
The complete [union table](results/UNION-MUTANTS.md) records all 49 mutants; no
property was dropped during reconciliation. Logs and graphs stay in `.build.noindex/`;
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
  cancellation is immediate. Escape targets the foreground recording when present, otherwise the newest
  processing take, using its identity-bound guard when it is not displayed.
  `EscapeTargetsNewest` is an enabled-action contract; `NoStaleGuard` checks
  stale guard dismissal. Both have exact-property mutants.
- N8 requires Complete to be enabled and dispatch immediately, including overlap.
  A separate invariant rejects superseded finals. `deliveries` is a dispatch count,
  not proof that a host inserted characters.
- `cancelRequested` survives phase changes. Complete can race cancellation while
  the phase is `cancelling`; it must consume that request rather than paste. The
  paste-after-cancel mutant deliberately ignores the token and fails `NoCancelledPaste`.
- D3 retains stopped, cancelled, timed-out and failed captures. Archive writes are
  assumed successful; byte durability and disk failures are not proved here.
- `talking[t]` changes through speech/silence events. Fixed timeout is enabled only
  in silence. `OldSpeechTimeout` exposes the Current PTT wall-clock timeout; the
  fixed policy's timeout-while-speaking mutant must fail `NoTimeoutWhileTalking`.
  This lifecycle timeout is the silence stop; the separate PTT module models
  the 60-second renewal budget and the explicit 20-minute hard cap, which may
  end speech while keeping/transcribing the full recording.

`ProcessingSettles` assumes fair decode, result, cancellation-reap and timer work.
`OverlapPastes` additionally requires A's overlap to dispatch or reach an explicit
failure/user cancellation; supersession is not success. `EventuallyIdle` is a
**conditional drain** property after both takes have finished capture. It does not
force a live speaker to stop or make recording terminate by fairness. Each of
these temporal properties has a mutant that fails on that exact named property.

## Default source conformance and integration seam

Both policy graphs export real socket/click/Escape contexts, outcomes and cancel
signal tokens. The harness does not recompute expected replies from a phase rule.
It calls the production `handleSocketCommand`, checks its reply and signal identity,
and rejects an unscoped stop signal for a scoped cancellation. Recording/playback
edges are silent fixtures under the normal isolation preload. `corpus.json` and its
hash allow the same tests to run by default without a prior TLC invocation.

`runtime-adapter.ts` seeds the production owned queue with silent recorder and
blocked-decoder fixtures; it observes the real per-take AbortSignal. Admission
and cancellation are never mocked. Fixed wire requests represent the native
resolved target ID or an unknown stale ID; arbitrary IDs for another active
take remain ordinary explicit socket cancellation requests. The native replay
checks stale guards and foreground selection before a command is emitted.
`runtime-contract.json` selects `fixed`; Fixed is a mandatory pass and Current
is an executed strict historical mismatch. No corpus uses an opt-in gate.

`conformance.sh` runs Bun socket replay and Swift LaneG/LaneI replay by default,
with Swift through heavy.sh. The Swift corpus includes F5, guarded click,
Escape, all distinct Fixed cancellation contexts, immediate final dispatch,
and the deferred-final-not-dropped trace. Lane G's notch corpora remain intact
and run through their existing expected-baseline comparison. These checks do
not exercise a real mic, input synthesis, or the installed application.

## Source map

| Model action / property | Merged production code |
| --- | --- |
| Record F5; visible drain rejection | `VoiceBarCommandRouter.swift:135`, `:164`; `VoiceState.swift:2586`, `:3395` |
| Record socket; capable/legacy ACK policy | `src/socket-handlers.ts:463`, `:516` |
| Mic/decoder ownership; bounded failed capture | `src/recording-take-queue.ts:84`, `:112`; `src/recording-jobs.ts:63` |
| Capture exit proof; full archive; decode queue | `src/input.ts:2663`, `:3035`, `:3363` |
| Speech renewal; 60-second silence; 20-minute cap | `src/input.ts:2571`, `:2595`, `:2680`, `:2809` |
| Immediate final; no cosmetic floor | `VoiceState.swift:2654`, `:4063`, `:4254` |
| Scoped cancel / durable take signal | `src/socket-handlers.ts:363`; `src/recording-jobs.ts:115` |
| Guard/cooldown; newest Escape; stale guard | `VoiceState.swift:1019`, `:2009`, `:2667` |
| Captured app/window/element delivery | `VoiceState.swift:2643`, `:4588`; `CommandModeAXHelper.swift:97`; `SynthesizedKeyEvents.swift:9` |
| Delivery ACK bound and unverified persistence | `src/recording-jobs.ts:143`; `VoiceState.swift:4769` |
| Disconnect/new owner reset | `VoiceState.swift:3399`, `:3412`; `SocketServer.swift:497` |
| Transcript commit then Lane D gate evidence | `src/input.ts:3581`, `:4365`, `:4538`, `:4661` |

The ownership supplement checks acknowledgement settlement without fair ACK
arrival, captured-target delivery, focus custody, drain notice and mic release.
The PTT supplement checks raw sequence retention, speech renewal and hard cap.
All properties in both supplements have their own exact-property failing mutants.

Current failures, all exact-property checks: native F5 cancels A, socket start is
busy, processing click lacks a guard, result delivery waits for a cosmetic floor,
new recording drops a deferred final, and PTT timeout is allowed during speech.
See normalized traces, [run.json](results/run.json), and [MUTANTS.md](results/MUTANTS.md).
