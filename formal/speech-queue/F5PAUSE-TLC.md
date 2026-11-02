# Lane F, final model fix round 2

**Model/checker only.** No product edit, installed-app proof, microphone, audio,
GUI action or F5 runtime conformance claim. This is the final implementation round
against the Claude review of `9884ffa7` (M1–M4, S1–S4, N1–N4), with lead decisions
D-M4 and D-S4. The branch still starts at integration baseline
`6d89690728ae1116dcb8d184847814a32b61fce0`; phase 1 was cherry-picked from `b76c6df1`.

## Contract and domain

The current slot is an **Option+F5 selection read**. Agent voice_speak/voice_ask
preemption and pausing an agent-owned current read are outside this model; this
receipt establishes no policy for them (N3). New requests in this bounded queue
are selection reads. Bounds: three requests (one current, **two waiting**), two
word positions plus the terminal boundary, and two distinct capture identities.
One capture may record while another transcribes. Identity reuse and an unbounded
stream of new captures are outside this finite check.

| Flow | Fixed contract and guard |
|---|---|
| F5 over PLAYING | Park the containing word before opening capture; owner f5; no word skipped |
| F5 over PREPARING (D-M4) | Explicit `parked_preparing`, owner f5; logical read launch waits for every capture to settle |
| F5 while A transcribes (D-S4 / N6) | Open capture B, preserve A; never Busy or implicit cancel |
| A settles with B still recording/transcribing | Read stays parked; `NoSpeechDuringOpenMic` includes every active identity |
| Final capture settles: pasted, empty, failed, cancelled, timeout | Resume from the anchored word; a preparing read starts once; ownership is cleared |
| Physical hold remains down after settlement | Keep held/keyCap independent of Finish; later key-up leaves the read untouched |
| Double tap locks capture | Physical key-up does not stop the locked recording; the subsequent explicit capture stop can |
| User pause before/during capture | User ownership persists across **every event**, including stale settlement, until UserPlay/UserStop |
| Speech Stop during capture | Stop wins through every settlement; no automatic resurrection |
| Stale/late settlement | Actual speech, position and owner are unchanged, not merely a counter |
| R2-03 queue count | The preparing/playing/parked current is excluded; +2 and a third request are explored |
| R2-05 timing | First logical playing frame has real timing or an estimate; real alignment is not assumed to arrive |

There is one capture-scoped stop per identity. It never changes the read. A physical
up-edge is separately modelled even when no capture remains; `ReleaseNeverDropsRead`
checks the read tuple on **every** up-edge, not the capture_stop action (N1).
`CaptureStop` is an explicit second tap after key-up, not VAD cutting off a held key.
Failure/cancel/deadline settlement can occur while the physical key remains down.

Logical read launch is atomic at final settlement for a parked preparing read.
This abstracts first-chunk availability and player startup, and proves no latency
or synthesis-readiness bound. Repeated settlement of an idle capture identity is a
StaleEnd, whose behavioural guard forbids a second launch/resume. Only a deliberate
UserPlay can leave a manual pause; only UserStop or a fresh read replaces a stopped
slot. Player quiescence before mic admission still needs real-code evidence.

## Independent anchors and behavioural properties

`pressPos` is a diagnostic pre-state observation, set when F5 encounters a playing
or preparing read, or when the user first pauses it. A later capture over an already
parked read does not replace that anchor. `PauseAtWordBoundary` requires both
`pos = Boundary(pressPos)` and `pausedAt = WordAt(pressPos)`. The actual resumed cursor
is checked against **pressPos**, independently of the implementation's parked word.
The final settlement of an f5 owner must actually play the read, so silently
dropping it cannot satisfy liveness merely by reaching stopped. N6's capture edge
also preserves the parked read tuple; N6DropsRead and DropAtEnd test these cases.
Parking both fields at zero or both at the next word therefore fails (M3).

The NoDoubleResume property compares the read tuple before/after stale settlement
and any genuine settlement while another capture remains;
there is no artificial resume counter. Both DoubleResume and the reviewer's exact
StaleResumesPaused probe perform a real resume. The legitimate resume API's
parked-read and all-captures-settled preconditions remain intact; only the stale
settlement/ownership protection is removed. It does not invent a seek/restart on an
already playing or unparked preparing read. `manualHold` tracks the
user's intent separately from the possibly corrupted owner field, and persists
until UserPlay/UserStop (M2). OwnerConsistent additionally requires that a user owner has a real manual intent.
Its isolating mutant retains the **user**
owner on UserPlay, so it does not also corrupt the f5-outside-capture property (S2).
TypeOK's mutant corrupts the semantic owner domain, not an admission counter (N2).

## Current projections and their limits

Fixed=FALSE projects the old router: an F5 over a playing/preparing read is ignored
or stops it; while transcribing it **cancels A**, rather than opening capture B.
The Current configs expose these failures separately. Current word-boundary and
queue/timing failures remain explicit. They are source projections, not app replays.

CurrentPostRelease is a **boundary projection**: the target daemon already parks
and settles the read, but the current router's up-edge still calls speech Stop.
CurrentCancelPostRelease uses SpecCancelUp, starting with that read parked at word 1
while A transcribes; the current router then cancels A on F5 and stops the resumed
read on key-up. This is the precise mixed-version hazard from M1, not a claim that
the old unmodified app already auto-pauses/resumes. FixedTranscribing checks the same
initial boundary against the new N6 contract: F5 opens B and the read waits for both.
The ordinary Fixed graph also reaches overlapping captures and post-settlement
key-up after failure, cancellation and timeout, without a special initial state.

## Deadlines and fairness (S1)

The stronger property is checked:
`owner = f5 ~> (speech in {playing, stopped} or owner = user)`.
It does not merely assert that the owner field eventually changes.

The model explicitly gives **each capture phase** an age in 0..CaptureBound and a
Timeout(c) transition that settles only that identity. CaptureBound=1 is an abstract
expired-deadline tick, not one millisecond or a measured latency. Moving a recording
to transcribing resets that identity's phase age. Clock fairness makes an eligible
phase deadline eventually expire; per-identity Timeout fairness makes its callback
run. There is no fairness on user input or ordinary EndCapture, and no assumption
that the provider voluntarily returns. Finite issued identities prevent an infinite
stream of fresh captures from keeping a single read parked forever.

Source custody for those assumptions:

- The bar's record handler passes `(timeout_seconds ?? 30) * 1000` to waitForInput
  (`src/socket-handlers.ts`, record case). `recordToBuffer` in `src/input.ts` arms
  `setTimeout(onTimeout, timeoutMs)` for PTT. Its comment explicitly preserves PTT's
  timeout; VAD HOLD suppression is a separate path. The recording deadline in this
  model abstracts that PTT/scoped-settlement bound, not a new cut-off while speaking.
- A universal transcription-chain settlement bound was **not established** from
  this checkout. Wispr's own WebSocket attempt has a 30-second timer in `src/stt.ts`;
  whisper-server's attempt has an AbortController timeout with a 120-second ceiling
  (`src/whisper-server.ts`). Neither establishes a bound for the complete fallback
  and postprocessing chain. The model therefore makes a **target transcription
  deadline explicit**, rather than hiding this gap inside WF(CaptureAdvance).
  Phase 2 must supply a per-take bound/cancellation path without ending another
  recording or deleting its retained audio. VAD hold/silence policy is not changed
  by this model; arbitrarily held VAD sessions need their own liveness assumption.
- Fair scheduling of a timer and its callback is still an assumption about the
  event loop; TLC cannot prove the host scheduler or product code honours it.

F5PauseStuck now drops only Clock fairness. It must violate AutoPauseNeverStuck
while **every safety invariant survives** in the cross-kill run. This is independent
of ResumeOnEveryEnd=FALSE, which still has its own safety mutant.

## Cross-kill protocol and named errors

Every isolated mutant flips exactly one constant from Fixed and must fail its exact
named property. Every mutant is then checked against **all 15 Fixed invariants and
the temporal property**, using TLC -continue -lncheck final. TLC stops its invariant
list at the first false predicate in each successor even with -continue. A raw
control demonstrated that TypeOK masked other failed predicates. CrossDiagnostics
therefore evaluates **every actual safety-property operator** in TLC and prints its
name when false. It is a non-filtering state constraint: each clause is
`Property \/ PrintT("CrossKill:Property")`, and the jar's standard TLC module defines
PrintT as TRUE. All original named invariants remain enabled; no assertion is
removed or weakened. Coverage checks require matching diagnostic and property names.
The matrix records all named kills and survivors, including collateral failures.
The streaming wrapper retains each real invariant-error/diagnostic line once, all temporal counterexample states,
and TLC's actual counts/depth; it discards only repeated safety trace text. The
supervisor owns the wrapper and TLC in one process group, with bounded runtime.
The open-first ordering mutant exposes its unsafe mic-open frame and then takes
the handler's pause continuation before unrelated user actions. Fixed never enters
this phase. This avoids enumerating arbitrary extra actions inside a deliberately
broken handler; it preserves the ordering violation and does not prune Fixed flows.

TLC 2.19 emits an anonymous temporal-error headline. The deterministic obligations
record exposes the **strong discharge predicate** under its real property name in
each state. The checker validates a real f5 antecedent followed by no discharge,
and a parsed lasso whose every cycle state has AutoPauseNeverStuck=false. A generic
nonzero exit or an anonymous temporal headline alone is rejected. Safety checks
require exit 12 and the exact invariant name. Cross runs require complete model
checking (or the identified temporal counterexample), a kill of the target property,
and no unrecognized property. KeepOwner and NoFairness must be single-property kills.

The model alone specifies R2-03/R2-05: it assigns the correct published count and
supplies timing at logical launch. The companion `speech_data_conformance.py` now
projects these obligations onto real PlaybackQueueManager events and compiled
VoiceState, with exact-property runtime mutants, in the full `check.sh` gate.
Its generated speech-data logs/results are the evidence for that bounded data-path
projection; the model and older queue/History/admission replays alone are insufficient.
The recorded 8.5-second stall has no model latency budget or measured improvement
claim. Owned fake synthesis proves the startup request bound, not installed latency.

## Review resolution ledger

| Item | Resolution / negative control |
|---|---|
| M1 | Independent physical key and cap ID; settled key-up is enabled; PostRelease plus CurrentCancelPostRelease boundary scenario |
| M2 | Behavioural tuple equality; persistent manual intent; real DoubleResume and StaleResumesPaused |
| M3 | Independent pressPos; ParkZero and ParkNextWord |
| M4 / D-M4 | parked_preparing owner; IgnorePreparing and StartDuringCapture; no empty mislabel |
| S1 | Explicit per-phase timeout; stronger goal; NoFairness independently kills only liveness |
| S2 | Every mutant/all Fixed properties matrix; UserPlay KeepOwner isolating check |
| S3 | Three requests, +2 queue reachable; no runtime evidence claim |
| S4 / D-S4 | Two capture identities; CancelPrevious and ResumeEarly; old cancel router explicitly projected |
| N1 | Release property covers only real physical up-edges; capture_stop removed |
| N2 | InvalidOwner semantic TypeOK mutant replaces TypeBound |
| N3 | Option+F5 current read scope explicit; agent-owned current reads excluded |
| N4 | Flow table states the actual stale behaviour and set-of-captures guard; no Busy/no-op claim |

## Phase-2 implementation handoff

1. **Pause before capture admission**, including preparation: src/socket-handlers.ts
   record handler currently calls stopAll(..., suspend). PlaybackQueueManager.pause
   and pausePlayback in src/tts.ts return unsupported for capture-reserved preparation
   (review anchors 1366 and 2182). Park/own the preparing job as f5 before reservation;
   do not stop it or suspend the selection chain. User pause can convert that owner.
2. **Physical key-up lifetime** in VoiceBarCommandRouter.handleHotkeyHoldEnd: an
   ended/failed/timed-out/cancelled capture must not clear the physical press token.
   A late up-edge must not invoke speech Stop after the daemon has resumed the read.
   Include the old cancel-on-F5-during-transcription → resume → up-edge path.
3. **N6 re-entry**: handleHotkeyHoldStart and handleHotkeySingleTap in .transcribing
   currently call handleCancel. Open a new capture identity B instead. Keep capture
   A's transcription and result delivery alive; do not reuse a scalar busy/idle flag
   as permission to resume the read.
4. **Set-based settlement ownership** in the daemon and VoiceState: resume only
   after every capture has settled, once per read/pause generation. A timeout of A
   must not end B. A stale recording-idle frame/late callback leaves speech, cursor
   and owner unchanged. Persistent user ownership overrides all automatic restore.
5. **Word anchor** in PlaybackQueueManager.pause/park/resume: retain the word at
   the F5 edge and its audio offset. Check resume against that independent anchor;
   writing both stored fields to zero or the next word must fail conformance.
6. **Speech-scoped Stop** during capture must retire the read and its waiting queue;
   physical key-up/capture stop must only advance its own capture. Stop always wins.
7. **Preparing snapshot** in PlaybackQueueManager.emitQueueSnapshot currently marks
   preparing.job is_current:false. VoiceState.queuedSpeakCount counts it; exclude the
   actual current read while preserving true waiting items, including +2.
8. **First-frame timing**: startCloneTiming publishes after playback starts.
   Supply real or estimated timing with the first speaking frame, then replace the
   estimate on alignment. TeleprompterPlaybackScrubBar.timingNotice is a consumer;
   hiding its message alone does not supply timing or an anchored seek position.
9. **Per-take transcription deadline**: provide a concrete full-chain settle/cancel
   bound for the explicit model timeout. Provider-attempt bounds alone are insufficient.
   Retain every recording and preserve a concurrently active recording B.
10. **Swift parked state/UI**: ParkedRead, isPlaybackPaused, record admission and
    scheduleParkedReadRestore need owner + capture-set/generation custody. Any view
    control for converting an f5 pause to user pause belongs to Claude with both
    frontend-design and emil-design-eng. This branch changes no view or capture code.

## Reproduction

All model gates run on the M1 Pro through its captain lock (5-minute load <12).
Fetch lane-f/model from etanheyman@macbook-pro:Gits/voicelayer into the M1 worktree
~/Gits/voicelayer/.worktrees/F-model-m1, check out the exact commit, and run
bun install --frozen-lockfile without changing bun.lock. From that M1 worktree:

```bash
set -euo pipefail
export PATH="$HOME/.bun/bin:/opt/homebrew/opt/openjdk/bin:/opt/homebrew/bin:$PATH"
~/.local/state/captain-2.2.61/heavy.sh F-model /opt/homebrew/bin/gtimeout -s TERM -k 10 3440 bash formal/speech-queue/check.sh --receipt
```

check.sh installs the formal/tlc.lock.json pin through formal/setup-tlc.py; check.py
resolves and verifies the same checksum before use, prints the release, actual TLC
banner and SHA-256, and records them in results.json. The versioned cache is
~/.cache/tla/v1.8.0/tla2tools.jar; the bare shared jar is never edited or used.
The lock/setup/support files are unchanged copies from 23f39dba, the existing repo pin.
TLC uses ParallelGC, 512 MB for isolated runs and 3072 MB for full cross-runs
(the pinned jar exhausted 512 MB on ManualResume, before completing its graph),
and the shared pinned harness's -noGenerateSpecTE flag (only auxiliary trace-exploration
files are suppressed; TLC's counterexample states remain in the logs),
one worker for isolated checks and four TLC workers in the same cross-check process,
fp 0, seed 1 and per-run .build.noindex metadata. The single captain heavy lock
covers both; the per-TLC 90-second bound is unchanged. The original gate retains
880 seconds excluding the cross-kill matrix, which has its own 2400-second supervisor:
24 unchanged 90-second per-case limits plus 240 seconds of overhead on the slower M1.
The outer 3440-second bound covers both budgets, pinned-jar setup and shutdown; timings.json records
isolated TLC, cross-kill, and reachability/runtime replay stages. --f5-only includes
the F5 isolated checks and matrix, but excludes the legacy/runtime admission replays.
--receipt regenerates the following tables from the actual logs; source/config and
jar SHA-256 hashes are retained with results.json. Test preload stays enabled.

| Toolchain | Version | SHA-256 |
|---|---|---|
| Active repository pin on M1/M4 | v1.8.0 | 011267fca25d0752cf18894dd585cd28b96960c112ea8a20b823ea770e7e10cd |
| Prior bare M4 cache (R2 tables below) | TLC2 2.19, 08 August 2024, rev 5a47802 | 936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88 |
| Prior bare M1 cache (failed migration launch) | TLC2 2026.10.28.014557, rev 56d37a9 | fc6878c603f0fdc18b9fe3e5bf51860cb90ab5b1154e3c371660c036d6bdd63e |

Both temporal error formats are recognized. The singular form must name exactly
AutoPauseNeverStuck. The legacy plural form requires that exact named discharge
record in an actual lasso, with an F5-owned antecedent and no later discharge.
The gate runs positive controls for both formats and both lasso shapes, plus
negative controls for wrong names (including a wrong header with a correct
record), anonymous failures, missing/invalid loops, discharged goals and missing
F5 antecedents. Cross-run logging preserves temporal states for both formats.

## Measured TLC results and cross-kill matrix

These are the generated R2/M4 numbers from the prior jar above. A new --receipt
run replaces them; G1's M1 receipt is retained with its results.json and timings.json.
Temporal depth uses TLC's completed Progress(N)
line if its final depth sentence is absent, labelled accordingly.

<!-- TLC-RESULTS-START -->
| Config | Expected | Actual | Generated | Distinct | Depth |
|---|---|---|---:|---:|---:|
| `AdmissionCurrent` | PASS | PASS | 257 | 257 | 3 |
| `AdmissionFinding` | FAIL NonemptySelectionDoesNotStop | FAIL NonemptySelectionDoesNotStop | 69 | 69 | 3 |
| `AdmissionOlderMatch` | FAIL EveryQueuedMatchStops | FAIL EveryQueuedMatchStops | 147 | 147 | 3 |
| `AdmissionProposed` | PASS | PASS | 257 | 257 | 3 |
| `Current` | PASS | PASS | 148729 | 11163 | 9 |
| `F5PauseCancelPrevious` | FAIL F5DuringTranscriptionStartsCapture | FAIL F5DuringTranscriptionStartsCapture | 89 | 80 | 4 |
| `F5PauseCurrent` | FAIL F5PausesPlayingSpeech | FAIL F5PausesPlayingSpeech | 37 | 36 | 4 |
| `F5PauseCurrentCancelPostRelease` | FAIL ReleaseNeverDropsRead | FAIL ReleaseNeverDropsRead | 77 | 50 | 3 |
| `F5PauseCurrentPostRelease` | FAIL ReleaseNeverDropsRead | FAIL ReleaseNeverDropsRead | 386 | 268 | 5 |
| `F5PauseCurrentPreparing` | FAIL F5HoldsPreparingRead | FAIL F5HoldsPreparingRead | 10 | 10 | 3 |
| `F5PauseCurrentQueued` | FAIL QueuedCountExcludesCurrent | FAIL QueuedCountExcludesCurrent | 2 | 2 | 2 |
| `F5PauseCurrentRelease` | FAIL ReleaseNeverDropsRead | FAIL ReleaseNeverDropsRead | 54 | 52 | 4 |
| `F5PauseCurrentTiming` | FAIL TimingNeverBlankWhilePlaying | FAIL TimingNeverBlankWhilePlaying | 7 | 7 | 3 |
| `F5PauseCurrentTranscribing` | FAIL F5DuringTranscriptionStartsCapture | FAIL F5DuringTranscriptionStartsCapture | 62 | 59 | 4 |
| `F5PauseCurrentWordBoundary` | FAIL PauseAtWordBoundary | FAIL PauseAtWordBoundary | 180 | 133 | 5 |
| `F5PauseDoubleResume` | FAIL NoDoubleResume | FAIL NoDoubleResume | 1511 | 841 | 6 |
| `F5PauseDropAtEnd` | FAIL ResumeFromPausedPosition | FAIL ResumeFromPausedPosition | 66 | 57 | 4 |
| `F5PauseFixed` | PASS | PASS | 1637135 | 178577 | 22 |
| `F5PauseFixedTranscribing` | PASS | PASS | 415239 | 55317 | 20 |
| `F5PauseIgnoreF5` | FAIL F5PausesPlayingSpeech | FAIL F5PausesPlayingSpeech | 46 | 40 | 4 |
| `F5PauseIgnorePreparing` | FAIL F5HoldsPreparingRead | FAIL F5HoldsPreparingRead | 12 | 10 | 3 |
| `F5PauseInvalidOwner` | FAIL TypeOK | FAIL TypeOK | 12 | 10 | 3 |
| `F5PauseKeepOwner` | FAIL OwnerConsistent | FAIL OwnerConsistent | 51 | 44 | 4 |
| `F5PauseManualResume` | FAIL ManualPausePersists | FAIL ManualPausePersists | 301 | 212 | 5 |
| `F5PauseN6DropsRead` | FAIL F5DuringTranscriptionStartsCapture | FAIL F5DuringTranscriptionStartsCapture | 361 | 254 | 5 |
| `F5PauseOpenFirst` | FAIL NoSpeechDuringOpenMic | FAIL NoSpeechDuringOpenMic | 46 | 40 | 4 |
| `F5PauseParkNextWord` | FAIL PauseAtWordBoundary | FAIL PauseAtWordBoundary | 12 | 10 | 3 |
| `F5PauseParkZero` | FAIL PauseAtWordBoundary | FAIL PauseAtWordBoundary | 1230 | 729 | 6 |
| `F5PausePostRelease` | FAIL ReleaseNeverDropsRead | FAIL ReleaseNeverDropsRead | 386 | 268 | 5 |
| `F5PauseQueueCount` | FAIL QueuedCountExcludesCurrent | FAIL QueuedCountExcludesCurrent | 2 | 2 | 2 |
| `F5PauseReleaseDrops` | FAIL ReleaseNeverDropsRead | FAIL ReleaseNeverDropsRead | 64 | 55 | 4 |
| `F5PauseResumeEarly` | FAIL NoSpeechDuringOpenMic | FAIL NoSpeechDuringOpenMic | 1819 | 982 | 6 |
| `F5PauseResumeOnPaste` | FAIL NoF5PauseOutsideCapture | FAIL NoF5PauseOutsideCapture | 66 | 57 | 4 |
| `F5PauseResumePosition` | FAIL ResumeFromPausedPosition | FAIL ResumeFromPausedPosition | 5440 | 2385 | 7 |
| `F5PauseStaleResumesPaused` | FAIL NoDoubleResume | FAIL NoDoubleResume | 1942 | 1050 | 6 |
| `F5PauseStartDuringCapture` | FAIL NoSpeechDuringOpenMic | FAIL NoSpeechDuringOpenMic | 64 | 53 | 4 |
| `F5PauseStopResumes` | FAIL StopWins | FAIL StopWins | 355 | 248 | 5 |
| `F5PauseStuck` | FAIL AutoPauseNeverStuck | FAIL AutoPauseNeverStuck | 1637135 | 178577 | 22 (TLC completed Progress) |
| `F5PauseTimingBlank` | FAIL TimingNeverBlankWhilePlaying | FAIL TimingNeverBlankWhilePlaying | 8 | 7 | 3 |
| `F5PauseWordBoundary` | FAIL PauseAtWordBoundary | FAIL PauseAtWordBoundary | 243 | 178 | 5 |
| `History` | PASS | PASS | 1369 | 297 | 5 |
| `MutableTerminal` | FAIL FirstAcceptedTerminalImmutable | FAIL FirstAcceptedTerminalImmutable | 60 | 32 | 3 |
| `QueueAdmissionClear` | FAIL NoSilentClear | FAIL NoSilentClear | 152 | 152 | 3 |
| `QueueAdmissionDuplicate` | FAIL NoDuplicateIdentity | FAIL NoDuplicateIdentity | 264 | 264 | 3 |
| `QueueAdmissionF5Clears` | FAIL F5KeepsQueue | FAIL F5KeepsQueue | 860 | 860 | 4 |
| `QueueAdmissionFixed` | PASS | PASS | 1430 | 1430 | 4 |
| `QueueAdmissionFreshClears` | FAIL NoSilentClear | FAIL NoSilentClear | 154 | 154 | 3 |
| `QueueAdmissionInferredPlaying` | FAIL NoBlindAdvance | FAIL NoBlindAdvance | 173 | 173 | 3 |
| `QueueAdmissionStopLeaves` | FAIL StopClearsAll | FAIL StopClearsAll | 829 | 829 | 4 |
| `StaleClear` | FAIL StaleCannotAdvance | FAIL StaleCannotAdvance | 29 | 29 | 3 |
| `StaleNext` | FAIL StaleCannotAdvance | FAIL StaleCannotAdvance | 7 | 7 | 2 |
| `StopLeaves` | FAIL StopClearsQueues | FAIL StopClearsQueues | 468 | 90 | 4 |

| Property | Mutant config | Knob or guard removed | Expected | Actual | Generated / distinct / depth |
|---|---|---|---|---|---|
| `TypeOK` | `F5PauseInvalidOwner.cfg` | Fault=InvalidOwner: corrupt pause-owner domain | FAIL TypeOK | FAIL TypeOK | 12 / 10 / 3 |
| `NoSpeechDuringOpenMic` | `F5PauseOpenFirst.cfg` | PauseBeforeOpen=FALSE: open before pause | FAIL NoSpeechDuringOpenMic | FAIL NoSpeechDuringOpenMic | 46 / 40 / 4 |
| `F5PausesPlayingSpeech` | `F5PauseIgnoreF5.cfg` | Fault=IgnoreF5: bypass playing-speech F5 admission | FAIL F5PausesPlayingSpeech | FAIL F5PausesPlayingSpeech | 46 / 40 / 4 |
| `ManualPausePersists` | `F5PauseManualResume.cfg` | Fault=ManualResume: admit user owner to auto-resume | FAIL ManualPausePersists | FAIL ManualPausePersists | 301 / 212 / 5 |
| `NoF5PauseOutsideCapture` | `F5PauseResumeOnPaste.cfg` | ResumeOnEveryEnd=FALSE: resume only pasted outcome | FAIL NoF5PauseOutsideCapture | FAIL NoF5PauseOutsideCapture | 66 / 57 / 4 |
| `ResumeFromPausedPosition` | `F5PauseResumePosition.cfg` | Fault=ResumePosition: restart at zero | FAIL ResumeFromPausedPosition | FAIL ResumeFromPausedPosition | 5440 / 2385 / 7 |
| `NoDoubleResume` | `F5PauseDoubleResume.cfg` | Fault=DoubleResume: stale settlement actually resumes/repositions the read | FAIL NoDoubleResume | FAIL NoDoubleResume | 1511 / 841 / 6 |
| `StopWins` | `F5PauseStopResumes.cfg` | Fault=StopResumes: admit stopped capture to auto-resume | FAIL StopWins | FAIL StopWins | 355 / 248 / 5 |
| `OwnerConsistent` | `F5PauseKeepOwner.cfg` | Fault=KeepOwner: UserPlay retains user owner (isolating) | FAIL OwnerConsistent | FAIL OwnerConsistent | 51 / 44 / 4 |
| `ReleaseNeverDropsRead` | `F5PauseReleaseDrops.cfg` | Fault=ReleaseDrops: release calls speech stop | FAIL ReleaseNeverDropsRead | FAIL ReleaseNeverDropsRead | 64 / 55 / 4 |
| `PauseAtWordBoundary` | `F5PauseWordBoundary.cfg` | Fault=WordBoundary: omit snap to word start | FAIL PauseAtWordBoundary | FAIL PauseAtWordBoundary | 243 / 178 / 5 |
| `QueuedCountExcludesCurrent` | `F5PauseQueueCount.cfg` | Fault=QueueCount: count preparing current as waiting | FAIL QueuedCountExcludesCurrent | FAIL QueuedCountExcludesCurrent | 2 / 2 / 2 |
| `TimingNeverBlankWhilePlaying` | `F5PauseTimingBlank.cfg` | Fault=TimingBlank: omit initial timing estimate | FAIL TimingNeverBlankWhilePlaying | FAIL TimingNeverBlankWhilePlaying | 8 / 7 / 3 |
| `AutoPauseNeverStuck` | `F5PauseStuck.cfg` | Fault=NoFairness: drop only clock fairness; all safety guards intact | FAIL AutoPauseNeverStuck | FAIL AutoPauseNeverStuck | 1637135 / 178577 / 22 (TLC completed Progress) |
| `ReleaseNeverDropsRead` | `F5PausePostRelease.cfg` | Fault=PostRelease: settled capture key-up calls speech Stop | FAIL ReleaseNeverDropsRead | FAIL ReleaseNeverDropsRead | 386 / 268 / 5 |
| `NoDoubleResume` | `F5PauseStaleResumesPaused.cfg` | Fault=StaleResumesPaused: reviewer real-resume probe | FAIL NoDoubleResume | FAIL NoDoubleResume | 1942 / 1050 / 6 |
| `PauseAtWordBoundary` | `F5PauseParkZero.cfg` | Fault=ParkZero: park and later resume word zero | FAIL PauseAtWordBoundary | FAIL PauseAtWordBoundary | 1230 / 729 / 6 |
| `PauseAtWordBoundary` | `F5PauseParkNextWord.cfg` | Fault=ParkNextWord: skip to the next word | FAIL PauseAtWordBoundary | FAIL PauseAtWordBoundary | 12 / 10 / 3 |
| `NoSpeechDuringOpenMic` | `F5PauseStartDuringCapture.cfg` | Fault=StartDuringCapture: remove StartPlayback capture guard | FAIL NoSpeechDuringOpenMic | FAIL NoSpeechDuringOpenMic | 64 / 53 / 4 |
| `F5HoldsPreparingRead` | `F5PauseIgnorePreparing.cfg` | Fault=IgnorePreparing: keep current preparing-read router | FAIL F5HoldsPreparingRead | FAIL F5HoldsPreparingRead | 12 / 10 / 3 |
| `F5DuringTranscriptionStartsCapture` | `F5PauseCancelPrevious.cfg` | Fault=CancelPrevious: cancel A instead of opening capture B | FAIL F5DuringTranscriptionStartsCapture | FAIL F5DuringTranscriptionStartsCapture | 89 / 80 / 4 |
| `NoSpeechDuringOpenMic` | `F5PauseResumeEarly.cfg` | Fault=ResumeEarly: resume before every capture settles | FAIL NoSpeechDuringOpenMic | FAIL NoSpeechDuringOpenMic | 1819 / 982 / 6 |
| `F5DuringTranscriptionStartsCapture` | `F5PauseN6DropsRead.cfg` | Fault=N6DropsRead: open B but silently drop the parked read | FAIL F5DuringTranscriptionStartsCapture | FAIL F5DuringTranscriptionStartsCapture | 361 / 254 / 5 |
| `ResumeFromPausedPosition` | `F5PauseDropAtEnd.cfg` | Fault=DropAtEnd: final capture settlement drops the read | FAIL ResumeFromPausedPosition | FAIL ResumeFromPausedPosition | 66 / 57 / 4 |

Cross-kill matrix: X = named TLC violation, . = survived in that complete run.

| Mutant | P1 | P2 | P3 | P4 | P5 | P6 | P7 | P8 | P9 | P10 | P11 | P12 | P13 | P14 | P15 | P16 | Generated / distinct |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| F5PauseInvalidOwner | X | . | X | . | . | . | . | . | . | . | . | . | . | X | . | . | 1584202 / 177455 |
| F5PauseOpenFirst | . | X | X | . | . | . | . | . | . | . | . | . | . | X | . | . | 1639187 / 180629 |
| F5PauseIgnoreF5 | . | . | X | . | . | . | . | . | . | . | . | . | . | X | . | . | 1831259 / 214496 |
| F5PauseManualResume | . | . | . | X | . | . | . | . | . | . | . | . | . | . | . | . | 1917864 / 214001 |
| F5PauseResumeOnPaste | . | . | . | . | X | X | . | . | . | . | . | . | . | . | . | X | 1658781 / 182009 |
| F5PauseResumePosition | . | . | . | . | . | X | . | . | . | . | . | . | . | . | . | . | 1975287 / 218273 |
| F5PauseDoubleResume | . | . | . | X | . | . | X | . | . | . | . | . | . | . | . | . | 1917864 / 214001 |
| F5PauseStopResumes | . | . | . | X | . | . | . | X | . | . | . | . | . | . | . | . | 2100385 / 235236 |
| F5PauseKeepOwner | . | . | . | . | . | . | . | . | X | . | . | . | . | . | . | . | 1857894 / 207683 |
| F5PauseReleaseDrops | . | . | . | X | . | . | . | . | . | X | . | . | . | . | . | . | 1873059 / 207607 |
| F5PauseWordBoundary | . | . | . | . | . | . | . | . | . | . | X | . | . | . | . | . | 1791823 / 194741 |
| F5PauseQueueCount | . | . | . | . | . | . | . | . | . | . | . | X | . | . | . | . | 2324379 / 250760 |
| F5PauseTimingBlank | . | . | . | . | . | . | . | . | . | . | . | . | X | . | . | . | 1601227 / 174524 |
| F5PauseStuck | . | . | . | . | . | . | . | . | . | . | . | . | . | . | . | X | 1637135 / 178577 |
| F5PausePostRelease | . | . | . | . | . | . | . | . | . | X | . | . | . | . | . | . | 1629599 / 178577 |
| F5PauseStaleResumesPaused | . | . | . | X | . | . | X | . | . | . | . | . | . | . | . | . | 1917552 / 214001 |
| F5PauseParkZero | . | . | . | . | . | X | . | . | . | . | X | . | . | . | . | . | 2220437 / 252989 |
| F5PauseParkNextWord | . | . | . | . | . | X | . | . | . | . | X | . | . | . | . | . | 2211959 / 247991 |
| F5PauseStartDuringCapture | . | X | . | . | . | . | . | . | . | . | . | . | . | . | X | . | 2082821 / 218651 |
| F5PauseIgnorePreparing | . | . | . | . | . | . | . | . | . | . | . | . | . | X | . | . | 1675111 / 187458 |
| F5PauseCancelPrevious | . | . | . | . | . | . | . | . | . | . | . | . | . | . | X | . | 850282 / 111808 |
| F5PauseResumeEarly | . | X | . | . | . | . | X | . | . | . | . | . | . | . | . | . | 2416274 / 253964 |
| F5PauseN6DropsRead | . | . | . | X | . | . | . | . | . | . | . | . | . | . | X | . | 1539007 / 177890 |
| F5PauseDropAtEnd | . | . | . | . | . | X | . | . | . | . | . | . | . | . | . | . | 1629335 / 178577 |

- P1: `TypeOK`
- P2: `NoSpeechDuringOpenMic`
- P3: `F5PausesPlayingSpeech`
- P4: `ManualPausePersists`
- P5: `NoF5PauseOutsideCapture`
- P6: `ResumeFromPausedPosition`
- P7: `NoDoubleResume`
- P8: `StopWins`
- P9: `OwnerConsistent`
- P10: `ReleaseNeverDropsRead`
- P11: `PauseAtWordBoundary`
- P12: `QueuedCountExcludesCurrent`
- P13: `TimingNeverBlankWhilePlaying`
- P14: `F5HoldsPreparingRead`
- P15: `F5DuringTranscriptionStartsCapture`
- P16: `AutoPauseNeverStuck`

TLC log excerpts (emitted by the checker, never transcribed):

```text
AdmissionCurrent:
Model checking completed. No error has been found.
257 states generated, 257 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 3.
AdmissionFinding:
Error: Invariant NonemptySelectionDoesNotStop is violated.
69 states generated, 69 distinct states found, 65 states left on queue.
The depth of the complete state graph search is 3.
AdmissionOlderMatch:
Error: Invariant EveryQueuedMatchStops is violated.
147 states generated, 147 distinct states found, 117 states left on queue.
The depth of the complete state graph search is 3.
AdmissionProposed:
Model checking completed. No error has been found.
257 states generated, 257 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 3.
Current:
Model checking completed. No error has been found.
148729 states generated, 11163 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 9.
F5PauseCancelPrevious:
Error: Invariant F5DuringTranscriptionStartsCapture is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
89 states generated, 80 distinct states found, 65 states left on queue.
The depth of the complete state graph search is 4.
F5PauseCurrent:
Error: Invariant F5PausesPlayingSpeech is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
37 states generated, 36 distinct states found, 28 states left on queue.
The depth of the complete state graph search is 4.
F5PauseCurrentCancelPostRelease:
Error: Invariant ReleaseNeverDropsRead is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
77 states generated, 50 distinct states found, 43 states left on queue.
The depth of the complete state graph search is 3.
F5PauseCurrentPostRelease:
Error: Invariant ReleaseNeverDropsRead is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
386 states generated, 268 distinct states found, 210 states left on queue.
The depth of the complete state graph search is 5.
F5PauseCurrentPreparing:
Error: Invariant F5HoldsPreparingRead is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
10 states generated, 10 distinct states found, 7 states left on queue.
The depth of the complete state graph search is 3.
F5PauseCurrentQueued:
Error: Invariant QueuedCountExcludesCurrent is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
2 states generated, 2 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 2.
F5PauseCurrentRelease:
Error: Invariant ReleaseNeverDropsRead is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
54 states generated, 52 distinct states found, 41 states left on queue.
The depth of the complete state graph search is 4.
F5PauseCurrentTiming:
Error: Invariant TimingNeverBlankWhilePlaying is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
7 states generated, 7 distinct states found, 4 states left on queue.
The depth of the complete state graph search is 3.
F5PauseCurrentTranscribing:
Error: Invariant F5DuringTranscriptionStartsCapture is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
62 states generated, 59 distinct states found, 45 states left on queue.
The depth of the complete state graph search is 4.
F5PauseCurrentWordBoundary:
Error: Invariant PauseAtWordBoundary is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
180 states generated, 133 distinct states found, 98 states left on queue.
The depth of the complete state graph search is 5.
F5PauseDoubleResume:
Error: Invariant NoDoubleResume is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
1511 states generated, 841 distinct states found, 628 states left on queue.
The depth of the complete state graph search is 6.
F5PauseDropAtEnd:
Error: Invariant ResumeFromPausedPosition is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
66 states generated, 57 distinct states found, 46 states left on queue.
The depth of the complete state graph search is 4.
F5PauseFixed:
Progress(9) at 2026-11-02 13:14:26: 68,983 states generated (68,983 s/min), 18,005 distinct states found (18,005 ds/min), 9,751 states left on queue.
Progress(22) at 2026-11-02 13:15:05: 1,637,135 states generated, 178,577 distinct states found, 0 states left on queue.
Model checking completed. No error has been found.
1637135 states generated, 178577 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 22.
F5PauseFixedTranscribing:
Progress(14) at 2026-11-02 13:15:11: 298,626 states generated (298,626 s/min), 44,139 distinct states found (44,139 ds/min), 5,210 states left on queue.
Progress(20) at 2026-11-02 13:15:12: 415,239 states generated, 55,317 distinct states found, 0 states left on queue.
Model checking completed. No error has been found.
415239 states generated, 55317 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 20.
F5PauseIgnoreF5:
Error: Invariant F5PausesPlayingSpeech is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
46 states generated, 40 distinct states found, 32 states left on queue.
The depth of the complete state graph search is 4.
F5PauseIgnorePreparing:
Error: Invariant F5HoldsPreparingRead is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
12 states generated, 10 distinct states found, 7 states left on queue.
The depth of the complete state graph search is 3.
F5PauseInvalidOwner:
Error: Invariant TypeOK is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
12 states generated, 10 distinct states found, 7 states left on queue.
The depth of the complete state graph search is 3.
F5PauseKeepOwner:
Error: Invariant OwnerConsistent is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
51 states generated, 44 distinct states found, 35 states left on queue.
The depth of the complete state graph search is 4.
F5PauseManualResume:
Error: Invariant ManualPausePersists is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
301 states generated, 212 distinct states found, 166 states left on queue.
The depth of the complete state graph search is 5.
F5PauseN6DropsRead:
Error: Invariant F5DuringTranscriptionStartsCapture is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
361 states generated, 254 distinct states found, 198 states left on queue.
The depth of the complete state graph search is 5.
F5PauseOpenFirst:
Error: Invariant NoSpeechDuringOpenMic is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
46 states generated, 40 distinct states found, 32 states left on queue.
The depth of the complete state graph search is 4.
F5PauseParkNextWord:
Error: Invariant PauseAtWordBoundary is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
12 states generated, 10 distinct states found, 7 states left on queue.
The depth of the complete state graph search is 3.
F5PauseParkZero:
Error: Invariant PauseAtWordBoundary is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
1230 states generated, 729 distinct states found, 553 states left on queue.
The depth of the complete state graph search is 6.
F5PausePostRelease:
Error: Invariant ReleaseNeverDropsRead is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
386 states generated, 268 distinct states found, 210 states left on queue.
The depth of the complete state graph search is 5.
F5PauseQueueCount:
Error: Invariant QueuedCountExcludesCurrent is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
2 states generated, 2 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 2.
F5PauseReleaseDrops:
Error: Invariant ReleaseNeverDropsRead is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
64 states generated, 55 distinct states found, 44 states left on queue.
The depth of the complete state graph search is 4.
F5PauseResumeEarly:
Error: Invariant NoSpeechDuringOpenMic is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
1819 states generated, 982 distinct states found, 727 states left on queue.
The depth of the complete state graph search is 6.
F5PauseResumeOnPaste:
Error: Invariant NoF5PauseOutsideCapture is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
66 states generated, 57 distinct states found, 46 states left on queue.
The depth of the complete state graph search is 4.
F5PauseResumePosition:
Error: Invariant ResumeFromPausedPosition is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
5440 states generated, 2385 distinct states found, 1657 states left on queue.
The depth of the complete state graph search is 7.
F5PauseStaleResumesPaused:
Error: Invariant NoDoubleResume is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
1942 states generated, 1050 distinct states found, 783 states left on queue.
The depth of the complete state graph search is 6.
F5PauseStartDuringCapture:
Error: Invariant NoSpeechDuringOpenMic is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
64 states generated, 53 distinct states found, 42 states left on queue.
The depth of the complete state graph search is 4.
F5PauseStopResumes:
Error: Invariant StopWins is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
355 states generated, 248 distinct states found, 193 states left on queue.
The depth of the complete state graph search is 5.
F5PauseStuck:
Progress(12) at 2026-11-02 13:15:29: 368,941 states generated (368,941 s/min), 64,263 distinct states found (64,263 ds/min), 21,616 states left on queue.
Progress(22) at 2026-11-02 13:15:38: 1,637,135 states generated, 178,577 distinct states found, 0 states left on queue.
Error: Temporal properties were violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
State 11: Stuttering
1637135 states generated, 178577 distinct states found, 0 states left on queue.
F5PauseTimingBlank:
Error: Invariant TimingNeverBlankWhilePlaying is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
8 states generated, 7 distinct states found, 4 states left on queue.
The depth of the complete state graph search is 3.
F5PauseWordBoundary:
Error: Invariant PauseAtWordBoundary is violated.
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
243 states generated, 178 distinct states found, 140 states left on queue.
The depth of the complete state graph search is 5.
History:
Model checking completed. No error has been found.
1369 states generated, 297 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 5.
MutableTerminal:
Error: Invariant FirstAcceptedTerminalImmutable is violated.
60 states generated, 32 distinct states found, 24 states left on queue.
The depth of the complete state graph search is 3.
QueueAdmissionClear:
Error: Invariant NoSilentClear is violated.
152 states generated, 152 distinct states found, 143 states left on queue.
The depth of the complete state graph search is 3.
QueueAdmissionDuplicate:
Error: Invariant NoDuplicateIdentity is violated.
264 states generated, 264 distinct states found, 239 states left on queue.
The depth of the complete state graph search is 3.
QueueAdmissionF5Clears:
Error: Invariant F5KeepsQueue is violated.
860 states generated, 860 distinct states found, 702 states left on queue.
The depth of the complete state graph search is 4.
QueueAdmissionFixed:
Model checking completed. No error has been found.
1430 states generated, 1430 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 4.
QueueAdmissionFreshClears:
Error: Invariant NoSilentClear is violated.
154 states generated, 154 distinct states found, 145 states left on queue.
The depth of the complete state graph search is 3.
QueueAdmissionInferredPlaying:
Error: Invariant NoBlindAdvance is violated.
173 states generated, 173 distinct states found, 161 states left on queue.
The depth of the complete state graph search is 3.
QueueAdmissionStopLeaves:
Error: Invariant StopClearsAll is violated.
829 states generated, 829 distinct states found, 707 states left on queue.
The depth of the complete state graph search is 4.
StaleClear:
Error: Invariant StaleCannotAdvance is violated.
29 states generated, 29 distinct states found, 26 states left on queue.
The depth of the complete state graph search is 3.
StaleNext:
Error: Invariant StaleCannotAdvance is violated.
7 states generated, 7 distinct states found, 5 states left on queue.
The depth of the complete state graph search is 2.
StopLeaves:
Error: Invariant StopClearsQueues is violated.
468 states generated, 90 distinct states found, 66 states left on queue.
The depth of the complete state graph search is 4.
```
<!-- TLC-RESULTS-END -->

## R2 conformance receipt (prior M4 jar)

The same-source gate passed 52 expected-result checks (7 PASS, 45 named expected
FAIL), and the 24-by-16 cross-kill matrix completed. Fixed's full graph and the
transcribing-boundary scenario passed safety plus the stronger temporal property.
G1 separates the matrix's M1-sized 2400-second budget from the original gate's 880 seconds;
every per-TLC 90-second limit and every correctness check remain unchanged.
The reviewer StaleResumesPaused case fails both the behavioural stale-settlement
property and persistent manual ownership. KeepOwner is an isolated owner-consistency
kill, and NoFairness is an isolated liveness kill across every Fixed property.

The old admission replays remain narrow runtime checks, not F5 conformance or
installed acceptance. Queue/History Bun: 2 tests passed; Swift admission: 2 passed;
daemon admission: 65 passed. All zero failures. Negative verdict controls on the
35 actual F5 logs reject survivors, wrong names, anonymous temporal failures,
a missing f5 antecedent and a discharged lasso. The current cancel-then-up-edge
trace was checked for both events and the actual named release violation.

Extracted from the accepted captain-lock gate log (never transcribed):

```text
[heavy.sh] F-model start 2026-11-02T09:47:00Z load { 12.01 13.01 12.93 }
Replayed 148728 TLC reachable transitions against SelectionReadQueue
Replayed 1368 TLC History transitions against transitionSpeech
 2 pass
 0 fail
Test Case '-[VoiceBarUITests.ReadQueueTests testModelAdmissionCasesDriveRealVoiceState]' passed (1.108 seconds).
Replayed 4172 TLC cases through real VoiceState capture completion and commands
Test Case '-[VoiceBarTests.SocketServerTests testQueueAdmissionSocketBoundary]' passed (0.290 seconds).
Replayed 1043 TLC admission cases through daemon handlers
 65 pass
 0 fail
PASS: queue/History runtime and real Swift/daemon admission conformance; 45 expected counterexamples
[heavy.sh] F-model end rc=0 2026-11-02T10:01:03Z
```
