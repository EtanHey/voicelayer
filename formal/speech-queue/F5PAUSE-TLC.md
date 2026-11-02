# F5 pauses Option+F5 speech: TLC record (lane F5-PAUSE, phase 1)

Status: **model only**. There's no product code, no audio, no installed-app claim, and no replay against real code yet.
Phase 2 implements the fix and must add a conformance replay before anyone claims the code matches `F5PauseFixed`.

Module: [F5Pause.tla](F5Pause.tla). It models one speech slot (positions `0..SpeechLen`), one waiting speech request, one
capture (`idle → recording → transcribing → idle`) and one pause owner (`none | user | f5`). The bounds are
`SpeechLen = 2` and `MaxSpeeches = 2`. `Fixed = FALSE` projects today's router and daemon. `Fixed = TRUE` is the lead's
six-row contract. Every result below was copied from TLC's own log (the commands are at the end). None of it was typed by hand.

## Contract rows → model

| Row | Model element | Checked by |
|---|---|---|
| 1. F5 (tap / hold / double) over a playing speech pauses it before the mic opens, then resumes it from the same position | `F5(g)` Fixed branch pauses and opens the capture in one step; `EndCapture` resumes from `pausedAt` | `F5PausesPlayingSpeech`, `NoSpeechDuringOpenMic`, `ResumeFromPausedPosition` |
| 2. His own pause persists through an F5 capture | `F5(g)` `OTHER` branch leaves `owner = "user"`; `EndCapture` resumes only `owner = "f5"` | `ManualPausePersists` |
| 3. Resume only after the capture fully ends: pasted, empty, failed, cancelled or timed out; an F5 pause is never left stuck | `EndCapture(o)` for all five outcomes | `NoF5PauseOutsideCapture` (safety), `AutoPauseNeverStuck` (liveness, under weak fairness on capture progress) |
| 4. A stop or a same-text Option+F5 during the capture wins; a new speech waits behind the paused one | `UserStop` in-capture branch (clears the waiting request: Stop means stop); `NewSpeech` queues during the capture; `Dequeue` runs only when the slot is free and the capture is idle | `StopWins`, `NoSpeechDuringOpenMic` |
| 5. F5 during transcribing is busy and never resumes twice | `F5Busy` (daemon `record` answers reject busy); `StaleEnd` (a late cancel or stop ack after the end) | `NoDoubleResume` |
| 6. One pause owner; a manual pause during an F5 capture turns it into his own pause | `owner`; `UserPause` branch `user_pause_converts` (Fixed only) | `ManualPausePersists`, `OwnerConsistent` |

Today's projection, with anchors read on origin/main `d500e4ee`:
- In `.speaking`, `VoiceBarCommandRouter.handleHotkeyHoldStart` returns without recording (`flow-bar/Sources/VoiceBar/VoiceBarCommandRouter.swift:135-147`).
- In `.speaking`, `handleHotkeySingleTap` calls `handleStop`, wrapped in `retainingReadQueueOnStop` (`:163-173`, `VoiceBarApp.swift:1549-1555`).
- Over a paused read, a hold records and the read stays parked (`:136-139`).
- The daemon `record` handler calls `stopAll(undefined, "suspend")` while speaking (`src/socket-handlers.ts:483-486`).
- `speak_text` is rejected during a capture (`src/socket-handlers.ts:269`).
- Play is rejected while a capture owns the voice (`src/socket-handlers.ts:246-256`, `src/tts.ts:2190-2200`).
- The pause button is gone while recording (`BarView.swift:506`).

**Today fails only one invariant, `F5PausesPlayingSpeech`.** Both gestures break it: a hold is ignored, and a tap or
double tap stops the speech. TLC's `-continue` run found no other violations: today's code already keeps
`NoSpeechDuringOpenMic`, because it stops the speech, and `ManualPausePersists`. The defect is lost speech, not speech
talking over the mic. It matches Etan's "still no f5 pausing the run of option+f5".

## What the current queue spec implies for row 4 (decision needed in phase 2)

- `speak_text` arriving during a capture is **rejected** today (`src/socket-handlers.ts:269`, raw receipt `REJECTED`). It
  does not queue. The Fixed model queues it behind the paused read; that is a contract change, not today's rule.
- Agent speech and Ask **end the user chain** today (`setExternalSpeechPreemptionListener(() => selectionReads.clear())`,
  `src/socket-handlers.ts:161`). If an agent speech queues behind an F5-paused Option+F5 read, it must not fire that
  preemption listener while it waits. Otherwise the reads queued behind the paused read are silently cleared.
- F5 currently **suspends** the selection chain (`SelectionReadQueue.suspend`, `src/selection-read-queue.ts:122-126`)
  because it stops the owner. Under the contract, the owner is only paused, so the chain must stay live, not suspended.
  After the resume, its queued reads advance as before.
- A Stop during a capture over a paused read today ends **only the capture** (P16, `src/socket-handlers.ts:343`).
  Row 4 needs a **speech-scoped** stop during a capture, separate from the capture-scoped F5 release. The model
  keeps them as two actions: `UserStop` and `CaptureStop`.

## Sensitivity (each guard has a broken config that must fail)

| Config | Broken knob | Must violate |
|---|---|---|
| `F5PauseOpenFirst.cfg` | `PauseBeforeOpen = FALSE`: the mic opens, then the daemon pauses | `NoSpeechDuringOpenMic` |
| `F5PauseResumeOnPaste.cfg` | `ResumeOnEveryEnd = FALSE`: resume only after a paste | `NoF5PauseOutsideCapture` |
| `F5PauseStuck.cfg` | same knob, liveness only | `AutoPauseNeverStuck` (temporal) |

`F5PauseFixed` explores 1,945 distinct states. Every contract event is reachable in its state graph (TLC `-dump dot`):
`end_{pasted,empty,failed,cancelled,timeout}` (each with and without `_auto_resume`), `stop_in_capture`,
`queue_speech`, `f5_busy`, `stale_capture_end`, `user_pause_converts` and `f5_auto_pause_then_open`.

## Limits

This is a bounded model check. It is not a refinement proof and not a check of the source code. Nothing ties these
actions to the TypeScript or Swift yet. `ResumeFromPausedPosition` and `OwnerConsistent` hold by construction (no
action moves `pos` while paused), so they record intent rather than test it. Fairness covers capture progress only
(3600 s timeout, transcription settles); the user is never forced to act. Audio, focus and paste, and the archive are
outside the model.

## Code points phase 2 must touch

1. **Daemon record handler** `src/socket-handlers.ts:483-486`: replace `stopAll(undefined, "suspend")` with a pause
   owned by F5, before `waitForInput`. The record command runs inside a capture admission
   (`socket-handlers.ts:226`, `kind: "capture"`). `pausePlayback` refuses to park a read that has no first chunk yet
   while a capture is reserved (`src/tts.ts:2182`, reason `unsupported`). The pause must therefore land before the
   reservation, or get an F5-owner bypass. Either way, the order must stay pause → open (`F5PauseOpenFirst` shows the
   failure).
2. **Capture settlement**: resume an F5-owned pause exactly once when `waitForInput` settles, whatever the outcome
   (the promise at `socket-handlers.ts:490-500`). There are 8 recording-idle broadcasts in `src/input.ts`
   (2989, 3030, 3131, 3150, 3259, 3283, 3447) and one in `src/handlers.ts:817`. Use the single settle point, not each
   broadcast (`NoDoubleResume`).
3. **Playback pause/resume API** `src/tts.ts:2174-2200`: add an owner (`user | f5`) to the paused state, plus an
   internal resume that is allowed only after the capture is idle (Play stays `busy` during the capture).
4. **Selection queue** `src/selection-read-queue.ts:122-126`: do not `suspend` on an F5 pause. Queue a new speech
   behind the paused read (row 4 decision above).
5. **VoiceBar F5 path** `flow-bar/Sources/VoiceBar/VoiceBarCommandRouter.swift:135-173`: in `.speaking`, hold start
   records (as it does over a paused read) instead of returning. Single tap and double tap record instead of calling
   `handleStop`. Also `VoiceBarApp.swift:1549-1555` and `:2196-2204`, the `retainingReadQueueOnStop` wrappers.
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

## TLC output (copied from the logs)

Each run: `~/.local/bin/tlc -workers 1 -fp 0 -seed 1 -metadir .build.noindex/f5pause/<cfg> -config formal/speech-queue/<cfg>.cfg formal/speech-queue/F5Pause.tla` (2026-11-02, M4).

### F5PauseFixed: PASS (safety + liveness `AutoPauseNeverStuck`)

```text
TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)
Model checking completed. No error has been found.
11500 states generated, 1945 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 14.
```

### F5PauseCurrent: FAIL `F5PausesPlayingSpeech` (today). Shortest trace: hold over a playing speech is ignored

```text
TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)
Error: Invariant F5PausesPlayingSpeech is violated.
Error: The behavior up to this point is:
State 1: <Initial predicate>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "none"
/\ pendingPause = FALSE
/\ started = 0
/\ capture = "idle"
/\ queued = 0
/\ event = "init"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 2: <NewSpeech line 36, col 3 to line 43, col 77 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "playing"
/\ pendingPause = FALSE
/\ started = 1
/\ capture = "idle"
/\ queued = 0
/\ event = "speak"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 3: <F5 line 87, col 3 to line 106, col 94 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "playing"
/\ pendingPause = FALSE
/\ started = 1
/\ capture = "idle"
/\ queued = 0
/\ event = "f5_hold_ignored"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "playing"
10 states generated, 8 distinct states found, 5 states left on queue.
The depth of the complete state graph search is 3.
```

Same config with `-continue` (exit 0 because `-continue` does not stop on violations). Violation summary computed from that log:

```text
F5PausesPlayingSpeech violations reported: 84; distinct invariant names violated: ['F5PausesPlayingSpeech']
trace lines with event f5_hold_ignored: 42; with event f5_tap_stops: 42
6022 states generated, 1104 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 14.
```

First `-continue` trace for the tap/double branch: the tap stops the speech

```text
Error: Invariant F5PausesPlayingSpeech is violated.
Error: The behavior up to this point is:
State 1: <Initial predicate>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "none"
/\ pendingPause = FALSE
/\ started = 0
/\ capture = "idle"
/\ queued = 0
/\ event = "init"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 2: <NewSpeech line 36, col 3 to line 43, col 77 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "playing"
/\ pendingPause = FALSE
/\ started = 1
/\ capture = "idle"
/\ queued = 0
/\ event = "speak"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 3: <F5 line 87, col 3 to line 106, col 94 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "stopped"
/\ pendingPause = FALSE
/\ started = 1
/\ capture = "idle"
/\ queued = 0
/\ event = "f5_tap_stops"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "playing"
```

### F5PauseOpenFirst: FAIL `NoSpeechDuringOpenMic` (sensitivity)

```text
TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)
Error: Invariant NoSpeechDuringOpenMic is violated.
Error: The behavior up to this point is:
State 1: <Initial predicate>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "none"
/\ pendingPause = FALSE
/\ started = 0
/\ capture = "idle"
/\ queued = 0
/\ event = "init"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 2: <NewSpeech line 36, col 3 to line 43, col 77 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "playing"
/\ pendingPause = FALSE
/\ started = 1
/\ capture = "idle"
/\ queued = 0
/\ event = "speak"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 3: <F5 line 87, col 3 to line 106, col 94 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "playing"
/\ pendingPause = TRUE
/\ started = 1
/\ capture = "recording"
/\ queued = 0
/\ event = "f5_open_then_pause"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "playing"
12 states generated, 8 distinct states found, 5 states left on queue.
The depth of the complete state graph search is 3.
```

### F5PauseResumeOnPaste: FAIL `NoF5PauseOutsideCapture` (sensitivity)

```text
TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)
Error: Invariant NoF5PauseOutsideCapture is violated.
Error: The behavior up to this point is:
State 1: <Initial predicate>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "none"
/\ pendingPause = FALSE
/\ started = 0
/\ capture = "idle"
/\ queued = 0
/\ event = "init"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 2: <NewSpeech line 36, col 3 to line 43, col 77 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "playing"
/\ pendingPause = FALSE
/\ started = 1
/\ capture = "idle"
/\ queued = 0
/\ event = "speak"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 3: <F5 line 87, col 3 to line 106, col 94 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "f5"
/\ speech = "paused"
/\ pendingPause = FALSE
/\ started = 1
/\ capture = "recording"
/\ queued = 0
/\ event = "f5_auto_pause_then_open"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "playing"
State 4: <EndCapture line 127, col 3 to line 134, col 62 of module F5Pause>
/\ endOwner = "f5"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "f5"
/\ speech = "paused"
/\ pendingPause = FALSE
/\ started = 1
/\ capture = "idle"
/\ queued = 0
/\ event = "end_failed"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "playing"
52 states generated, 32 distinct states found, 23 states left on queue.
The depth of the complete state graph search is 4.
```

### F5PauseStuck: FAIL temporal `AutoPauseNeverStuck` (sensitivity; lasso, so the timeout leaves F5 owning the pause forever)

```text
TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)
Error: Temporal properties were violated.
Error: The following behavior constitutes a counter-example:
State 1: <Initial predicate>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "none"
/\ pendingPause = FALSE
/\ started = 0
/\ capture = "idle"
/\ queued = 0
/\ event = "init"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 2: <NewSpeech line 36, col 3 to line 43, col 77 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "playing"
/\ pendingPause = FALSE
/\ started = 1
/\ capture = "idle"
/\ queued = 0
/\ event = "speak"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 3: <NewSpeech line 36, col 3 to line 43, col 77 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "none"
/\ speech = "playing"
/\ pendingPause = FALSE
/\ started = 2
/\ capture = "idle"
/\ queued = 1
/\ event = "queue_speech"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "none"
State 4: <F5 line 87, col 3 to line 106, col 94 of module F5Pause>
/\ endOwner = "none"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "f5"
/\ speech = "paused"
/\ pendingPause = FALSE
/\ started = 2
/\ capture = "recording"
/\ queued = 1
/\ event = "f5_auto_pause_then_open"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "playing"
State 5: <EndCapture line 127, col 3 to line 134, col 62 of module F5Pause>
/\ endOwner = "f5"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "f5"
/\ speech = "paused"
/\ pendingPause = FALSE
/\ started = 2
/\ capture = "idle"
/\ queued = 1
/\ event = "end_timeout"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "playing"
State 6: <F5 line 87, col 3 to line 106, col 94 of module F5Pause>
/\ endOwner = "f5"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "f5"
/\ speech = "paused"
/\ pendingPause = FALSE
/\ started = 2
/\ capture = "recording"
/\ queued = 1
/\ event = "f5_record"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "paused"
State 7: <EndCapture line 127, col 3 to line 134, col 62 of module F5Pause>
/\ endOwner = "f5"
/\ pausedAt = 0
/\ pos = 0
/\ owner = "f5"
/\ speech = "paused"
/\ pendingPause = FALSE
/\ started = 2
/\ capture = "idle"
/\ queued = 1
/\ event = "end_cancelled"
/\ resumes = 0
/\ stopInCapture = FALSE
/\ f5Saw = "paused"
Back to state 6: <F5 line 87, col 3 to line 106, col 94 of module F5Pause>
Finished checking temporal properties in 00s at 2026-11-02 05:26:42
14824 states generated, 2434 distinct states found, 0 states left on queue.
```

### Full gate: `gtimeout -s TERM -k 10 900 formal/speech-queue/check.sh` (F5Pause rows and verdict)

```text
F5PauseCurrent: EXPECTED violation F5PausesPlayingSpeech; 10 states generated, 8 distinct states found
F5PauseFixed: PASS; 11500 states generated, 1945 distinct states found
F5PauseOpenFirst: EXPECTED violation NoSpeechDuringOpenMic; 12 states generated, 8 distinct states found
F5PauseResumeOnPaste: EXPECTED violation NoF5PauseOutsideCapture; 52 states generated, 32 distinct states found
F5PauseStuck: EXPECTED violation temporal; 14824 states generated, 2434 distinct states found
PASS: queue/History runtime and real Swift/daemon admission conformance; sixteen expected counterexamples
exit=0
```
