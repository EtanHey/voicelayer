# Lane G — integration union merge

Status: PASS — all requested merged-head checks complete.
Merge parents: Lane G `0fb80413992d7aeb74be8a37f87a24455fa353b9` and approved
integration `f98243d2b2141ff0f0d16c3f145cb76cfcd0ebae`.

## Union retained

- Lane A: collapsed-notice-shell, out-of-range timer and rearming timer mutants;
  sole-item Hold-to-talk refinement; explicit transientNoteOffersHistory input;
  production wingLabel adapter; notchPolicy fixed.
- Lane G: MutCoreWing, MutOutsideBand, numeric 132 pt wing bound, N3 notice/band
  capacity, all deadline/overlap/retention properties, and exact divergence pins.
- No acceptance property or registered config from either parent is dropped.
  Notch retains all 9 acceptance properties; pipeline retains all 25.
- generate-configs.py owns the combined mutant list, so rerunning it preserves
  the three Lane A mutants. A's MutantStuck re-arms expiry; G's MutNeverExpire
  disables it. Both remain distinct mandatory temporal failures.
- The corpus carries transientNoteOffersHistory explicitly and the Swift fixture
  passes it directly to the production operational input. This is note-kind
  metadata, not a text/copy heuristic.

Generated corpus/result conflicts were replaced by TLC output from the merged
spec, never combined by hand. App and daemon production sources exactly match
approved integration f98243d2; this resolution adds no production edits.

## Verification

| Command | Result |
| --- | --- |
| bash formal/notch-presentation/check.sh --record | 24/24 expected outcomes: 2 PASS + 22 EXPECTED_FAIL; Current 51,264 / Fixed 47,376 states |
| bash formal/record-while-processing/check.sh --record | 52/52 expected outcomes: 3 PASS + 49 EXPECTED_FAIL; Current 11,399 / Fixed 62,161 / ProductClock 921 states |
| bash formal/record-while-processing/conformance.sh | 5 PASS / 0 FAIL; 410 both-policy contexts, exact pipeline baseline pins unchanged |
| bash formal/notch-presentation/conformance.sh | 3 PASS / 0 unexpected failures; all eight Fixed notch families zero; no Fixed expected failures; 12,330 both-policy frames and 8 native paths |

Combined: 76 expected TLC outcomes, 34 acceptance properties, **56/56 fault mutants**
failing on their exact named properties (17 notch + 39 pipeline), plus 11 historical
failures and 4 reachability witnesses. The per-model runner requires the exact
invariant/temporal diagnostic and error status for each negative config.

## Union mutant table

### notch-presentation

| Property | Exact-property mutants | Passed mutation gate |
| --- | --- | --- |
| N1CompactNote | MutWideWing, MutCoreWing, MutTextWing | 3/3 |
| N2NoProcessingBand | MutProcessingNote | 1/1 |
| N3GrowsDown | MutTruncate, MutOutsideBand | 2/2 |
| N4NoSubstitute | MutErrorSubstitute, MutDetailsSubstitute | 2/2 |
| N5InlineHistory | MutBusyHistory, MutErrorHistory | 2/2 |
| NoteHasCause | MutStaleNote | 1/1 |
| NoteNeverStuck | MutNeverExpire, MutantStuck | 2/2 |
| TypeOK | MutType, MutantType | 2/2 |
| VisibleHasShell | MutNoShell, MutantNoShell | 2/2 |

### record-while-processing

| Property | Exact-property mutants | Passed mutation gate |
| --- | --- | --- |
| CapAlwaysFires | MutNoCap, MutCapRenewedBySpeech, MutCapBlockedBySpeech | 3/3 |
| CaptureWithinCap | MutNoCapBound | 1/1 |
| D3EveryTakeKept | MutDropTimeout | 1/1 |
| EventuallyIdle | MutNoIdle, MutNoDecodeFairness | 2/2 |
| N6Admissible | MutStallRecord | 1/1 |
| N6PreservesA | MutRecordCancels, MutDisableRecordPreserve | 2/2 |
| N6StartsB | MutRejectRecord, MutDisableRecordStart | 2/2 |
| N7CooldownRing | MutRing | 1/1 |
| N7GuardedClick | MutUnguardedClick, MutDisableCancelBGuard, MutDisableClick | 3/3 |
| N7Identity | MutIgnoreIdentity | 1/1 |
| N7ScopedCancel | MutWrongVictim, MutUnscopedSignal, MutDisableCancelB | 3/3 |
| N8DecodeAdmissible | MutHeldDecode | 1/1 |
| N8FinalNotSuperseded | MutSupersede | 1/1 |
| N8ImmediatePaste | MutHoldResult, MutResultStopsB, MutDelayedPaste, MutHeldDecodeImmediate | 4/4 |
| NoCancelledPaste | MutPasteAfterCancel | 1/1 |
| NoDuplicatePaste | MutDuplicatePaste | 1/1 |
| NoEarlySilenceTimeout | MutEarlyTimeout | 1/1 |
| NoTimeoutWhileTalking | MutSpeechTimeout | 1/1 |
| OneDecoder | MutTwoDecoders | 1/1 |
| OneMic | MutTwoMics | 1/1 |
| OverlapPastes | MutNoOverlapProgress, MutHeldDecodeOverlap | 2/2 |
| ProcessingSettles | MutUnfairProcessing | 1/1 |
| SilenceTimesOut | MutTimeoutNeverFires | 1/1 |
| SpeechRenewsDeadline | MutSpeechNoRenew, MutSpeechDisabled | 2/2 |
| TypeOK | MutType | 1/1 |

## Evidence boundary

Fixed notch assertions have no expected-failure allowance. Historical Current
notch comparisons still execute and require their historical mismatch. The
separate pipeline implementation remains Current until Lane I integrates it;
its Fixed daemon/native mismatches remain explicitly pinned by ordinary mandatory assertions, without Fixed expected-failure wrappers. This is not a
Fixed pipeline source PASS or installed/live acceptance claim.

The approved source, corpus/model hashes and replay outcomes are recorded in
results/run.json, results/corpus.json and results/conformance.json under each
model. CI and installed/live acceptance were not run by this lane. No audio,
real microphone, input synthesis, resident-app stop/start or install was used.

The Swift replay verified explicit History metadata using synthetic busy-note copy
without the word Busy. The historical Current notch comparisons are the only
expected-failure wrappers executed. Native pipeline differences are ordinary
mandatory exact-pin assertions until Lane I flips the pipeline policy. No Fixed
expected-failure wrapper executed in this focused replay.
