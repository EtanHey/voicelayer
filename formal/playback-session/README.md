# PlaybackSession (Lane B, VoiceLayer 2.4)

One explicit session machine for Option+F5 reads, `voice_speak` and `voice_ask` narration and the
teleprompter. `src/playback/session.ts` implements the same states, events and invariants;
`src/playback/ledger.ts` is the daemon's single ledger, fed by the player driver in `src/tts.ts`.

States: `queued`, `preparing`, `playing`, `paused`, `seeking`, `parked` (by an ask), `ended`.
Events: start, ready, word, teleprompter sync, end, reap, pause, resume, seek, seek done, Esc,
previous read, ask preempt, prompt start/end, mic open, capture end, ask abort, recorder exit,
ask restore, ask release, stop.

Ask phases: `none`, `waiting`, `prompt`, `capturewait`, `capture`, `closing`, `transcribing`. `transcribing` is the
capture-end r2 window: the recorder has exited, the answer is transcribing and the ask still holds its capture
admission. A read the ask found playing is restored at its word when the window opens (AskRestore) and may play in it;
a read the user had paused stays parked until the ask releases (AskRelease) and comes back paused. No other read starts
in the window (the next queued read waits for the release), and a second ask is not enabled (the daemon refuses it as
capture-owned before touching the read). Pause, resume and Esc work on the restored read in the window. Seek does not: `seekPlayback` and `seekSpeechWord` refuse any non-idle recording state, transcribing included, so the model enables Seek only with no ask.

Positions are word indices held by the session. `mark` is the ground truth (the word heard when
the read left the speaker); `pausedAt` is what the engine stored; a resume must land on `mark`.

| Invariant | Bug it prevents | Mutant config(s) |
| --- | --- | --- |
| ResumeExact | Etan: "pause sometimes jumps back" (QA 2026-11-08: the pause button rewound to 0:00) | JumpBackMutant, SecondAskMutant |
| OneAudible | two voices at once: a read or the ask prompt starting over a player still exiting | OverlapMutant |
| AskParksOne | "a second voice_ask over a paused read didn't resume": a read left parked after an ask | StrandMutant |
| MicExclusive | the mic records our own audio: prompt still exiting, or a read resumed before the recorder exited (capture-end r2) | EarlyMicMutant, RecorderWaitMutant |
| TeleTracksAudio | "wrong clock": the teleprompter restarting at 0 on resume/restore | ClockResetMutant |
| OneLiveSession | "overlap": previous read starting without ending the current one | PrevOverlapMutant |
| NoZombie | a stopped or replaced preparation still starting its player | ZombieMutant |
| NoSameQueued | Etan (2026-11-08): Option+F5 on the text being read must dedupe, never queue it behind itself | SameQueuesMutant |
| AskKeepsRead | Lane B night item 3 + statechart gap 1: an ask cancels a read (a read still preparing, or any read whose park the driver refused) | CancelPreparingMutant, AskCancelsReadMutant |
| QueueSurvivesAsk | statechart gap 2: an ask that parks nothing empties the narration queue (`selectionReads.clear()`) | AskClearsQueueMutant |
| SuccessorWaitsForRelease | statechart gap 5: the next queued read starts while the ask's answer is still transcribing | EarlySuccessorMutant |
| ParkedEventuallyReleased (temporal, under FairSpec) | #818 review: a read an ask parked is eventually restored or ended, never left parked | NoRestoreMutant |

TeleTracksAudio allows one word event of lag on purpose: the teleprompter learns each word after the audio speaks it
(Advance then TeleSync). It is exact after every TeleSync, and a resume/restore resets it to the stored word.

Option+F5 over a read (OptF5Empty / OptF5Same / OptF5Other, Etan 2026-11-08): an empty selection pauses or
resumes the read, the same text sets the "Already reading this" notice, different text joins the narration queue.

Liveness: `Liveness.cfg` checks ParkedEventuallyReleased under FairSpec, weak fairness on the ask's progress
steps (prompt start/end, mic open, capture end, recorder exit, reap, restore, release).

`W == 2` keeps Fixed at 837,722 distinct states (`results/Fixed.log`); every mutant still trips. "Previous read" holds the read on screen (prevHeld) and PrevReturn brings it back paused at its word.

Stop during an ask ends the ask and the read it parked: Stop means stop (the paused-ask stack's W1 "stopped" contract).

## Code and model (statechart audit, BRIEF-B-MODEL-GAPS)

- **An ask never cancels a read** (gap 1). The driver's old refusals are parks now (`tts.ts holdReadForAsk`): a read
  whose next chunk is still synthesizing is parked through its admission directly, never through a refusable Pause;
  a read chunk queued behind short agent speech is parked where it waits; a critical-priority read is parked like any
  read. A capture admission already reserved is the previous ask's `transcribing` window: the second ask is refused
  (`capture-owned`) before the read is touched. A read the driver still cannot park (not reachable from voice_ask;
  the recorder check is synchronous before the hold) is ended in the player and the engine and logged as an
  `AskKeepsRead(driver)` violation. `ledgerAskBegin` names the session the driver parked, so the engine never records a
  park the player did not make. AskCancelsReadMutant is the old fallback.
- **An ask never touches the narration queue** (gap 2): `preemptLongRead("ask")` no longer empties `selectionReads`.
  Agent speech still ends the user's chain (QUEUE1b).
- **Seeking is real** (gap 3): a committed live seek or speed change calls `ledgerSeek` (queue `commitSeek` and the
  long-read runner's `seekCommitted`), so the engine goes playing → seeking and its new player's start is SeekDone. A
  chunk boundary is a logged `next-chunk` transition.
- **An ask during a previous_read replay parks the replay** (gap 4), the read on screen at its word, and the read held
  aside stays held (its own queue slot). After the ask the replay plays on; the held read returns paused when the replay
  is over and any ask has released (PrevReturn needs `ask = "none"`). This is the model's AskPreempt unchanged.
- **The engine collapses `transcribing`** (gap 5): `session.ts` restores the read in one `askRestore` (at recorder
  exit for a playing read, at the ask's end for a paused one), and the successor's wait is held by the driver
  (`PlaybackQueueManager.settleRead` and the capture-admission filter in `processNext`). The model carries the phase
  so the wait is checked; the engine needs no state for it because nothing else may start under the admission.
- **Out of scope: `playback_rate`.** Speed is not modelled. `applySpeed` restarts the playing player at its current
  word through Seek / SeekDone (so ResumeExact and TeleTracksAudio hold for it), but the rate scaling of the player
  clock, the pause cursor and the watchdog is code-only, covered by the daemon tests (`playback-engine.test.ts`
  set_playback_speed rows), not by TLC.
- The model checks at most two asks per run (`asks < 2`).

Run: `bash formal/playback-session/check.sh` (recorded evidence in `results/`).
