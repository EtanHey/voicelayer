# Lane G FIXED-2 — final review receipt

Base: `23f39dba7fbda43b4f497068134dd34431deedeb`. Status: FIXED; all eight findings addressed.
All changes are local to this lane. The captain integrates and verifies on M1.
No application production source changed; there was no app installation, restart,
audio emission, microphone use or input synthesis.

## Findings addressed

| Finding | Change and review pointer |
| --- | --- |
| P1-1 silence deadline/cap | `record-while-processing/RecordWhileProcessing.tla:33` adds renewed silence and independent elapsed clocks. `:40` separates timeout and hard-cap causes and archives either stop; `:96` advances clocks. `:169` checks renewal, early timeout, capture bound, cap service/progress and continuous-silence service/progress. `ProductClock.cfg:1` uses 60-second steps, silence 1 and cap 20 (1,200 s). Never-timeout, no-renewal, no-cap, cap-renewed-by-speech and cap-blocked-during-speech all fail their exact properties. |
| P1-2 held decode | `RecordWhileProcessing.tla:147` adds N8DecodeAdmissible and includes it in N8ImmediatePaste. `:164` starts OverlapPastes from captured or transcribing A and requires decode/result availability while B records, plus progress. Three distinct hold-decode configs fail the three exact contracts even though B is bounded. |
| P2-1 Fixed replay drift | `flow-bar/Tests/VoiceBarTests/LaneGFormalConformanceTests.swift:101` pins each Fixed family's full sorted divergence multiset SHA-256/count outside XCTExpectFailure. FixedProjection additionally binds full expected projection and actual output on already-divergent frames. `record-while-processing/conformance.test.ts:55` uses ordinary mandatory Bun assertions over complete context/outcome tags; failingIf is removed. Each model's results/conformance.json holds the pins. |
| P2-2 captured is not idle | `RecordWhileProcessing.tla:13` defines Unsettled including captured work; `:168` uses it for EventuallyIdle. MutNoDecodeFairness removes only Decode fairness and fails EventuallyIdle. |
| P2-3 speech registration/reachability | `RecordWhileProcessing.tla:35` retains a spoke bit. `:179` and WitnessSpeechSilenceTimeout.cfg require an actual speech → silence → timeout trace. SpeechRenewsDeadline also requires speech registration to be enabled, so disabling Talk(TRUE) fails directly. |
| P3-1 core-wide wing | `notch-presentation/NotchPresentation.tla:83` bounds either wing at 132 pt, below the 185 pt core. `flow-bar/Tests/VoiceBarTests/LaneGFormalConformanceTests.swift:164` applies the same number in every mode. MutCoreWing uses exactly 185 and fails N1CompactNote. |
| P3-2 N3 outside band | `NotchPresentation.tla:91` requires every visible notice to own a band with full line capacity; the antecedent no longer depends on band. MutOutsideBand fails N3GrowsDown. `flow-bar/Tests/VoiceBarTests/LaneGFormalConformanceTests.swift:187` checks missing bands and legacy note geometry; the explicitly pinned N3NoticeBand family records baseline gaps. The README states the 72 pt scroll boundary, with strict grow-down probes over 1–3 lines. |
| P3-3 Bun pin | `.github/workflows/formal.yml:33` pins Bun 1.4.4, matching the executable used for this receipt. TLC remains version/checksum-pinned. |

## Verification

The two model runners check **73 configs**: **5 positive passes**, **53 exact-property
mutant failures**, **11 historical failures**, and **4 event-anchored witness
failures**. All 34 acceptance properties have targeted failing mutants. Exact
named TLC invariant/temporal diagnostics and the corresponding failure exit code
are mandatory; an unexpected PASS or wrong property is a runner failure.

| Command | Result |
| --- | --- |
| `bash formal/notch-presentation/check.sh --record` | 21 expected outcomes: Current 51,264 / Fixed 47,376 states; 14 mutants, 5 historical failures |
| `bash formal/record-while-processing/check.sh --record` (then `python3 -B formal/check-model.py formal/record-while-processing --record` + conformance export after making the two older timing mutants use the exact ratio) | 52 expected outcomes: Current 11,399 / Fixed 62,161 / ProductClock 921 states; 39 mutants, 6 historical failures, 4 witnesses |
| `bash formal/notch-presentation/conformance.sh` | 3 tests, 0 unexpected failures; 12,330 Current/Fixed frames, 2 cause-ending cases and 8 native paths; nine Fixed divergence families match exact pins |
| `bash formal/record-while-processing/conformance.sh` | 5 ordinary mandatory passes, 0 failures; 410 contexts; two Fixed divergence families match exact baseline pins |
| Fixed-corpus drift probes (Swift under heavy.sh, single-file Bun under nice 19) | Both EXPECTED_FAIL, exit 1: 468 Fixed recording-note rows hidden; 34 Fixed stale-ID cancel replies changed to noop. Strict divergence-set checks fail; fixtures and checksum pins restored byte-for-byte |

The initial literal 1/20 two-take clock graph exceeded the 180-second per-config
budget. The final suite separates two questions using the **same** clock/actions:
full two-take concurrency with CapLimit=3, and exact-ratio ProductClock with
SilenceLimit=1, CapLimit=20 and admission restricted to A. Dedicated clock mutants
also use the exact ratio. This checks deadline/cap logic without claiming an
exhaustive literal-20-minute two-take schedule graph. No positive run uses a
state/depth cutoff. There is no fairness on speech, or a forced stop action;
Tick and due timeout/cap handlers are fair. Physical scheduler latency is outside
the model.

SilenceTimesOut includes deadline-handler availability: without it a later hard
cap could mask a disabled silence timer. OverlapPastes includes decode/result
availability: plain leads-to would accept a decoder held until B's bounded cap.
Those safety and liveness clauses are expressed as a single equivalent temporal
formula so TLC names the exact declared property instead of an anonymous split
safety component. Temporal mutant failures are exit 13 with that property name.

The speech witness is event-anchored: F5 → speech → silence → tick → timeout, not a count of unordered states. The cap is
a distinct cause allowed during speech; the silence-timeout cause is forbidden
during speech. D3 keeps the recording for either cause.

## Full exact-property mutant table

### notch-presentation

| Property | Mutants (each MUST fail on this exact property) |
| --- | --- |
| N1CompactNote | MutWideWing, MutCoreWing, MutTextWing |
| N2NoProcessingBand | MutProcessingNote |
| N3GrowsDown | MutTruncate, MutOutsideBand |
| N4NoSubstitute | MutErrorSubstitute, MutDetailsSubstitute |
| N5InlineHistory | MutBusyHistory, MutErrorHistory |
| NoteHasCause | MutStaleNote |
| NoteNeverStuck | MutNeverExpire |
| TypeOK | MutType |
| VisibleHasShell | MutNoShell |

### record-while-processing

| Property | Mutants (each MUST fail on this exact property) |
| --- | --- |
| CapAlwaysFires | MutNoCap, MutCapRenewedBySpeech, MutCapBlockedBySpeech |
| CaptureWithinCap | MutNoCapBound |
| D3EveryTakeKept | MutDropTimeout |
| EventuallyIdle | MutNoIdle, MutNoDecodeFairness |
| N6Admissible | MutStallRecord |
| N6PreservesA | MutRecordCancels, MutDisableRecordPreserve |
| N6StartsB | MutRejectRecord, MutDisableRecordStart |
| N7CooldownRing | MutRing |
| N7GuardedClick | MutUnguardedClick, MutDisableCancelBGuard, MutDisableClick |
| N7Identity | MutIgnoreIdentity |
| N7ScopedCancel | MutWrongVictim, MutUnscopedSignal, MutDisableCancelB |
| N8DecodeAdmissible | MutHeldDecode |
| N8FinalNotSuperseded | MutSupersede |
| N8ImmediatePaste | MutHoldResult, MutResultStopsB, MutDelayedPaste, MutHeldDecodeImmediate |
| NoCancelledPaste | MutPasteAfterCancel |
| NoDuplicatePaste | MutDuplicatePaste |
| NoEarlySilenceTimeout | MutEarlyTimeout |
| NoTimeoutWhileTalking | MutSpeechTimeout |
| OneDecoder | MutTwoDecoders |
| OneMic | MutTwoMics |
| OverlapPastes | MutNoOverlapProgress, MutHeldDecodeOverlap |
| ProcessingSettles | MutUnfairProcessing |
| SilenceTimesOut | MutTimeoutNeverFires |
| SpeechRenewsDeadline | MutSpeechNoRenew, MutSpeechDisabled |
| TypeOK | MutType |

## Integration boundary

Fixed remains the design spec; Current is strict baseline source conformance.
There are nine pinned Swift Fixed families and two pinned daemon families.
Those source mismatches are explicit debt, not Fixed-source or installed PASS.
The baseline pins are strict while the implementation policy is Current; changing
notchPolicy/pipelinePolicy to Fixed makes Fixed's comparison mandatory and stops
expecting baseline divergences. The historical Current comparison still executes.
Lane A/I retain the existing fixture seams; this change adds operators/properties
and configs rather than replacing that structure. Do not refresh a divergence pin
to absorb an unexplained change: inspect the changed model/input/output first.

Per-config normalized traces and source/config/spec hashes remain in each
results/ directory; corpus hashes bind both-policy default fixtures. The CI job
runs all formal/*/check.sh plus both source replays. Remote CI and installed/live
acceptance are not claimed. This receipt supersedes REVIEW-ROUND2.md's counts
and baseline-debt description for the new delta.

The runtime drift probes re-hashed their intentionally modified corpus to pass
the ordinary corpus-integrity check first. Swift then rejected changed
FixedProjection/FixedText divergence sets (FixedText 1,524 → 1,992); Bun rejected
the changed Fixed/cancel SHA even with the same count of 280 divergences. Thus
these probes test the divergence guard, rather than only a stale checksum.

Cleanup: the worktree-filtered process check found zero bun/swift-test/xctest
processes, and this lane's `.build.noindex/swift` cache was removed.
