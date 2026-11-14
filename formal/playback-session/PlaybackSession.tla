------------------------------ MODULE PlaybackSession ------------------------------
(* Lane B (2.4): ONE explicit session machine for Option+F5 reads, voice_speak and
   voice_ask narration and the teleprompter. src/playback/session.ts implements
   these states and events (it folds the ask's "transcribing" phase into askRestore;
   the driver holds the successor's wait, see README); src/__tests__/playback-session.test.ts
   replays the same transitions.

   Reads 1 and 2 are queued reads (2 follows 1, so "previous read" exists). Id 3 is
   the voice_ask prompt, which is audio too. Words are 0 .. W-1; cursor W means the
   read played past its last word (pausing exactly there is allowed).

   Positions are WORD INDICES held by the session, never a time re-derived from a
   client clock or a re-synthesised clip. `mark` is the ground truth: the word the
   listener was on when the read left the speaker. `pausedAt` is what the engine
   stored. A resume must land on `mark`. *)
EXTENDS Naturals, FiniteSets

CONSTANTS
  JumpBack,          \* Reported pause rewind: client clock resets to word zero
  SkipReap,          \* audio starts before the previous player exited: two voices at once
  StrandOnFail,      \* an ask ends without restoring the read it parked: read lost after an ask
  ParkResumeAtZero,  \* an ask over a read still preparing its resume parks it at word 0 (second ask bug)
  OpenMicEarly,      \* the mic opens while the prompt player is still exiting
  SkipRecorderWait,  \* the read resumes before the recorder exited (capture-end r2)
  ClockReset,        \* resume/restore restarts the teleprompter clock at 0: wrong clock
  PrevKeepsCurrent,  \* "previous read" starts the old read without ending the current one: overlap
  ZombieReady,       \* a cancelled preparation still starts its player after Esc/Stop
  SameQueues,        \* Playback selection remains associated with its originating session.
  NoRestore,         \* the ask's end never restores the read it parked (liveness mutant)
  CancelPreparing,   \* an ask over a read still preparing cancels it instead of parking it (the N4 guard's limit)
  CancelUnparkable,  \* the driver's park is refused (another job in front, a critical job, the pause refused) and the
                     \* ask cancels the read instead (statechart gap 1, #818: preemptLongRead("ask") after a refused hold)
  AskClearsQueue,    \* an ask that parks nothing empties the narration queue (statechart gap 2: selectionReads.clear())
  SuccessorEarly,    \* the next queued read starts while the ask still owns capture (its answer transcribing)
  ClientLayer,       \* TRUE: the client observer below is checked (ClientFixed and its mutants); FALSE freezes it
  MaxAsks,           \* asks per run: 2 for the engine configs, 1 for ClientFixed (state budget, see README)
  BareReturn         \* (2.4 teleprompter freeze, M4 03:28:48.849) the previous-read return sends only a bare
                     \* playback_state(paused) for the held player, which the client drops as wrong-owner

Reads == {1, 2}
Prompt == 3
W == 2   \* two words keep Fixed small enough for one TLC worker (count in README and results/Fixed.log); every mutant trips
NoPos == 9
None == 0
Live == {"preparing", "playing", "paused", "seeking", "parked"}
Positioned == {"preparing", "playing", "paused", "seeking"}

VARIABLES st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, prep,
          ask, parked, parkedFrom, mic, recorder, asks, prevHeld, optq, notice, askFound, restoring, lost,
          cOwner, cPhase, cWord, restored, retReplay
\* Client layer (VoiceBar VoiceState, the 2.4 teleprompter-freeze extension): cOwner is the read whose presentation
\* (text, word table, playback identity) the client shows, cPhase what it shows that read doing, cWord the word it
\* shows. restored / retReplay are history: the read the last previous-read return brought back (while it stays
\* paused) and the replay that return ended (until the next replay is presented).
clientVars == <<cOwner, cPhase, cWord, restored, retReplay>>
vars == <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, prep,
          ask, parked, parkedFrom, mic, recorder, asks, prevHeld, optq, notice, askFound, restoring, lost, clientVars>>

Dist(a, b) == IF a >= b THEN a - b ELSE b - a
Quiet == players \cup exiting = {}
NoLive == \A x \in Reads : st[x] \notin Live
Leave(r) == /\ players' = players \ {r}
            /\ exiting' = exiting \cup (players \cap {r})

Init == /\ st = [r \in Reads |-> "queued"]
        /\ cur = [r \in Reads |-> 0]
        /\ pausedAt = [r \in Reads |-> NoPos]
        /\ mark = [r \in Reads |-> NoPos]
        /\ resumedAt = [r \in Reads |-> NoPos]
        /\ seekTo = [r \in Reads |-> 0]
        /\ tele = 0 /\ players = {} /\ exiting = {} /\ prep = {}
        /\ ask = "none" /\ parked = None /\ parkedFrom = "none"
        /\ mic = FALSE /\ recorder = FALSE /\ asks = 0 /\ prevHeld = None
        /\ optq = {} /\ notice = FALSE /\ askFound = None /\ restoring = None /\ lost = FALSE
        /\ cOwner = None /\ cPhase = "idle" /\ cWord = 0 /\ restored = None /\ retReplay = None

\* Pause, resume and Esc work with no ask, and on the read an ask restored while its answer transcribes
\* (the read_processing window; tts.ts isProcessingRead).
UserControls == ask \in {"none", "transcribing"}
\* Seek works only with no ask: seekPlayback and seekSpeechWord refuse any non-idle recording state, transcribing
\* included (tts.ts seekPlayback / seekSpeechWord; no isProcessingRead exception).
SeekControls == ask = "none"

\* Next queued read: read 2 only after read 1 ended.
\* The ask's capture admission ("transcribing") still holds the speaker for the read it restored only, so the next
\* read waits for the ask to release (tts.ts settleRead / beginReadProcessing; SuccessorEarly drops the wait).
Start(r) == /\ st[r] = "queued" /\ NoLive /\ r # prevHeld
            /\ (ask = "none" \/ (SuccessorEarly /\ ask = "transcribing"))
            /\ (r = 1 \/ st[1] = "ended")
            /\ st' = [st EXCEPT ![r] = "preparing"]
            /\ cur' = [cur EXCEPT ![r] = 0] /\ tele' = 0
            /\ prep' = prep \cup {r}
            /\ UNCHANGED <<pausedAt, mark, resumedAt, seekTo, players, exiting, ask, parked, parkedFrom, mic, recorder, asks>>

\* The player for a prepared session starts only when the speaker is quiet and the mic is closed.
Ready(r) == /\ r \in prep
            /\ (st[r] = "preparing" \/ ZombieReady)
            /\ (Quiet \/ SkipReap) /\ ~mic
            /\ players' = players \cup {r} /\ prep' = prep \ {r}
            /\ st' = [st EXCEPT ![r] = IF st[r] = "preparing" THEN "playing" ELSE st[r]]
            /\ UNCHANGED <<cur, pausedAt, mark, resumedAt, seekTo, tele, exiting, ask, parked, parkedFrom, mic, recorder, asks>>

\* A preparation whose session moved on is dropped, never started.
DropPrep(r) == /\ r \in prep /\ st[r] # "preparing" /\ ~ZombieReady
               /\ prep' = prep \ {r}
               /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, ask, parked, parkedFrom, mic, recorder, asks>>

\* The player speaks the next word; the teleprompter is one word-event behind at most.
Advance(r) == /\ st[r] = "playing" /\ r \in players /\ cur[r] < W /\ tele = cur[r]
              /\ cur' = [cur EXCEPT ![r] = cur[r] + 1]
              /\ UNCHANGED <<st, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, prep, ask, parked, parkedFrom, mic, recorder, asks>>

TeleSync(r) == /\ st[r] \in Positioned /\ tele # cur[r]
               /\ tele' = cur[r]
               /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, players, exiting, prep, ask, parked, parkedFrom, mic, recorder, asks>>

End(r) == /\ st[r] = "playing" /\ cur[r] = W
          /\ st' = [st EXCEPT ![r] = "ended"] /\ Leave(r)
          /\ UNCHANGED <<cur, pausedAt, mark, resumedAt, seekTo, tele, prep, ask, parked, parkedFrom, mic, recorder, asks>>

Reap == /\ exiting # {} /\ \E x \in exiting : exiting' = exiting \ {x}
        /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, prep, ask, parked, parkedFrom, mic, recorder, asks>>

\* Pause from playing, or from preparing (CLICK2: Pause landed before the player existed).
Pause(r) == /\ st[r] \in {"playing", "preparing"} /\ UserControls
            /\ st' = [st EXCEPT ![r] = "paused"]
            /\ mark' = [mark EXCEPT ![r] = cur[r]]
            /\ pausedAt' = [pausedAt EXCEPT ![r] = IF JumpBack THEN 0 ELSE cur[r]]
            /\ resumedAt' = [resumedAt EXCEPT ![r] = NoPos]
            /\ Leave(r)
            /\ UNCHANGED <<cur, seekTo, tele, prep, ask, parked, parkedFrom, mic, recorder, asks>>

Resume(r) == /\ st[r] = "paused" /\ UserControls
             /\ LET to == IF JumpBack THEN 0 ELSE pausedAt[r] IN
                /\ st' = [st EXCEPT ![r] = "preparing"]
                /\ cur' = [cur EXCEPT ![r] = to]
                /\ resumedAt' = [resumedAt EXCEPT ![r] = to]
                /\ tele' = IF ClockReset THEN 0 ELSE to
             /\ prep' = prep \cup {r}
             /\ UNCHANGED <<pausedAt, mark, seekTo, players, exiting, ask, parked, parkedFrom, mic, recorder, asks>>

\* Seek one word back or forward from a playing read.
Seek(r) == /\ st[r] = "playing" /\ SeekControls
           /\ \E to \in {cur[r] - 1, cur[r] + 1} \cap 0 .. (W - 1) :
                seekTo' = [seekTo EXCEPT ![r] = to]
           /\ st' = [st EXCEPT ![r] = "seeking"] /\ Leave(r)
           /\ UNCHANGED <<cur, pausedAt, mark, resumedAt, tele, prep, ask, parked, parkedFrom, mic, recorder, asks>>

SeekDone(r) == /\ st[r] = "seeking"
               /\ st' = [st EXCEPT ![r] = "preparing"]
               /\ cur' = [cur EXCEPT ![r] = seekTo[r]] /\ tele' = seekTo[r]
               /\ resumedAt' = [resumedAt EXCEPT ![r] = NoPos]
               /\ prep' = prep \cup {r}
               /\ UNCHANGED <<pausedAt, mark, seekTo, players, exiting, ask, parked, parkedFrom, mic, recorder, asks>>

\* Esc stops the read on screen (including a resumed one).
Esc(r) == /\ st[r] \in Positioned /\ UserControls
          /\ st' = [st EXCEPT ![r] = "ended"] /\ Leave(r)
          /\ UNCHANGED <<cur, pausedAt, mark, resumedAt, seekTo, tele, prep, ask, parked, parkedFrom, mic, recorder, asks>>

\* Previous read: read 1 plays again from its first word. Read 2 is held off screen at its exact
\* word (seeking holds its target) and comes back PAUSED there when read 1 is over (PrevReturn).
PreviousRead == /\ st[2] \in Positioned /\ st[1] = "ended" /\ ask = "none" /\ prevHeld = None
                /\ LET at == IF st[2] = "paused" THEN pausedAt[2] ELSE IF st[2] = "seeking" THEN seekTo[2] ELSE cur[2]
                       truth == IF st[2] = "paused" THEN mark[2] ELSE at IN
                   /\ pausedAt' = [pausedAt EXCEPT ![2] = at]
                   /\ mark' = [mark EXCEPT ![2] = truth]
                /\ st' = [st EXCEPT ![1] = "preparing", ![2] = IF PrevKeepsCurrent THEN st[2] ELSE "queued"]
                /\ cur' = [cur EXCEPT ![1] = 0]
                /\ resumedAt' = [resumedAt EXCEPT ![2] = NoPos]
                /\ tele' = 0
                /\ prep' = prep \cup {1}
                /\ prevHeld' = IF PrevKeepsCurrent THEN None ELSE 2
                /\ IF PrevKeepsCurrent THEN UNCHANGED <<players, exiting>> ELSE Leave(2)
                /\ UNCHANGED <<seekTo, ask, parked, parkedFrom, mic, recorder, asks>>

\* The previous read is over (ended or stopped): the held read returns paused at its word.
PrevReturn == /\ prevHeld # None /\ st[1] = "ended" /\ ask = "none"
              /\ st' = [st EXCEPT ![prevHeld] = "paused"]
              /\ cur' = [cur EXCEPT ![prevHeld] = pausedAt[prevHeld]]
              /\ tele' = pausedAt[prevHeld]
              /\ prevHeld' = None
              /\ UNCHANGED <<pausedAt, mark, resumedAt, seekTo, players, exiting, prep, ask, parked, parkedFrom, mic, recorder, asks>>

\* voice_ask preempts: whatever read is on screen is parked at its exact word, in every positioned state:
\* playing, paused, seeking, and preparing (its first audio or a resume not ready yet; it plays once its audio
\* exists, after the ask). CancelPreparing is the paused-ask stack's N4 guard, which cancelled a read whose
\* runner had not started yet.
\*
\* The driver's refused parks (statechart gap 1) are all parks here, which is what tts.ts holdReadForAsk now does:
\*  - another job in front of the read (its next chunk still preparing, or its chunk queued behind short speech):
\*    the read's own admission or queued chunk is parked directly, never through a refusable Pause;
\*  - a critical-priority read job: parked like any read (the ask-owner park ignores the critical guard);
\*  - capture admission already reserved: that is the previous ask's "transcribing" window, where ask # "none",
\*    so this action is not enabled; the daemon refuses the second ask (capture-owned) before touching the read.
\* CancelUnparkable is the old fallback (preemptLongRead("ask") cancelled the read the hold refused).
\* A read the driver still cannot park (unreachable from voice_ask: the recorder check is synchronous) is ended in
\* the engine too and logged as an AskKeepsRead(driver) violation: never a park the player does not honour.
ParkForAsk(r) == /\ LET truth == CASE st[r] = "seeking" -> seekTo[r]
                                   [] OTHER -> cur[r]
                        stored == CASE st[r] = "paused" -> pausedAt[r]
                                    [] st[r] = "preparing" /\ ParkResumeAtZero -> 0
                                    [] OTHER -> truth
                    IN /\ pausedAt' = [pausedAt EXCEPT ![r] = stored]
                       /\ mark' = [mark EXCEPT ![r] = IF st[r] = "paused" THEN mark[r] ELSE truth]
                 /\ parkedFrom' = IF st[r] = "paused" THEN "paused" ELSE "playing"
                 /\ st' = [st EXCEPT ![r] = "parked"] /\ parked' = r
                 /\ resumedAt' = [resumedAt EXCEPT ![r] = NoPos]
                 /\ Leave(r)

CancelForAsk(r) == /\ st' = [st EXCEPT ![r] = "ended"] /\ parked' = None /\ parkedFrom' = "none"
                   /\ UNCHANGED <<pausedAt, mark, resumedAt>> /\ Leave(r)

AskPreempt == /\ ask = "none" /\ asks < MaxAsks
              /\ ask' = "waiting" /\ asks' = asks + 1
              /\ IF \E r \in Reads : st[r] \in Positioned
                 THEN \E r \in Reads :
                        /\ st[r] \in Positioned
                        /\ IF CancelUnparkable \/ (CancelPreparing /\ st[r] = "preparing")
                           THEN CancelForAsk(r) ELSE ParkForAsk(r)
                 ELSE UNCHANGED <<st, pausedAt, mark, parkedFrom, parked, resumedAt, players, exiting>>
              /\ UNCHANGED <<cur, seekTo, tele, prep, mic, recorder>>

AskPromptStart == /\ ask = "waiting" /\ (Quiet \/ SkipReap) /\ ~mic
                  /\ ask' = "prompt" /\ players' = players \cup {Prompt} /\ tele' = 0
                  /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, exiting, prep, parked, parkedFrom, mic, recorder, asks>>

AskPromptEnd == /\ ask = "prompt" /\ Prompt \in players
                /\ ask' = "capturewait" /\ Leave(Prompt)
                /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, prep, parked, parkedFrom, mic, recorder, asks>>

MicOpen == /\ ask = "capturewait" /\ (Quiet \/ OpenMicEarly)
           /\ ask' = "capture" /\ mic' = TRUE /\ recorder' = TRUE
           /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, prep, parked, parkedFrom, asks>>

\* Capture end: an answer, a failed capture, a cancel or a timeout. All close the mic first.
CaptureEnd == /\ ask = "capture"
              /\ ask' = "closing" /\ mic' = FALSE
              /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, prep, parked, parkedFrom, recorder, asks>>

\* The ask fails or is cancelled (Esc) before or during its prompt/capture.
AskAbort == /\ ask \in {"waiting", "prompt", "capturewait", "capture"}
            /\ ask' = "closing" /\ mic' = FALSE /\ Leave(Prompt)
            /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, prep, parked, parkedFrom, recorder, asks>>

RecorderExit == /\ recorder /\ ~mic /\ recorder' = FALSE
                /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, prep, ask, parked, parkedFrom, mic, asks>>

\* The recorder has exited (capture-end r2): a read the ask found playing is restored now, from its exact word, and
\* plays while the answer transcribes. A read the user had paused stays parked until the ask releases. The ask keeps
\* its capture admission ("transcribing"): no other read may start yet.
AskRestore == /\ ask = "closing" /\ (~recorder \/ SkipRecorderWait) /\ ~NoRestore
              /\ ask' = "transcribing"
              /\ IF parked = None \/ parkedFrom = "paused"
                 THEN UNCHANGED <<st, cur, resumedAt, tele, prep, parked, parkedFrom>>
                 ELSE LET p == parked IN
                      /\ parked' = None /\ parkedFrom' = "none"
                      /\ IF StrandOnFail THEN UNCHANGED <<st, cur, resumedAt, tele, prep>>
                         ELSE /\ st' = [st EXCEPT ![p] = "preparing"]
                              /\ cur' = [cur EXCEPT ![p] = pausedAt[p]]
                              /\ resumedAt' = [resumedAt EXCEPT ![p] = pausedAt[p]]
                              /\ tele' = IF ClockReset THEN 0 ELSE pausedAt[p]
                              /\ prep' = prep \cup {p}
              /\ UNCHANGED <<pausedAt, mark, seekTo, players, exiting, mic, recorder, asks>>

\* The ask releases its capture admission (answer delivered, failure, cancel, timeout): a read the user had paused
\* comes back paused at its exact word (restores_paused_read), and the next read may start.
AskRelease == /\ ask = "transcribing"
              /\ ask' = "none" /\ parked' = None /\ parkedFrom' = "none"
              /\ IF parked = None \/ StrandOnFail
                 THEN UNCHANGED <<st, cur, tele>>
                 ELSE /\ st' = [st EXCEPT ![parked] = "paused"]
                      /\ cur' = [cur EXCEPT ![parked] = pausedAt[parked]]
                      /\ tele' = IF ClockReset THEN 0 ELSE pausedAt[parked]
              /\ UNCHANGED <<pausedAt, mark, resumedAt, seekTo, players, exiting, prep, mic, recorder, asks>>

\* Stop: every positioned read ends and an ask in flight closes, together with the read it parked: Stop
\* means stop (paused-ask stack W1 "stopped", merged into Lane B on the M1, 2026-11-08 night).
StopAll == /\ (\E r \in Reads : st[r] \in Positioned) \/ ask \notin {"none", "closing", "transcribing"} \/ parked # None
           /\ st' = [r \in Reads |-> IF st[r] \in Positioned \/ r = parked THEN "ended" ELSE st[r]]
           /\ players' = {} /\ exiting' = exiting \cup players
           /\ parked' = None /\ parkedFrom' = "none"
           /\ mic' = FALSE
           /\ ask' = IF ask \in {"none", "transcribing"} THEN ask ELSE "closing"
           /\ UNCHANGED <<cur, pausedAt, mark, resumedAt, seekTo, tele, prep, recorder, asks>>

Others == \/ \E r \in Reads : Start(r) \/ Ready(r) \/ DropPrep(r) \/ Advance(r) \/ TeleSync(r) \/ End(r)
                              \/ Pause(r) \/ Resume(r) \/ Seek(r) \/ SeekDone(r) \/ Esc(r)
          \/ Reap \/ AskPreempt \/ AskPromptStart \/ AskPromptEnd \/ MicOpen
          \/ CaptureEnd \/ AskAbort \/ RecorderExit \/ AskRestore \/ AskRelease \/ StopAll

\* Option+F5 over a read that is playing or paused (Etan, 2026-11-08 4:40 pm). `optq` is the narration queue the
\* press joins; `notice` is "Already reading this".
OptF5Empty == \E r \in Reads :
                /\ st[r] \in {"playing", "paused"} /\ ask = "none"
                /\ IF st[r] = "playing" THEN Pause(r) ELSE Resume(r)
                /\ UNCHANGED <<prevHeld, optq, notice>>
OptF5Same == \E r \in Reads :
               /\ st[r] \in {"playing", "paused"} /\ ask = "none"
               /\ notice' = TRUE
               /\ optq' = IF SameQueues THEN optq \cup {r} ELSE optq
               /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, prep,
                              ask, parked, parkedFrom, mic, recorder, asks, prevHeld>>
OptF5Other == \E r, t \in Reads :
                /\ r # t /\ st[r] \in {"playing", "paused"} /\ st[t] = "queued" /\ t \notin optq /\ ask = "none"
                /\ optq' = optq \cup {t} /\ notice' = FALSE
                /\ UNCHANGED <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, prep,
                               ask, parked, parkedFrom, mic, recorder, asks, prevHeld>>

\* History: the read the ask found on screen, until the ask restores it or a Stop ends both.
TrackAsk == askFound' = CASE ask = "none" /\ ask' = "waiting" ->
                               (IF \E r \in Reads : st[r] \in Positioned THEN CHOOSE r \in Reads : st[r] \in Positioned ELSE None)
                          [] ask' = "none" \/ (parked # None /\ parked' = None) -> None
                          [] OTHER -> askFound

TrackStep ==
        \/ Others /\ UNCHANGED <<prevHeld, notice>>
           /\ optq' = IF AskClearsQueue /\ ask = "none" /\ ask' = "waiting" /\ parked' = None THEN {}
                      ELSE optq \ {r \in Reads : st'[r] \in Live}
        \/ (PreviousRead \/ PrevReturn) /\ UNCHANGED notice /\ optq' = optq \ {r \in Reads : st'[r] \in Live}
        \/ OptF5Empty \/ OptF5Same \/ OptF5Other

\* The read an ask restored at its recorder's exit: the only read that may play while the answer transcribes.
TrackRestore == restoring' = CASE ask = "closing" /\ ask' = "transcribing" /\ parkedFrom = "playing" -> parked
                              [] ask' = "transcribing" -> restoring
                              [] OTHER -> None

\* History: a read left the narration queue without going live (the queue was emptied under it).
TrackLost == lost' = (lost \/ \E r \in optq : r \notin optq' /\ st'[r] \notin Live)

(* The client applies, in socket order, the event each daemon step emits. A step and the delivery of its event are one
   TLC step: the socket is FIFO and VoiceState applies events on the main queue in order, so delivery delay changes
   when the client sees an event, never which events it accepts. (A stalled main queue is out of scope; see README.)

   Presentations carry a read's identity and replace what the client shows:
   - a read first going live (Start, and PreviousRead's replay of read 1): state(speaking) with its word table;
   - the ask's release of a read the user had paused: state(idle, restores_paused_read) (tts.ts
     broadcastRestoresPausedRead), which VoiceState accepts for the read it saw the ask park;
   - Fixed only: the previous-read return's restore receipt (the held read's presentation, playback identity,
     offset and pause owner). With BareReturn the return is only playback_state(paused) for the held player, and
     VoiceState.ownsPlaybackEvent drops it as wrong-owner because the client still owns the replay's player.
   Every other event is about one player and is applied only if the client owns that read (ownsPlaybackEvent).
   A replay that ends while a read is held emits no playback idle: its completion runs the return instead, and the
   daemon never sends a playback idle while a read is parked (VoiceState's "idle" arm). *)
ClientApply ==
  LET presented == {r \in Reads : st[r] \in {"queued", "ended"} /\ st'[r] = "preparing"}
      returned == IF prevHeld # None /\ prevHeld' = None THEN prevHeld ELSE None
      released == IF ask = "transcribing" /\ ask' = "none" /\ parked # None /\ st'[parked] = "paused" THEN parked ELSE None
      r == cOwner
  IN /\ IF presented # {} THEN
           /\ cOwner' = (CHOOSE x \in presented : TRUE) /\ cPhase' = "running" /\ cWord' = 0
        ELSE IF returned # None /\ ~BareReturn THEN
           /\ cOwner' = returned /\ cPhase' = "paused" /\ cWord' = pausedAt'[returned]
        ELSE IF released # None THEN
           /\ cOwner' = released /\ cPhase' = "paused" /\ cWord' = pausedAt'[released]
        ELSE IF r # None /\ st'[r] = "ended" /\ st[r] # "ended" THEN
           /\ cPhase' = IF prevHeld # None /\ prevHeld # r THEN cPhase ELSE "ended"
           /\ UNCHANGED <<cOwner, cWord>>
        ELSE IF r # None /\ st'[r] \in {"paused", "parked"} THEN
           /\ cPhase' = "paused" /\ cWord' = pausedAt'[r] /\ UNCHANGED cOwner
        ELSE IF r # None /\ st'[r] \in {"preparing", "playing", "seeking"} THEN
           /\ cPhase' = "running" /\ cWord' = (IF st'[r] = "seeking" THEN cWord ELSE tele') /\ UNCHANGED cOwner
        ELSE UNCHANGED <<cOwner, cPhase, cWord>>
     /\ restored' = IF returned # None THEN returned
                    ELSE IF restored # None /\ st'[restored] = "paused" THEN restored ELSE None
     /\ retReplay' = IF returned # None THEN (CHOOSE x \in Reads : x # returned)
                     ELSE IF presented # {} THEN None ELSE retReplay

ClientStep == IF ~ClientLayer THEN UNCHANGED clientVars ELSE ClientApply

Next == TrackStep /\ TrackAsk /\ TrackRestore /\ TrackLost /\ ClientStep

Spec == Init /\ [][Next]_vars

\* #818 review: liveness. Once an ask has begun, its machinery keeps moving (prompt, capture, recorder exit, the
\* player reaping, the restore) unless something else changes the state; nothing waits forever.
Progress(A) == A /\ UNCHANGED <<prevHeld, notice>> /\ optq' = optq \ {r \in Reads : st'[r] \in Live} /\ TrackAsk
               /\ TrackRestore /\ TrackLost /\ ClientStep
FairSpec == Spec /\ WF_vars(Progress(AskPromptStart)) /\ WF_vars(Progress(AskPromptEnd)) /\ WF_vars(Progress(MicOpen))
                 /\ WF_vars(Progress(CaptureEnd)) /\ WF_vars(Progress(RecorderExit)) /\ WF_vars(Progress(AskRestore))
                 /\ WF_vars(Progress(AskRelease))
                 /\ WF_vars(Progress(Reap))

TypeOK == /\ st \in [Reads -> {"queued", "preparing", "playing", "paused", "seeking", "parked", "ended"}]
          /\ players \subseteq Reads \cup {Prompt} /\ exiting \subseteq Reads \cup {Prompt}

(* Each invariant names the bug it prevents. *)

\* "Pause sometimes jumps back": a resume lands exactly on the word that was heard, never earlier.
ResumeExact == \A r \in Reads : resumedAt[r] # NoPos => resumedAt[r] = mark[r]

\* Two voices at once (a new read or the ask prompt over a player still exiting).
OneAudible == Cardinality(players \cup exiting) <= 1

\* "A second voice_ask over a paused read didn't resume": an ask parks at most one read and,
\* once the ask is over, no read is left parked (it was restored or explicitly stopped).
AskParksOne == /\ Cardinality({r \in Reads : st[r] = "parked"}) <= 1
               /\ (parked # None => st[parked] = "parked")
               /\ (ask = "none" => \A r \in Reads : st[r] # "parked")

\* The mic never records our own audio: no player (or exiting player) while the mic or recorder is open.
MicExclusive == (mic \/ recorder) => Quiet

\* "Wrong clock": the teleprompter word is the audio word, within one word event.
TeleTracksAudio == \A r \in Reads : st[r] \in Positioned => Dist(tele, cur[r]) <= 1

\* #818 review: a read an ask parked is eventually restored (or explicitly ended); it is never left parked forever.
ParkedEventuallyReleased == \A r \in Reads : [](st[r] = "parked" => <>(st[r] # "parked"))

\* "Overlap": exactly one session owns the screen.
OneLiveSession == Cardinality({r \in Reads : st[r] \in Live}) <= 1

\* Etan's ruling: dedupe the active read, whether playing or paused; never queue it behind
\* itself; the queue never holds a read that is on screen.
NoSameQueued == \A r \in optq : st[r] \notin Live

\* Lane B night item 3: the read an ask found on screen (preparing included) stays parked for the whole ask; the ask
\* never cancels it. Only the ask's restore or a Stop releases it.
AskKeepsRead == askFound # None => st[askFound] = "parked"

\* Statechart gap 2: an ask never touches the narration queue; a queued read leaves it only by going live.
QueueSurvivesAsk == ~lost

\* Statechart gap 5 (capture-end r2): while the ask's answer transcribes, the only read on screen is the one it
\* restored; the next queued read waits for the ask to release.
SuccessorWaitsForRelease == ask = "transcribing" => \A r \in Reads : st[r] \in Positioned => r = restoring

\* 2.4 teleprompter freeze (V3-5, M4 03:28:48.842-.849): the previous-read return delivers the held read's restore
\* receipt, so until something else moves that read the client shows it, paused, at the word the engine stored.
RestoreReceiptApplied == restored # None =>
                           /\ cOwner = restored /\ cPhase = "paused" /\ cWord = pausedAt[restored]

\* V3-5 "the finished replay remains playing; pause does nothing": once the held read is back, the client no longer
\* shows (or targets controls at) the replay that return ended. Stronger than "not shown running": not owned at all.
EndedReplayNotShownRunning == retReplay # None => cOwner # retReplay

\* A stopped or replaced session never starts a player.
NoZombie == /\ \A r \in Reads : r \in players => st[r] = "playing"
            /\ (Prompt \in players => ask = "prompt")
=============================================================================
