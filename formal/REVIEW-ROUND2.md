# Lane G — round 2 receipt

Status: all six P1, five P2 and both P3 findings addressed. Application production
code is unchanged. Fixed is the design contract; baseline source gaps are executed
as explicit strict expected failures until Lanes A/I implement them. No installed
or live acceptance and no remote CI run is claimed.

## Verification

| Command | Observed result |
| --- | --- |
| `bash formal/notch-presentation/check.sh --record` | 2 exhaustive PASS (Current 51,264; Fixed 47,376 states), 5 historical failures, 12 exact-property mutant failures |
| `bash formal/record-while-processing/check.sh --record` | 2 exhaustive PASS (Current 2,883; Fixed 12,453), 6 historical failures, 27 exact-property mutant failures, 2 event-anchored negative reachability failures |
| `bash formal/notch-presentation/check.sh` and `bash formal/record-while-processing/check.sh` | All 56 configs repeated successfully; zero tracked/artifact file changes; regenerated corpora byte-identical to recorded corpora |
| `bash formal/notch-presentation/conformance.sh` | Default, heavy-lock-serialized Swift: 3 tests, 0 unexpected failures; 12,330 Current/Fixed frames, 2 cause-ending edges, 8 native graph paths. Seven baseline expected-failure families executed |
| `bash formal/record-while-processing/conformance.sh` | Default Bun: 5 reported passes, 0 failures (3 strict passes and 2 strict expected-failure tests); 410 graph contexts, both policies, socket/click/Escape and stale IDs |
| `TLC="$PWD/formal/tlc.sh" ~/.local/state/captain-2.2.61/heavy.sh G bash formal/speech-queue/check.sh` | Existing runner passes with pinned jar: 5 positive configs, 12 expected counterexamples, real Swift and daemon replay; final Bun phase 65 passes / 0 failures |
| Python AST, shell syntax and workflow YAML checks | 7 Python files, 5 shell scripts and new workflow parse successfully |

The 28 acceptance properties have **39 targeted fault mutants**. Each negative
config isolates one exact property; an unexpected PASS, wrong property, parser
failure or timeout fails the runner. The other negative checks are 11 historical
source-policy failures and 2 event-anchored reachability queries. All negative
checks have the expected TLC invariant/temporal exit status and exact named error.
No positive graph has a state/depth constraint.

Mutation tables (one row per acceptance property):

- [Notch: 9 properties / 12 mutants](notch-presentation/results/MUTANTS.md)
- [Pipeline: 19 properties / 27 mutants](record-while-processing/results/MUTANTS.md)

Normalized TLC traces, state counts, spec/config/source hashes and complete graph
hashes are in each `results/run.json` and named `.log`. Runtime receipts distinguish
expected source failures in each `results/conformance.json`. Raw logs and graphs
remain in ignored `.build.noindex/`. Only `--record` refreshes tracked evidence.

## Finding → fix

| Finding | Fix and review pointer |
| --- | --- |
| P1-1 dodgeable N6/N7/N8 flags | `record-while-processing/RecordWhileProcessing.tla:99` replaces flags with enabled-operation and bad-postcondition exclusion contracts. `:132` adds event-anchored queries. `check-model.py:27` enforces complete mutation coverage; `:61` requires the exact target error. Disabled Record, held Complete, disabled Cancel(B), disabled click and result-stops-B each fail their named property. |
| P1-2 paste after cancel | `record-while-processing/RecordWhileProcessing.tla:17` adds durable `cancelRequested`; `:39` permits Complete during cancelling and checks the token before dispatch; `:126` inspects durable request versus delivery count. `MutPasteAfterCancel.cfg:1` fails on the actual late-paste trace. |
| P1-3 timeout during speech | `record-while-processing/RecordWhileProcessing.tla:31` models speech/silence and gates timeout. `:124` forbids enabled timeout while talking. Historical `OldSpeechTimeout.cfg:1` and fixed-policy `MutSpeechTimeout.cfg:1` both fail the exact property. |
| P1-4 missing grow-down geometry | `notch-presentation/NotchPresentation.tla:34` allocates pixels/rows from 1/2/3-line text, `:88` measures demand and compares capacity. `flow-bar/Tests/VoiceBarTests/LaneGFormalConformanceTests.swift:168` independently measures production heights; `:177` checks unlimited renderer and strictly increasing line-class heights. `MutTruncate.cfg:1` fails N3. |
| P1-5 definitional Fixed / vacuous busy History | `notch-presentation/NotchPresentation.tla:41` counts actual status/note action allocations; `:93` reads the real `historyInline`, no shadow. Independent production ledger starts at `flow-bar/Tests/VoiceBarTests/LaneGFormalConformanceTests.swift:160`; busy and error History have separate failing mutants. |
| P1-6 no default regression guard | `flow-bar/Tests/VoiceBarTests/LaneGFormalConformanceTests.swift:104` runs both corpora with strict coverage assertions and no skip gate. Corpus/spec checksums bind checked-in fallback fixtures. `.github/workflows/formal.yml:53` runs every formal check.sh plus both default source replays. TLC version/cache/checksum is pinned in `tlc.lock.json:1`. |
| P2-1 all-mode numeric wing bounds | `notch-presentation/NotchPresentation.tla:83` bounds both wings in all modes. `flow-bar/Tests/VoiceBarTests/LaneGFormalConformanceTests.swift:131` observes candidate/visible wing text, `:152` checks numeric bounds for every frame. Actual renderer routing is read at `:80`. |
| P2-2 unreachable Details below | `notch-presentation/NotchPresentation.tla:11` models absent diagnostic with available details. `MutDetailsSubstitute.cfg:1` and `MutErrorSubstitute.cfg:1` separately fail N4. Current only emits Error at this baseline, stated in the README. |
| P2-3 thin replay / wrong cancel identity | `record-while-processing/Current.cfg:4` uses global cancellation; `RecordWhileProcessing.tla:54` models possible shared consumers and actual signal identity. `conformance.py:24` exports graph decisions directly. `conformance.test.ts:32` executes all 410 Current/Fixed contexts through the real dispatcher and checks replies and ID-scoped signals. `runtime-adapter.ts:38` is Lane I's ownership fixture seam. |
| P2-4 scripted TLC scenarios | `record-while-processing/conformance.py:30` extracts native command and ordered result/drop paths from graph edges. `flow-bar/Tests/VoiceBarTests/LaneGFormalConformanceTests.swift:210` consumes both policies' 8 paths through native router/VoiceState. `notch-presentation/conformance.py:21` exports the cause-ending edge. |
| P2-5 one-sided text assertions | `flow-bar/Tests/VoiceBarTests/LaneGFormalConformanceTests.swift:133` computes the actual visible string and compares even absent expected text, including forbidden extra note text. `:164` checks the Fixed corpus too. |
| P3-1 dirty default checks | `check-model.py:20` sends raw logs/graphs to ignored cache; `:95` writes normalized tracked evidence only under explicit `--record`. Repeated default runners produced zero file-content changes. |
| P3-2 missing overlap/drain liveness | `record-while-processing/RecordWhileProcessing.tla:129` adds OverlapPastes and conditional EventuallyIdle after both captures finish. `MutNoOverlapProgress.cfg:1` and `MutNoIdle.cfg:1` fail the exact temporal properties; their names are checked in TLC output. |

## Source-policy counterexamples retained

Action contracts can fail in the **pre-state** where an enabled action has a bad
postcondition, or a required action is disabled. Their trace ends before that
operation; this is intentional, rather than a missing event in the replay.

- A records → capture ends → A transcribes. A new socket Record(B) rejects Busy;
  native F5 instead requests cancellation of A. `OldSocketBusy.log` and
  `OldF5CancelsA.log` record the exact pre-state/action violations.
- A transcribes without a guard. Click can cancel immediately (`OldUnguardedCancel`).
- A transcribes with display-floor ticks left. Complete defers dispatch
  (`OldDisplayFloor`). A result becomes ready → socket starts B → new recording
  event supersedes A (`OldDeferredFinalDrop`, full seven-state trace).
- F5 starts A → speech begins. Timeout remains enabled despite `talking[A]=TRUE`
  (`OldSpeechTimeout`, three-state trace).
- Missing diagnostic → error projects Error into a wing; processing → busy note
  projects a band; preview → busy note lacks inline History; update/preview cause
  ends while quit refusal persists. Five notch historical logs preserve these.

The late-paste mutant is a **designed faulty variant**, not a newly established
production race. It proves that paste after a cancel request is now observable.
Likewise Details below is an exercised regression variant, not claimed baseline
output. Current global cancel cannot faithfully promise a particular take identity.

## Integration instructions

1. Lane A points the Swift input/observer helpers at its final notch API, implements
   N1/N2/N4/N5/cause clearing, then changes `runtime-contract.json.notchPolicy` to
   `fixed`. Fixed source checks become strict; historical Current is still executed
   with a required mismatch. N3 and all-mode numeric wing bounds are already strict.
2. Lane I seeds its real owned-take registry in `runtime-adapter.ts` from `row.before`
   and `captureIds`, observes its actual scoped cancellation primitive, and adapts
   the native event-ID bindings if needed. Set `pipelinePolicy` to `fixed` only
   after both Fixed daemon/native corpora pass; no decision logic is mocked.
3. Run both check.sh and conformance.sh commands. Do not reinterpret model Fixed
   PASS or baseline expected failures as source, installed, or live Fixed acceptance.

No application source was edited, no audio was emitted, and the resident app was
not launched, stopped, installed or replaced. The captain owns integration and
remote CI execution. Final worktree-filtered process check found zero bun/swift-test/
xctest processes; this worktree's `.build.noindex/swift` cache was removed.
