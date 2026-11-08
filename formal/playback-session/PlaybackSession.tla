------------------------------ MODULE PlaybackSession ------------------------------
(* Lane B (2.4): ONE explicit session machine for Option+F5 reads, voice_speak and
   voice_ask narration and the teleprompter. src/playback/session.ts implements
   exactly these states and events; src/__tests__/playback-session.test.ts replays
   the same transitions.

   Reads 1 and 2 are queued reads (2 follows 1, so "previous read" exists). Id 3 is
   the voice_ask prompt, which is audio too. Words are 0 .. W-1; cursor W means the
   read played past its last word (pausing exactly there is allowed).

   Positions are WORD INDICES held by the session, never a time re-derived from a
   client clock or a re-synthesised clip. `mark` is the ground truth: the word the
   listener was on when the read left the speaker. `pausedAt` is what the engine
   stored. A resume must land on `mark`. *)
EXTENDS Naturals, FiniteSets

CONSTANTS
  JumpBack,          \* pause stores a reset client clock (word 0): Etan's "pause jumps back"
  SkipReap,          \* audio starts before the previous player exited: two voices at once
  StrandOnFail,      \* an ask ends without restoring the read it parked: read lost after an ask
  ParkResumeAtZero,  \* an ask over a read still preparing its resume parks it at word 0 (second ask bug)
  OpenMicEarly,      \* the mic opens while the prompt player is still exiting
  SkipRecorderWait,  \* the read resumes before the recorder exited (capture-end r2)
  ClockReset,        \* resume/restore restarts the teleprompter clock at 0: wrong clock
  PrevKeepsCurrent,  \* "previous read" starts the old read without ending the current one: overlap
  ZombieReady,       \* a cancelled preparation still starts its player after Esc/Stop
  SameQueues,        \* Option+F5 on the text being read queues it again behind itself (Etan: dedupe and tell)
  NoRestore          \* the ask's end never restores the read it parked (liveness mutant)

Reads == {1, 2}
Prompt == 3
W == 2   \* two words keep Fixed at 275k states (teleprompter-handoff checks 677k); every mutant still trips
NoPos == 9
None == 0
Live == {"preparing", "playing", "paused", "seeking", "parked"}
Positioned == {"preparing", "playing", "paused", "seeking"}

VARIABLES st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, prep,
          ask, parked, parkedFrom, mic, recorder, asks, prevHeld, optq, notice
vars == <<st, cur, pausedAt, mark, resumedAt, seekTo, tele, players, exiting, prep,
          ask, parked, parkedFrom, mic, recorder, asks, prevHeld, optq, notice>>

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
        /\ optq = {} /\ notice = FALSE

\* Next queued read: read 2 only after read 1 ended.
Start(r) == /\ st[r] = "queued" /\ NoLive /\ ask = "none" /\ r # prevHeld
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
Pause(r) == /\ st[r] \in {"playing", "preparing"} /\ ask = "none"
            /\ st' = [st EXCEPT ![r] = "paused"]
            /\ mark' = [mark EXCEPT ![r] = cur[r]]
            /\ pausedAt' = [pausedAt EXCEPT ![r] = IF JumpBack THEN 0 ELSE cur[r]]
            /\ resumedAt' = [resumedAt EXCEPT ![r] = NoPos]
            /\ Leave(r)
            /\ UNCHANGED <<cur, seekTo, tele, prep, ask, parked, parkedFrom, mic, recorder, asks>>

Resume(r) == /\ st[r] = "paused" /\ ask = "none"
             /\ LET to == IF JumpBack THEN 0 ELSE pausedAt[r] IN
                /\ st' = [st EXCEPT ![r] = "preparing"]
                /\ cur' = [cur EXCEPT ![r] = to]
                /\ resumedAt' = [resumedAt EXCEPT ![r] = to]
                /\ tele' = IF ClockReset THEN 0 ELSE to
             /\ prep' = prep \cup {r}
             /\ UNCHANGED <<pausedAt, mark, seekTo, players, exiting, ask, parked, parkedFrom, mic, recorder, asks>>

\* Seek one word back or forward from a playing read.
Seek(r) == /\ st[r] = "playing" /\ ask = "none"
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
Esc(r) == /\ st[r] \in Positioned /\ ask = "none"
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

\* voice_ask preempts: whatever read is on screen is parked at its exact word.
AskPreempt == /\ ask = "none" /\ asks < 2
              /\ ask' = "waiting" /\ asks' = asks + 1
              /\ IF \E r \in Reads : st[r] \in Positioned
                 THEN \E r \in Reads :
                        /\ st[r] \in Positioned
                        /\ LET truth == CASE st[r] = "seeking" -> seekTo[r]
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

\* Ask end restores exactly the parked read, to its exact word, in the state it had.
AskRestore == /\ ask = "closing" /\ (~recorder \/ SkipRecorderWait) /\ ~NoRestore
              /\ ask' = "none" /\ parked' = None /\ parkedFrom' = "none"
              /\ IF parked = None \/ StrandOnFail
                 THEN UNCHANGED <<st, cur, resumedAt, tele, prep>>
                 ELSE LET p == parked IN
                      /\ st' = [st EXCEPT ![p] = IF parkedFrom = "paused" THEN "paused" ELSE "preparing"]
                      /\ cur' = [cur EXCEPT ![p] = pausedAt[p]]
                      /\ resumedAt' = [resumedAt EXCEPT ![p] = IF parkedFrom = "paused" THEN NoPos ELSE pausedAt[p]]
                      /\ tele' = IF ClockReset THEN 0 ELSE pausedAt[p]
                      /\ prep' = IF parkedFrom = "paused" THEN prep ELSE prep \cup {p}
              /\ UNCHANGED <<pausedAt, mark, seekTo, players, exiting, mic, recorder, asks>>

\* Stop: every positioned read ends and an ask in flight closes. The read an ask parked is
\* never lost: it survives and the ask's end restores it PAUSED at its word.
StopAll == /\ (\E r \in Reads : st[r] \in Positioned) \/ ask \notin {"none", "closing"}
           /\ st' = [r \in Reads |-> IF st[r] \in Positioned THEN "ended" ELSE st[r]]
           /\ players' = {} /\ exiting' = exiting \cup players
           /\ parkedFrom' = (IF parked # None THEN "paused" ELSE parkedFrom)
           /\ mic' = FALSE
           /\ ask' = IF ask = "none" THEN "none" ELSE "closing"
           /\ UNCHANGED <<cur, pausedAt, mark, resumedAt, seekTo, tele, prep, parked, recorder, asks>>

Others == \/ \E r \in Reads : Start(r) \/ Ready(r) \/ DropPrep(r) \/ Advance(r) \/ TeleSync(r) \/ End(r)
                              \/ Pause(r) \/ Resume(r) \/ Seek(r) \/ SeekDone(r) \/ Esc(r)
          \/ Reap \/ AskPreempt \/ AskPromptStart \/ AskPromptEnd \/ MicOpen
          \/ CaptureEnd \/ AskAbort \/ RecorderExit \/ AskRestore \/ StopAll

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

Next == \/ Others /\ UNCHANGED <<prevHeld, notice>>
           /\ optq' = optq \ {r \in Reads : st'[r] \in Live}
        \/ (PreviousRead \/ PrevReturn) /\ UNCHANGED notice /\ optq' = optq \ {r \in Reads : st'[r] \in Live}
        \/ OptF5Empty \/ OptF5Same \/ OptF5Other

Spec == Init /\ [][Next]_vars

\* #818 review: liveness. Once an ask has begun, its machinery keeps moving (prompt, capture, recorder exit, the
\* player reaping, the restore) unless something else changes the state; nothing waits forever.
Progress(A) == A /\ UNCHANGED <<prevHeld, notice>> /\ optq' = optq \ {r \in Reads : st'[r] \in Live}
FairSpec == Spec /\ WF_vars(Progress(AskPromptStart)) /\ WF_vars(Progress(AskPromptEnd)) /\ WF_vars(Progress(MicOpen))
                 /\ WF_vars(Progress(CaptureEnd)) /\ WF_vars(Progress(RecorderExit)) /\ WF_vars(Progress(AskRestore))
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

\* Etan: "if its on the same it should dedupe": the text being read (playing or paused) is never queued behind
\* itself; the queue never holds a read that is on screen.
NoSameQueued == \A r \in optq : st[r] \notin Live

\* A stopped or replaced session never starts a player.
NoZombie == /\ \A r \in Reads : r \in players => st[r] = "playing"
            /\ (Prompt \in players => ask = "prompt")
=============================================================================
