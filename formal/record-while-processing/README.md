# Recording during processing — availability, identity and delivery

`Current.cfg` models the source policy starting at
`e75a4eb662a534665c36240916ab918a00aabf2c`. `Fixed.cfg` is the intended design.
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
  after the renewed silence deadline, while the hard cap is a separate stop cause. `OldSpeechTimeout` exposes the Current PTT wall-clock timeout; the
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

## Capture timing and captured-take overlap

`ProductClock.cfg` checks the exact product ratio: one clock step is 60 seconds,
`SilenceLimit = 1`, `CapLimit = 20` (1,200 seconds). Speech renews the silence
deadline but never the hard cap. The silence `timeout` and hard `cap` are distinct
causes: speech forbids the former; the latter must stop even continuous speech.
Both archive the take. Deadline service availability and fair timeout/cap handlers
are checked, not just a guard that could hold because timeout is disabled. There
is no fairness assumption that forces the speaker to become silent.

The full two-take graph uses `CapLimit = 3` as a conservative finite concurrency
abstraction. The single-capture ProductClock graph uses the same operators with
the literal 1/20 ratio, restricting only admission to A; A/B capture-clock logic
is symmetric. All dedicated timing mutants also run that literal ratio. This
keeps exhaustive graph and fairness checking small without silently dropping the
real product deadlines. Neither clock model proves wall-clock scheduler latency.

`SpeechRenewsDeadline` rejects missed speech registration and failed renewal;
`NoEarlySilenceTimeout` rejects early firing; `SilenceTimesOut` checks deadline
service availability and eventual stop under uninterrupted silence;
`CaptureWithinCap` and `CapAlwaysFires` check the bound and eventual stop. A broken
timeout cannot hide behind a later cap because the deadline-availability clause
fails first. The cap-disabled, cap-renewed-by-speech, cap-blocked-during-speech,
never-timeout, no-renewal and early-timeout mutants all have exact failing configs.

`N8DecodeAdmissible` and `N8ImmediatePaste` require an enabled capture-to-decode
transition while B records and preserve B's microphone ownership. `OverlapPastes`
combines progress from captured A with immediate decode/result availability. A
plain leads-to formula would still accept Decode delayed until B's bounded cap;
the availability clauses deliberately close that dodge. Weak fairness alone does
not promise that a scheduler will finish A before an adversarial immediate stop
of B, so that stronger ordering is not claimed. Three hold-decode mutants target
N8DecodeAdmissible, N8ImmediatePaste and OverlapPastes separately.

Event-anchored negative queries require decode(A) during B's recording and
speech(A) → silence(A) → timeout(A), alongside the prior overlap/cancel witnesses.
Removing Decode fairness must fail `EventuallyIdle` because captured work remains
unsettled. Default replay still executes both policies; switching runtime policy
to Fixed makes its comparison strict and removes baseline-pin expectations.
