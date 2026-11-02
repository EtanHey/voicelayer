------------------------------- MODULE F5Pause -------------------------------
(* One current read, one waiting read and one capture. Fixed projects the lane-F
   contract; ~Fixed projects the router/player/UI defects, not an executable replay.
   Fault flips one semantic guard for the config's named property. No audio. *)
EXTENDS Naturals, Sequences
CONSTANTS Fixed, PauseBeforeOpen, ResumeOnEveryEnd, SpeechLen, MaxSpeeches, Fault
(* Diagnostic ghost record names the temporal discharge predicate in TLC 2.19
   traces: that version prints an anonymous temporal-error headline. *)
VARIABLES speech, pos, pausedAt, owner, capture, queued, started, pendingPause,
          f5Saw, stopInCapture, resumes, endOwner, event, held, releaseHadRead,
          shownQueued, timing, obligations
vars == <<speech, pos, pausedAt, owner, capture, queued, started, pendingPause,
          f5Saw, stopInCapture, resumes, endOwner, event, held, releaseHadRead,
          shownQueued, timing, obligations>>

(* Two audio ticks per word let TLC distinguish an arbitrary millisecond cursor
   from a word index. Pausing rewinds to the start of the containing word: no tail
   or word is discarded. SpeechLen is also the end-of-read boundary sentinel. *)
WordAt(p) == p \div 2
Boundary(p) == 2 * WordAt(p)
PausePosition(p) == IF Fixed /\ Fault # "WordBoundary" THEN Boundary(p) ELSE p
ResumePosition == IF Fault = "ResumePosition" THEN 0 ELSE IF Fixed THEN 2 * pausedAt ELSE pos
Live == speech \in {"preparing", "playing", "paused"}
Outcomes == {"pasted", "empty", "failed", "cancelled", "timeout"}
EndEvents == {"end_" \o o : o \in Outcomes}
ResumeEvents == {"end_" \o o \o "_auto_resume" : o \in Outcomes}
F5Edges == {"f5_hold_ignored", "f5_tap_stops", "f5_auto_pause_then_open"}
(* This is the published snapshot, independent of the true waiting count. The
   current code tags the preparing job is_current:false (tts.ts emitQueueSnapshot).
   The slot and the one waiting request share the same lifetime as the F5 pause. *)
QueueDisplay(q, phase) == q + IF phase = "preparing" /\ (~Fixed \/ Fault = "QueueCount") THEN 1 ELSE 0
Keep(v) == UNCHANGED v

Init == speech = "none" /\ pos = 0 /\ pausedAt = 0 /\ owner = "none"
        /\ capture = "idle" /\ queued = 0 /\ started = 0 /\ pendingPause = FALSE
        /\ f5Saw = "none" /\ stopInCapture = FALSE /\ resumes = 0
        /\ endOwner = "none" /\ event = "init" /\ held = "no"
        /\ releaseHadRead = FALSE /\ shownQueued = 0 /\ timing = "none"
        /\ obligations = [AutoPauseNeverStuck |-> TRUE]

NewSpeech ==
  /\ started < MaxSpeeches + (IF Fault = "TypeBound" THEN 1 ELSE 0)
  /\ IF capture = "idle" /\ ~Live
       THEN /\ speech' = "preparing" /\ pos' = 0 /\ owner' = "none"
            /\ timing' = "none" /\ shownQueued' = QueueDisplay(queued, "preparing")
            /\ event' = "prepare_speech" /\ Keep(<<queued, pausedAt>>)
       ELSE /\ queued = 0 /\ (capture = "idle" \/ Fixed)
            /\ queued' = 1 /\ shownQueued' = QueueDisplay(1, speech)
            /\ event' = "queue_speech" /\ Keep(<<speech, pos, owner, pausedAt, timing>>)
  /\ started' = started + 1
  /\ Keep(<<capture, pendingPause, f5Saw, stopInCapture, resumes, endOwner, held, releaseHadRead>>)

StartPlayback ==
  /\ speech = "preparing" /\ capture = "idle"
  /\ speech' = "playing" /\ shownQueued' = queued /\ event' = "start_playback"
  /\ timing' = IF timing = "none" /\ Fixed /\ Fault # "TimingBlank" THEN "estimate" ELSE timing
  /\ Keep(<<pos, pausedAt, owner, capture, queued, started, pendingPause, f5Saw,
            stopInCapture, resumes, endOwner, held, releaseHadRead>>)

TimingArrives ==
  /\ Live /\ timing # "real" /\ timing' = "real" /\ event' = "timing_arrives"
  /\ Keep(<<speech, pos, pausedAt, owner, capture, queued, started, pendingPause,
            f5Saw, stopInCapture, resumes, endOwner, held, releaseHadRead, shownQueued>>)

Tick ==
  /\ speech = "playing"
  /\ IF pos < 2 * SpeechLen
       THEN pos' = pos + 1 /\ speech' = speech /\ event' = "tick"
       ELSE pos' = pos /\ speech' = "done" /\ event' = "speech_done"
  /\ Keep(<<pausedAt, owner, capture, queued, started, pendingPause, f5Saw,
            stopInCapture, resumes, endOwner, held, releaseHadRead, shownQueued, timing>>)

Dequeue ==
  /\ queued = 1 /\ ~Live /\ capture = "idle"
  /\ speech' = "preparing" /\ pos' = 0 /\ owner' = "none" /\ queued' = 0
  /\ shownQueued' = QueueDisplay(0, "preparing") /\ timing' = "none" /\ event' = "dequeue"
  /\ Keep(<<pausedAt, capture, started, pendingPause, f5Saw, stopInCapture,
            resumes, endOwner, held, releaseHadRead>>)

UserPause ==
  \/ /\ speech = "playing" /\ capture = "idle"
     /\ speech' = "paused" /\ pausedAt' = WordAt(pos) /\ pos' = PausePosition(pos)
     /\ owner' = "user" /\ event' = "user_pause"
     /\ Keep(<<capture, queued, started, pendingPause, f5Saw, stopInCapture,
               resumes, endOwner, held, releaseHadRead, shownQueued, timing>>)
  \/ /\ Fixed /\ capture # "idle" /\ speech = "paused" /\ owner = "f5"
     /\ owner' = "user" /\ event' = "user_pause_converts"
     /\ Keep(<<speech, pos, pausedAt, capture, queued, started, pendingPause, f5Saw,
               stopInCapture, resumes, endOwner, held, releaseHadRead, shownQueued, timing>>)

UserPlay ==
  /\ speech = "paused" /\ capture = "idle"
  /\ speech' = "playing" /\ pos' = ResumePosition /\ owner' = "none" /\ event' = "user_play"
  /\ Keep(<<pausedAt, capture, queued, started, pendingPause, f5Saw, stopInCapture,
            resumes, endOwner, held, releaseHadRead, shownQueued, timing>>)

(* Speech-scoped Stop differs from F5 release/capture-stop. It clears waiting reads. *)
UserStop ==
  /\ Live /\ (capture = "idle" \/ Fixed)
  /\ speech' = "stopped" /\ owner' = "none" /\ queued' = 0 /\ shownQueued' = 0
  /\ pendingPause' = FALSE /\ stopInCapture' = (capture # "idle")
  /\ event' = IF capture = "idle" THEN "user_stop" ELSE "stop_in_capture"
  /\ Keep(<<pos, pausedAt, capture, started, f5Saw, resumes, endOwner, held, releaseHadRead, timing>>)

StartCapture(spoke, g) ==
  /\ capture' = "recording" /\ resumes' = 0 /\ stopInCapture' = FALSE
  /\ f5Saw' = spoke /\ held' = IF g = "hold" THEN "hold" ELSE IF g = "double" THEN "locked" ELSE "no"

F5(g) ==
  /\ capture = "idle"
  /\ CASE speech \in {"preparing", "playing"} /\ (~Fixed \/ Fault = "IgnoreF5") ->
            /\ (IF g = "hold"
              THEN /\ f5Saw' = speech /\ held' = "hold" /\ event' = "f5_hold_ignored"
                   /\ Keep(<<speech, owner>>)
              ELSE /\ f5Saw' = speech /\ held' = IF g = "double" THEN "locked" ELSE "no"
                   /\ speech' = "stopped" /\ owner' = "none" /\ event' = "f5_tap_stops")
            /\ Keep(<<pos, pausedAt, capture, pendingPause, stopInCapture, resumes>>)
       [] speech = "playing" /\ Fixed /\ PauseBeforeOpen ->
            /\ StartCapture("playing", g) /\ speech' = "paused"
            /\ pausedAt' = WordAt(pos) /\ pos' = PausePosition(pos) /\ owner' = "f5"
            /\ event' = "f5_auto_pause_then_open" /\ Keep(pendingPause)
       [] speech = "playing" /\ Fixed /\ ~PauseBeforeOpen ->
            /\ StartCapture("playing", g) /\ pendingPause' = TRUE /\ event' = "f5_open_then_pause"
            /\ Keep(<<speech, pos, pausedAt, owner>>)
       [] OTHER ->
            /\ StartCapture(IF speech = "paused" THEN "paused" ELSE "empty", g)
            /\ event' = "f5_record" /\ Keep(<<speech, pos, pausedAt, owner, pendingPause>>)
  /\ Keep(<<queued, started, endOwner, releaseHadRead, shownQueued, timing>>)

LatePause ==
  /\ pendingPause /\ speech = "playing"
  /\ speech' = "paused" /\ pausedAt' = WordAt(pos) /\ pos' = PausePosition(pos)
  /\ owner' = "f5" /\ pendingPause' = FALSE /\ event' = "late_auto_pause"
  /\ Keep(<<capture, queued, started, f5Saw, stopInCapture, resumes, endOwner,
            held, releaseHadRead, shownQueued, timing>>)

(* A physical hold-end is separately reachable even when today's hold-start was
   ignored. This reproduces R2-01: hold -> ignored -> release -> handleStop. *)
HoldRelease ==
  /\ held # "no"
  /\ (capture = "recording" \/ (capture = "idle" /\ speech \in {"preparing", "playing"} /\ ~Fixed))
  /\ held' = "no" /\ releaseHadRead' = Live /\ event' = "hold_release"
  /\ IF (~Fixed /\ capture = "idle") \/ Fault = "ReleaseDrops"
       THEN /\ speech' = "stopped" /\ owner' = "none" /\ capture' = capture
       ELSE /\ capture' = IF held = "locked" THEN capture ELSE "transcribing"
            /\ Keep(<<speech, owner>>)
  /\ Keep(<<pos, pausedAt, queued, started, pendingPause, f5Saw, stopInCapture,
            resumes, endOwner, shownQueued, timing>>)

(* Second tap, VAD silence, or explicit capture stop; never the speech Stop. *)
CaptureStop ==
  /\ capture = "recording" /\ capture' = "transcribing" /\ event' = "capture_stop"
  /\ held' = "no" /\ releaseHadRead' = Live
  /\ Keep(<<speech, pos, pausedAt, owner, queued, started, pendingPause, f5Saw,
            stopInCapture, resumes, endOwner, shownQueued, timing>>)

F5Busy ==
  /\ capture = "transcribing" /\ event' = "f5_busy"
  /\ Keep(<<speech, pos, pausedAt, owner, capture, queued, started, pendingPause, f5Saw,
            stopInCapture, resumes, endOwner, held, releaseHadRead, shownQueued, timing>>)

EndCapture(o) ==
  /\ \/ capture = "transcribing" /\ o \in {"pasted", "empty", "failed", "cancelled"}
     \/ capture = "recording" /\ o \in {"cancelled", "timeout", "failed"}
  /\ capture' = "idle" /\ endOwner' = owner /\ pendingPause' = FALSE /\ held' = "no"
  /\ IF Fixed /\ (owner = "f5" \/ (Fault = "ManualResume" /\ owner = "user")
                                   \/ (Fault = "StopResumes" /\ stopInCapture))
              /\ (ResumeOnEveryEnd \/ o = "pasted")
       THEN /\ speech' = "playing" /\ pos' = ResumePosition
            /\ owner' = IF Fault = "KeepOwner" THEN owner ELSE "none"
            /\ resumes' = resumes + 1 /\ event' = "end_" \o o \o "_auto_resume"
       ELSE /\ event' = "end_" \o o /\ Keep(<<speech, pos, owner, resumes>>)
  /\ Keep(<<pausedAt, queued, started, f5Saw, stopInCapture, releaseHadRead, shownQueued, timing>>)

StaleEnd ==
  /\ capture = "idle" /\ f5Saw # "none" /\ event' = "stale_capture_end"
  /\ resumes' = IF Fault = "DoubleResume" /\ resumes = 1 THEN resumes + 1 ELSE resumes
  /\ Keep(<<speech, pos, pausedAt, owner, capture, queued, started, pendingPause, f5Saw,
            stopInCapture, endOwner, held, releaseHadRead, shownQueued, timing>>)

CaptureAdvance == CaptureStop \/ \E o \in Outcomes: EndCapture(o)
Observe(action) == action /\ obligations' = [AutoPauseNeverStuck |-> owner' # "f5"]
Next == Observe(NewSpeech \/ StartPlayback \/ TimingArrives \/ Tick \/ Dequeue \/ UserPause \/ UserPlay
            \/ UserStop \/ LatePause \/ HoldRelease \/ F5Busy \/ StaleEnd \/ CaptureAdvance
            \/ \E g \in {"tap", "hold", "double"}: F5(g))
(* Capture progress/timeout and a pending pause eventually settle; user actions,
   timing arrival and speech completion are never forced. *)
Spec == Init /\ [][Next]_vars /\ WF_vars(Observe(CaptureAdvance)) /\ WF_vars(Observe(LatePause))

TypeOK == speech \in {"none", "preparing", "playing", "paused", "done", "stopped"}
          /\ pos \in 0..(2 * SpeechLen) /\ pausedAt \in 0..SpeechLen
          /\ owner \in {"none", "user", "f5"} /\ capture \in {"idle", "recording", "transcribing"}
          /\ queued \in 0..1 /\ started \in 0..MaxSpeeches /\ resumes \in 0..2
          /\ shownQueued \in 0..2 /\ timing \in {"none", "estimate", "real"}
          /\ pendingPause \in BOOLEAN /\ held \in {"no", "hold", "locked"} /\ releaseHadRead \in BOOLEAN
          /\ stopInCapture \in BOOLEAN /\ endOwner \in {"none", "user", "f5"}
          /\ f5Saw \in {"none", "preparing", "playing", "paused", "empty"} /\ event \in STRING
          /\ obligations \in [{"AutoPauseNeverStuck"} -> BOOLEAN]
NoSpeechDuringOpenMic == capture # "idle" => speech # "playing"
F5PausesPlayingSpeech == f5Saw = "playing" /\ event \in F5Edges
                         => speech = "paused" /\ owner = "f5" /\ capture = "recording"
ManualPausePersists == endOwner = "user" /\ event \in (EndEvents \cup ResumeEvents)
                       => speech = "paused" /\ owner = "user"
NoF5PauseOutsideCapture == owner = "f5" => capture # "idle"
(* Checks the actual post-resume cursor, not merely the pre-resume parked state. *)
ResumeFromPausedPosition == event \in (ResumeEvents \cup {"user_play"}) => pos = 2 * pausedAt
NoDoubleResume == resumes <= 1
(* Includes auto-resume events so an erroneous resume cannot evade this check. *)
StopWins == stopInCapture /\ event \in (EndEvents \cup ResumeEvents) => speech # "playing"
OwnerConsistent == owner # "none" => speech = "paused"
ReleaseNeverDropsRead == event \in {"hold_release", "capture_stop"} /\ releaseHadRead => Live
PauseAtWordBoundary == speech = "paused" => pos = 2 * pausedAt
QueuedCountExcludesCurrent == shownQueued = queued
TimingNeverBlankWhilePlaying == speech = "playing" => timing \in {"estimate", "real"}
AutoPauseNeverStuck == (owner = "f5") ~> (owner # "f5")
=============================================================================
