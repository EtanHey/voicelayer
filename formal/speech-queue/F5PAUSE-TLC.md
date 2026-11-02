# Lane F: F5 pause, queue count and first-frame timing (model receipt)

Status: **model/checker only**. No product changes, installation, audio, microphone,
or installed-app acceptance. The existing Swift/daemon admission replays remain in
the default gate; they concern queue admission, not F5 pause conformance.

Base: `integration/2.2.61` at `6d89690728ae1116dcb8d184847814a32b61fce0`.
Phase 1 cherry-picked from `b76c6df1`; this extension follows LANE-F-MODEL-BRIEF.md.
QA source read in full: `qa-etan-0454/docs/qa-session-2026-11-02-0454/recording-2/qa-findings-recording-2.md`
(R2-01, R2-03, R2-05). The recording supports the visual read drop and blank timing;
its F5 release timing is narration-supported, not a visible key event.

## Contract and bounds

`F5Pause.tla` owns one current read, one waiting request, one capture and one
pause owner (`none | user | f5`). The read can be preparing, playing or paused;
this is the honest home for the published count because preparation, dequeue and
F5 parking all change which request owns that current slot. No second independent
queue is invented. Bounds: two requests, two words, two audio ticks per word.
`pausedAt` is a word index; `pos` is an audio tick offset. A fixed pause parks at
the **start of the containing word**, and resume uses `2 * pausedAt`. This retains
all words and avoids chopping a real tail off the transcript or skipping a word.
The final index is an end-of-read boundary sentinel. This model chooses the cursor
rule; it does not prove the precision of an audio alignment engine.

| Flow | Model/check |
|---|---|
| F5 tap, hold, double over playing read | `F5(g)` atomically quiesces/parks before recording; `F5PausesPlayingSpeech`, `NoSpeechDuringOpenMic` |
| Hold release or second tap | `HoldRelease` / `CaptureStop` ends only capture, not speech; `ReleaseNeverDropsRead` |
| Double tap locks capture | Locked physical release leaves recording active; a later `CaptureStop` ends it |
| User pause before or during capture | `UserPause` sets/converts owner to user; all capture outcomes preserve it (`ManualPausePersists`) |
| Paste, empty, failure, cancel, timeout | Single `EndCapture` settles all five; F5-owned pause resumes once, user-owned pause stays |
| Speech stop during capture | `UserStop` ends the read and clears waiting request; `StopWins` also checks erroneous auto-resume events |
| New request during capture | Queues behind current paused read; `Dequeue` waits for a free slot and idle capture |
| F5 during transcription / stale end | Busy/no-op, no extra resume (`NoDoubleResume`) |
| Word cursor | `PauseAtWordBoundary` checks parked cursor, `ResumeFromPausedPosition` checks actual post-resume cursor |
| R2-03 queue label | Published `shownQueued` equals true waiting `queued`; preparing current is excluded |
| R2-05 first playback frame | `StartPlayback` preserves real timings or supplies estimate atomically; timing arrival is never assumed |

`Fixed=FALSE` includes the ignored hold followed by a **separate physical release**
that calls speech Stop, arbitrary-millisecond pause offsets, the preparing current
misclassified as queued, and absent timing at playback start. Separate Current
configs expose each defect without an earlier invariant masking it. They are
projections of source behavior and the QA recording, not executable product replays.
The current router is also in `.speaking` during preparation, so its ignored hold
and destructive release apply there too. A capture-scoped release over a parked
read ends only the capture and leaves the read parked, unlike the speech-scoped
stop after an ignored hold. Its shortest release counterexample
may therefore occur during preparation, before the recorded playing-read case.

`ResumeFromPausedPosition` previously checked only a parked state. It now inspects
the resumed cursor. `ManualPausePersists` and `StopWins` now include `_auto_resume`
events, so a broken implementation cannot evade them by choosing that event name.
All 13 invariants and the one temporal property have an isolated one-knob mutant;
the checker verifies coverage and that exactly one constant changes from Fixed.

## Checker and named temporal failures

TLC command prefix is `nice -n 19 java -Xmx512m -XX:+UseParallelGC -cp ~/.cache/tla/tla2tools.jar tlc2.TLC`;
all runs use one worker, fingerprint 0, seed 1 and isolated `.build.noindex` metadata.
The jar must already exist. No replacement jar is downloaded or installed.

The installed TLC 2.19 prints **an anonymous temporal-error headline** and does not
support CFG `ALIAS`. A deterministic diagnostic record in each actual state names
the discharge predicate: `obligations = [AutoPauseNeverStuck |-> owner # "f5"]`.
This record changes no possible product behavior. The temporal mutant counts only
when all of the following hold: exit 13, no safety invariant violation, exactly
`PROPERTIES AutoPauseNeverStuck` in its config, a TLC temporal counterexample, and
a parsed lasso whose every cycle state has both `AutoPauseNeverStuck |-> FALSE`
and `owner = "f5"`. A generic nonzero exit or anonymous temporal headline alone
fails the gate. Safety mutants require exit 12 and the exact invariant name from
TLC's own error line. PASS requires exit 0 and TLC's completion message.

Every CFG is registered explicitly. The default gate runs every CFG and keeps the
existing queue/History Bun replay plus real Swift VoiceState/socket and daemon
admission replays. `--f5-only` runs just F5 checks and explicitly makes no replay
claim. `--receipt` regenerates the tables and log excerpts below from that run;
source/config SHA-256 hashes, the jar digest and raw logs stay in its evidence dir.

On this M4, **every TLC and Swift run goes through the captain lock**, per the
07:48Z lead update; the former load-12 gate is dropped. Run from the worker root:

```bash
set -euo pipefail
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:$PATH"
~/.local/state/captain-2.2.61/heavy.sh F-model /opt/homebrew/bin/gtimeout -s TERM -k 10 900 bash formal/speech-queue/check.sh --receipt
```

Focused model iteration uses the same lock and `--f5-only` (120-second cap).
The checker leaves test preload enabled; replays use fixture sockets and mocked
speech, not the resident sockets, audio player or real microphone. The macOS
admission helper uses `/opt/homebrew/bin/gtimeout`, not an assumed `timeout`.

## Code points phase 2 must touch

The following eight items are the phase-1 checklist; numeric anchors are historical
(d500e4ee) and implementers must locate the named methods at their own head.


1. **Daemon record handler** `src/socket-handlers.ts:483-486`: replace `stopAll(undefined, "suspend")` with a pause
   owned by F5, before `waitForInput`. The record command runs inside a capture admission
   (`socket-handlers.ts:226`, `kind: "capture"`). `pausePlayback` refuses to park a read that has no first chunk yet
   while a capture is reserved (`src/tts.ts:2182`, reason `unsupported`). The pause must therefore land before the
   reservation, or get an F5-owner bypass. Either way, the order must stay pause → open (`F5PauseOpenFirst` shows the
   failure).
2. **Capture settlement**: resume an F5-owned pause exactly once when `waitForInput` settles, whatever the outcome
   (the promise at `socket-handlers.ts:490-500`). Use the single settle point rather than
   distributed recording-idle broadcasts (`NoDoubleResume`).
3. **Playback pause/resume API** `src/tts.ts:2174-2200`: add an owner (`user | f5`) to the paused state, plus an
   internal resume that is allowed only after the capture is idle (Play stays `busy` during the capture).
4. **Selection queue** `src/selection-read-queue.ts:122-126`: do not `suspend` on an F5 pause. Queue a new speech
   behind the paused read (contract row 4).
5. **VoiceBar F5 path** `flow-bar/Sources/VoiceBar/VoiceBarCommandRouter.swift:135-173`: in `.speaking`, hold start
   records (as it does over a paused read) instead of returning. The first tap records instead of stopping;
   double tap retains its existing lock behavior after that first tap. Also `VoiceBarApp.swift:1549-1555` and `:2196-2204`, the `retainingReadQueueOnStop` wrappers.
6. **Pause-owner state in Swift** `flow-bar/Sources/VoiceBarUI/VoiceState.swift`: `ParkedRead` (`:547`) needs the owner.
   `isPlaybackPaused` (`:570`), the `record()` guard (`:2420`) and the recording-idle restore (`:2525-2535` →
   `scheduleParkedReadRestore`, `:2132`) must resume only an F5 owner and restore his own pause as paused.
7. **Pause button during a capture** `flow-bar/Sources/VoiceBarUI/BarView.swift:506` (`case .recording`): row 6 needs a
   pause control while recording that converts the owner. This is UI: per Etan's 2026-11-02 standing rule, load
   `frontend-design:frontend-design` and `emil-design-eng` first.
8. **Speech-scoped stop during a capture** (row 4): `src/socket-handlers.ts:323-347` today treats every in-capture stop
   as capture-scoped (P16).

Who should own the pause: the daemon. It is the only process that sees both the capture and the player. It should
publish the owner in its `paused` frame, and VoiceBar should render it, never infer it.


### Additional code points exposed by this extension

9. **Physical release routing**: `VoiceBarCommandRouter.handleHotkeyHoldEnd` calls
   `handleStop` after an ignored hold. Route it to the capture stop/settlement when
   F5 owns the pause. Preserve double-tap lock semantics. Cover both the ignored
   down-edge and the separate destructive up-edge, not only `handleHotkeyHoldStart`.
10. **Word-boundary pause and actual resume cursor**: `PlaybackQueueManager.pause`
    computes a rounded elapsed millisecond and `park` stores that arbitrary offset
    in `metadata.localOffsetMs` / `parked.offsetMs` (`src/tts.ts`). Map through the
    current real/estimated word timeline before parking; retain the word index and
    seek the same word on resume. A zero restart must fail even when parking was correct.
11. **Preparing current in queue snapshot (R2-03)**:
    `PlaybackQueueManager.emitQueueSnapshot` labels `this.preparing.job` with
    `is_current: false`. Swift `VoiceState.queuedSpeakCount` counts every noncurrent
    item. Mark the actual current owner consistently through preparation/playback;
    keep true pending requests counted. `SelectionReadQueue.pendingCount` already
    excludes its current owner; changing that separate queue alone misses the flash.
12. **First speaking frame timing (R2-05)**: playback starts before
    `startCloneTiming` publishes alignment (`src/tts.ts`, `src/tts/clone-timing.ts`).
    Supply a real or estimated timeline at the first speaking event and replace the
    estimate when alignment arrives. Hiding the notice alone does not satisfy
    `TimingNeverBlankWhilePlaying`; the pause/resume cursor also needs usable timing.
    `TeleprompterPlaybackScrubBar.timingNotice` and `VoiceState.wordBoundaries` consume
    this data. Any visual change belongs to Claude under the lane's two UI skills.

These are implementation handoff points only. This branch changes models and their
checker; no view or recording code is modified. The 8.5-second preparation stall is
observed by R2-03 but this spec sets no latency budget and makes no latency claim.

## Conformance receipt from the same locked gate

The existing queue/History and Swift/daemon admission replays passed. These are
admission checks of the existing runtime, not F5 conformance or installed-app proof.
The checker verdict was also probed against these actual logs: it rejects a surviving
mutant, a wrong invariant name, and anonymous/mismatched temporal failures. The initial
scratch Swift compilation emitted 27 warning diagnostics in untouched files; the
final cached build and focused tests completed successfully.

Output below is extracted from the actual gate log:

```text
[heavy.sh] F-model start 2026-11-02T08:10:48Z load { 10.51 13.04 13.58 }
Replayed 148728 TLC reachable transitions against SelectionReadQueue
Replayed 1368 TLC History transitions against transitionSpeech
 2 pass
 0 fail
Test Case '-[VoiceBarUITests.ReadQueueTests testModelAdmissionCasesDriveRealVoiceState]' passed (1.144 seconds).
Replayed 4172 TLC cases through real VoiceState capture completion and commands
Test Case '-[VoiceBarTests.SocketServerTests testQueueAdmissionSocketBoundary]' passed (0.285 seconds).
Replayed 1043 TLC admission cases through daemon handlers
 65 pass
 0 fail
PASS: queue/History runtime and real Swift/daemon admission conformance; 31 expected counterexamples
[heavy.sh] F-model end rc=0 2026-11-02T08:11:34Z
```

## Measured TLC results

Generated by `check.sh --receipt`. Depth is TLC's reported BFS depth. For the
temporal failure TLC omits the final depth sentence, so the checker uses the
depth in TLC's completed `Progress(N)` line (zero states remaining), labelled
as such. No depth is inferred from the counterexample length.

<!-- TLC-RESULTS-START -->
| Config | Expected | Actual | Generated | Distinct | Depth |
|---|---|---|---:|---:|---:|
| `AdmissionCurrent` | PASS | PASS | 257 | 257 | 3 |
| `AdmissionFinding` | FAIL NonemptySelectionDoesNotStop | FAIL NonemptySelectionDoesNotStop | 69 | 69 | 3 |
| `AdmissionOlderMatch` | FAIL EveryQueuedMatchStops | FAIL EveryQueuedMatchStops | 147 | 147 | 3 |
| `AdmissionProposed` | PASS | PASS | 257 | 257 | 3 |
| `Current` | PASS | PASS | 148729 | 11163 | 9 |
| `F5PauseCurrent` | FAIL F5PausesPlayingSpeech | FAIL F5PausesPlayingSpeech | 38 | 29 | 4 |
| `F5PauseCurrentQueued` | FAIL QueuedCountExcludesCurrent | FAIL QueuedCountExcludesCurrent | 2 | 2 | 2 |
| `F5PauseCurrentRelease` | FAIL ReleaseNeverDropsRead | FAIL ReleaseNeverDropsRead | 55 | 46 | 4 |
| `F5PauseCurrentTiming` | FAIL TimingNeverBlankWhilePlaying | FAIL TimingNeverBlankWhilePlaying | 7 | 7 | 3 |
| `F5PauseCurrentWordBoundary` | FAIL PauseAtWordBoundary | FAIL PauseAtWordBoundary | 149 | 95 | 5 |
| `F5PauseDoubleResume` | FAIL NoDoubleResume | FAIL NoDoubleResume | 836 | 355 | 6 |
| `F5PauseFixed` | PASS | PASS | 82882 | 13631 | 21 |
| `F5PauseIgnoreF5` | FAIL F5PausesPlayingSpeech | FAIL F5PausesPlayingSpeech | 46 | 33 | 4 |
| `F5PauseKeepOwner` | FAIL OwnerConsistent | FAIL OwnerConsistent | 213 | 125 | 5 |
| `F5PauseManualResume` | FAIL ManualPausePersists | FAIL ManualPausePersists | 746 | 309 | 6 |
| `F5PauseOpenFirst` | FAIL NoSpeechDuringOpenMic | FAIL NoSpeechDuringOpenMic | 46 | 33 | 4 |
| `F5PauseQueueCount` | FAIL QueuedCountExcludesCurrent | FAIL QueuedCountExcludesCurrent | 2 | 2 | 2 |
| `F5PauseReleaseDrops` | FAIL ReleaseNeverDropsRead | FAIL ReleaseNeverDropsRead | 64 | 48 | 4 |
| `F5PauseResumeOnPaste` | FAIL NoF5PauseOutsideCapture | FAIL NoF5PauseOutsideCapture | 213 | 125 | 5 |
| `F5PauseResumePosition` | FAIL ResumeFromPausedPosition | FAIL ResumeFromPausedPosition | 1954 | 665 | 7 |
| `F5PauseStopResumes` | FAIL StopWins | FAIL StopWins | 313 | 169 | 5 |
| `F5PauseStuck` | FAIL AutoPauseNeverStuck | FAIL AutoPauseNeverStuck | 99178 | 15890 | 21 (TLC completed Progress) |
| `F5PauseTimingBlank` | FAIL TimingNeverBlankWhilePlaying | FAIL TimingNeverBlankWhilePlaying | 8 | 7 | 3 |
| `F5PauseTypeBound` | FAIL TypeOK | FAIL TypeOK | 144 | 85 | 5 |
| `F5PauseWordBoundary` | FAIL PauseAtWordBoundary | FAIL PauseAtWordBoundary | 188 | 109 | 5 |
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
| `TypeOK` | `F5PauseTypeBound.cfg` | Fault=TypeBound: relax NewSpeech admission bound by one | FAIL TypeOK | FAIL TypeOK | 144 / 85 / 5 |
| `NoSpeechDuringOpenMic` | `F5PauseOpenFirst.cfg` | PauseBeforeOpen=FALSE: open before pause | FAIL NoSpeechDuringOpenMic | FAIL NoSpeechDuringOpenMic | 46 / 33 / 4 |
| `F5PausesPlayingSpeech` | `F5PauseIgnoreF5.cfg` | Fault=IgnoreF5: bypass playing-speech F5 admission | FAIL F5PausesPlayingSpeech | FAIL F5PausesPlayingSpeech | 46 / 33 / 4 |
| `ManualPausePersists` | `F5PauseManualResume.cfg` | Fault=ManualResume: admit user owner to auto-resume | FAIL ManualPausePersists | FAIL ManualPausePersists | 746 / 309 / 6 |
| `NoF5PauseOutsideCapture` | `F5PauseResumeOnPaste.cfg` | ResumeOnEveryEnd=FALSE: resume only pasted outcome | FAIL NoF5PauseOutsideCapture | FAIL NoF5PauseOutsideCapture | 213 / 125 / 5 |
| `ResumeFromPausedPosition` | `F5PauseResumePosition.cfg` | Fault=ResumePosition: restart at zero | FAIL ResumeFromPausedPosition | FAIL ResumeFromPausedPosition | 1954 / 665 / 7 |
| `NoDoubleResume` | `F5PauseDoubleResume.cfg` | Fault=DoubleResume: remove stale-settlement idempotency | FAIL NoDoubleResume | FAIL NoDoubleResume | 836 / 355 / 6 |
| `StopWins` | `F5PauseStopResumes.cfg` | Fault=StopResumes: admit stopped capture to auto-resume | FAIL StopWins | FAIL StopWins | 313 / 169 / 5 |
| `OwnerConsistent` | `F5PauseKeepOwner.cfg` | Fault=KeepOwner: omit owner clear on auto-resume | FAIL OwnerConsistent | FAIL OwnerConsistent | 213 / 125 / 5 |
| `ReleaseNeverDropsRead` | `F5PauseReleaseDrops.cfg` | Fault=ReleaseDrops: release calls speech stop | FAIL ReleaseNeverDropsRead | FAIL ReleaseNeverDropsRead | 64 / 48 / 4 |
| `PauseAtWordBoundary` | `F5PauseWordBoundary.cfg` | Fault=WordBoundary: omit snap to word start | FAIL PauseAtWordBoundary | FAIL PauseAtWordBoundary | 188 / 109 / 5 |
| `QueuedCountExcludesCurrent` | `F5PauseQueueCount.cfg` | Fault=QueueCount: count preparing current as waiting | FAIL QueuedCountExcludesCurrent | FAIL QueuedCountExcludesCurrent | 2 / 2 / 2 |
| `TimingNeverBlankWhilePlaying` | `F5PauseTimingBlank.cfg` | Fault=TimingBlank: omit initial timing estimate | FAIL TimingNeverBlankWhilePlaying | FAIL TimingNeverBlankWhilePlaying | 8 / 7 / 3 |
| `AutoPauseNeverStuck` | `F5PauseStuck.cfg` | ResumeOnEveryEnd=FALSE: resume only pasted outcome | FAIL AutoPauseNeverStuck | FAIL AutoPauseNeverStuck | 99178 / 15890 / 21 (TLC completed Progress) |

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
F5PauseCurrent:
Error: Invariant F5PausesPlayingSpeech is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
38 states generated, 29 distinct states found, 21 states left on queue.
The depth of the complete state graph search is 4.
F5PauseCurrentQueued:
Error: Invariant QueuedCountExcludesCurrent is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
2 states generated, 2 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 2.
F5PauseCurrentRelease:
Error: Invariant ReleaseNeverDropsRead is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
55 states generated, 46 distinct states found, 35 states left on queue.
The depth of the complete state graph search is 4.
F5PauseCurrentTiming:
Error: Invariant TimingNeverBlankWhilePlaying is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
7 states generated, 7 distinct states found, 4 states left on queue.
The depth of the complete state graph search is 3.
F5PauseCurrentWordBoundary:
Error: Invariant PauseAtWordBoundary is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
149 states generated, 95 distinct states found, 67 states left on queue.
The depth of the complete state graph search is 5.
F5PauseDoubleResume:
Error: Invariant NoDoubleResume is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
836 states generated, 355 distinct states found, 229 states left on queue.
The depth of the complete state graph search is 6.
F5PauseFixed:
Progress(21) at 2026-11-02 10:10:59: 82,882 states generated, 13,631 distinct states found, 0 states left on queue.
Model checking completed. No error has been found.
82882 states generated, 13631 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 21.
F5PauseIgnoreF5:
Error: Invariant F5PausesPlayingSpeech is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
46 states generated, 33 distinct states found, 25 states left on queue.
The depth of the complete state graph search is 4.
F5PauseKeepOwner:
Error: Invariant OwnerConsistent is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
213 states generated, 125 distinct states found, 91 states left on queue.
The depth of the complete state graph search is 5.
F5PauseManualResume:
Error: Invariant ManualPausePersists is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
746 states generated, 309 distinct states found, 195 states left on queue.
The depth of the complete state graph search is 6.
F5PauseOpenFirst:
Error: Invariant NoSpeechDuringOpenMic is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
46 states generated, 33 distinct states found, 25 states left on queue.
The depth of the complete state graph search is 4.
F5PauseQueueCount:
Error: Invariant QueuedCountExcludesCurrent is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
2 states generated, 2 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 2.
F5PauseReleaseDrops:
Error: Invariant ReleaseNeverDropsRead is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
64 states generated, 48 distinct states found, 37 states left on queue.
The depth of the complete state graph search is 4.
F5PauseResumeOnPaste:
Error: Invariant NoF5PauseOutsideCapture is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
213 states generated, 125 distinct states found, 91 states left on queue.
The depth of the complete state graph search is 5.
F5PauseResumePosition:
Error: Invariant ResumeFromPausedPosition is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
1954 states generated, 665 distinct states found, 368 states left on queue.
The depth of the complete state graph search is 7.
F5PauseStopResumes:
Error: Invariant StopWins is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
313 states generated, 169 distinct states found, 120 states left on queue.
The depth of the complete state graph search is 5.
F5PauseStuck:
Progress(21) at 2026-11-02 10:11:08: 99,178 states generated, 15,890 distinct states found, 0 states left on queue.
Error: Temporal properties were violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
/\ obligations = [AutoPauseNeverStuck |-> FALSE]
Back to state 10: <Observe line 183, col 9 to line 185, col 57 of module F5Pause>
99178 states generated, 15890 distinct states found, 0 states left on queue.
F5PauseTimingBlank:
Error: Invariant TimingNeverBlankWhilePlaying is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
8 states generated, 7 distinct states found, 4 states left on queue.
The depth of the complete state graph search is 3.
F5PauseTypeBound:
Error: Invariant TypeOK is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
144 states generated, 85 distinct states found, 60 states left on queue.
The depth of the complete state graph search is 5.
F5PauseWordBoundary:
Error: Invariant PauseAtWordBoundary is violated.
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
/\ obligations = [AutoPauseNeverStuck |-> TRUE]
188 states generated, 109 distinct states found, 78 states left on queue.
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

## Limits and conformance boundary

This is finite bounded exploration, not a refinement proof. Atomic pause-before-open
abstracts player quiescence; a product implementation must wait for the real player
exit before mic admission. The one-slot model cannot prove cross-process generation
fencing or arbitrary queue lengths. Fairness requires capture progress/timeout and
pending pause settlement, never user input, speech progress or alignment arrival.
No product F5 conformance replay is added: that belongs to the implementation lane.
The preserved admission replays check their existing queue contract only. Real
installed M4 interaction proof and audio/permission checks belong to the captain.
