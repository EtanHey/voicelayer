------------------------------- MODULE F5Pause -------------------------------
(* F5 over an Option+F5 speech (lane F5-PAUSE, phase 1). One speech slot, one waiting request, one capture.
   Fixed = FALSE projects today's VoiceBar router + daemon; Fixed = TRUE is the lead's contract (rows 1-6 of
   docs.local/n2c-push/F5PAUSE-TLA-BRIEF.md). PauseBeforeOpen and ResumeOnEveryEnd only matter when Fixed;
   each has a deliberately broken cfg so the invariant it protects is not vacuous. No audio, no product code. *)
EXTENDS Naturals, Sequences
CONSTANTS Fixed, PauseBeforeOpen, ResumeOnEveryEnd, SpeechLen, MaxSpeeches
VARIABLES speech,      \* "none" | "playing" | "paused" | "done" | "stopped"
          pos,         \* playback position of the speech in the slot, 0..SpeechLen
          pausedAt,    \* position recorded when the speech was paused
          owner,       \* who paused it: "none" | "user" | "f5"
          capture,     \* "idle" | "recording" | "transcribing"
          queued,      \* 0..1 speech request waiting behind the slot
          started,     \* speeches started so far (state bound)
          pendingPause,\* Fixed /\ ~PauseBeforeOpen: mic is open and the auto-pause has not landed yet
          f5Saw,       \* what the last F5 press found: "none" | "playing" | "paused" | "empty"
          stopInCapture,\* a Stop / Option+F5 stop landed during this capture
          resumes,     \* F5 auto-resumes since this capture started
          endOwner,    \* owner when the capture ended
          event
vars == <<speech, pos, pausedAt, owner, capture, queued, started, pendingPause, f5Saw, stopInCapture, resumes, endOwner, event>>

Live == speech \in {"playing", "paused"}
Outcomes == {"pasted", "empty", "failed", "cancelled", "timeout"}

Init == speech = "none" /\ pos = 0 /\ pausedAt = 0 /\ owner = "none" /\ capture = "idle" /\ queued = 0
        /\ started = 0 /\ pendingPause = FALSE /\ f5Saw = "none" /\ stopInCapture = FALSE /\ resumes = 0
        /\ endOwner = "none" /\ event = "init"

Keep(v) == UNCHANGED v

(* Option+F5 / agent speech with new text. Idle slot: it plays. Live slot, no capture: it waits (SelectionReadQueue
   append). During a capture: today the daemon rejects speak_text (socket-handlers.ts:269); Fixed queues it behind
   the paused read, which is a contract choice, not today's rule. *)
NewSpeech ==
  /\ started < MaxSpeeches
  /\ IF capture = "idle" /\ ~Live
       THEN /\ speech' = "playing" /\ pos' = 0 /\ owner' = "none" /\ started' = started + 1 /\ event' = "speak"
            /\ Keep(<<queued, pausedAt>>)
       ELSE /\ queued = 0 /\ (capture = "idle" \/ Fixed)
            /\ queued' = 1 /\ started' = started + 1 /\ event' = "queue_speech"
            /\ Keep(<<speech, pos, owner, pausedAt>>)
  /\ Keep(<<capture, pendingPause, f5Saw, stopInCapture, resumes, endOwner>>)

Tick ==
  /\ speech = "playing"
  /\ IF pos < SpeechLen THEN pos' = pos + 1 /\ speech' = speech /\ event' = "tick"
                  ELSE pos' = pos /\ speech' = "done" /\ event' = "speech_done"
  /\ Keep(<<pausedAt, owner, capture, queued, started, pendingPause, f5Saw, stopInCapture, resumes, endOwner>>)

(* The waiting request starts only after the slot is free and no capture owns the voice. *)
Dequeue ==
  /\ queued = 1 /\ ~Live /\ capture = "idle"
  /\ speech' = "playing" /\ pos' = 0 /\ owner' = "none" /\ queued' = 0 /\ event' = "dequeue"
  /\ Keep(<<pausedAt, capture, started, pendingPause, f5Saw, stopInCapture, resumes, endOwner>>)

(* Pause button. Today it is removed while recording (VoiceState/BarView); Fixed shows it during a capture, where it
   converts an F5 auto-pause into the user's own pause (row 6). *)
UserPause ==
  \/ /\ speech = "playing" /\ capture = "idle"
     /\ speech' = "paused" /\ pausedAt' = pos /\ owner' = "user" /\ event' = "user_pause"
     /\ Keep(<<pos, capture, queued, started, pendingPause, f5Saw, stopInCapture, resumes, endOwner>>)
  \/ /\ Fixed /\ capture # "idle" /\ speech = "paused" /\ owner = "f5"
     /\ owner' = "user" /\ event' = "user_pause_converts"
     /\ Keep(<<speech, pos, pausedAt, capture, queued, started, pendingPause, f5Saw, stopInCapture, resumes, endOwner>>)

(* Play: idle only; the daemon rejects resume while a capture owns the voice (socket-handlers.ts resume case). *)
UserPlay ==
  /\ speech = "paused" /\ capture = "idle"
  /\ speech' = "playing" /\ pos' = pausedAt /\ owner' = "none" /\ event' = "user_play"
  /\ Keep(<<pausedAt, capture, queued, started, pendingPause, f5Saw, stopInCapture, resumes, endOwner>>)

(* Stop button, or Option+F5 on the same text (selection admission = Stop). Stop means stop: it clears the
   waiting request too. Today a Stop during a capture is aimed at the capture, so only Fixed has the in-capture
   branch, where the stop wins and nothing resumes (row 4). *)
UserStop ==
  /\ Live /\ (capture = "idle" \/ Fixed)
  /\ speech' = "stopped" /\ owner' = "none" /\ queued' = 0 /\ pendingPause' = FALSE
  /\ stopInCapture' = (capture # "idle") /\ event' = IF capture = "idle" THEN "user_stop" ELSE "stop_in_capture"
  /\ Keep(<<pos, pausedAt, capture, started, f5Saw, resumes, endOwner>>)

StartCapture(spoke) ==
  /\ capture' = "recording" /\ resumes' = 0 /\ stopInCapture' = FALSE /\ f5Saw' = spoke

(* Any capture-starting F5 gesture: tap, hold or double (double = tap + lock, same opening edge). *)
F5(g) ==
  /\ capture = "idle"
  /\ CASE speech = "playing" /\ ~Fixed ->
            \* VoiceBarCommandRouter: hold-start in .speaking returns; single tap -> handleStop (suspend queue).
            IF g = "hold"
              THEN /\ f5Saw' = "playing" /\ event' = "f5_hold_ignored"
                   /\ Keep(<<speech, pos, pausedAt, owner, capture, queued, started, pendingPause, stopInCapture, resumes, endOwner>>)
              ELSE /\ f5Saw' = "playing" /\ speech' = "stopped" /\ owner' = "none" /\ event' = "f5_tap_stops"
                   /\ Keep(<<pos, pausedAt, capture, queued, started, pendingPause, stopInCapture, resumes, endOwner>>)
       [] speech = "playing" /\ Fixed /\ PauseBeforeOpen ->
            /\ StartCapture("playing") /\ speech' = "paused" /\ pausedAt' = pos /\ owner' = "f5"
            /\ event' = "f5_auto_pause_then_open"
            /\ Keep(<<pos, queued, started, pendingPause, endOwner>>)
       [] speech = "playing" /\ Fixed /\ ~PauseBeforeOpen ->
            /\ StartCapture("playing") /\ pendingPause' = TRUE /\ event' = "f5_open_then_pause"
            /\ Keep(<<speech, pos, pausedAt, owner, queued, started, endOwner>>)
       [] OTHER ->
            \* Paused (his own pause persists, today and Fixed) or nothing live: just record.
            /\ StartCapture(IF speech = "paused" THEN "paused" ELSE "empty")
            /\ event' = "f5_record"
            /\ Keep(<<speech, pos, pausedAt, owner, queued, started, pendingPause, endOwner>>)

LatePause ==
  /\ pendingPause /\ speech = "playing"
  /\ speech' = "paused" /\ pausedAt' = pos /\ owner' = "f5" /\ pendingPause' = FALSE /\ event' = "late_auto_pause"
  /\ Keep(<<pos, capture, queued, started, f5Saw, stopInCapture, resumes, endOwner>>)

(* Release / lock-tap / VAD silence ends the recording; the daemon transcribes. *)
CaptureStop ==
  /\ capture = "recording" /\ capture' = "transcribing" /\ event' = "capture_stop"
  /\ Keep(<<speech, pos, pausedAt, owner, queued, started, pendingPause, f5Saw, stopInCapture, resumes, endOwner>>)

(* F5 while transcribing: the daemon answers record with reject "busy" (row 5). Nothing may resume here. *)
F5Busy ==
  /\ capture = "transcribing" /\ event' = "f5_busy"
  /\ Keep(<<speech, pos, pausedAt, owner, capture, queued, started, pendingPause, f5Saw, stopInCapture, resumes, endOwner>>)

(* The capture fully ends: pasted, empty, failed, cancelled (from recording or transcribing; today's router maps
   F5 hold/tap during transcribing to Cancel), or timed out (recording only). Fixed resumes an F5-owned pause here
   and only here, from pausedAt (rows 1, 3). A user-owned pause stays paused (row 2). *)
EndCapture(o) ==
  /\ \/ capture = "transcribing" /\ o \in {"pasted", "empty", "failed", "cancelled"}
     \/ capture = "recording" /\ o \in {"cancelled", "timeout", "failed"}
  /\ capture' = "idle" /\ endOwner' = owner /\ pendingPause' = FALSE
  /\ IF Fixed /\ owner = "f5" /\ (ResumeOnEveryEnd \/ o = "pasted")
       THEN /\ speech' = "playing" /\ pos' = pausedAt /\ owner' = "none" /\ resumes' = resumes + 1
            /\ event' = "end_" \o o \o "_auto_resume"
       ELSE /\ event' = "end_" \o o /\ Keep(<<speech, pos, owner, resumes>>)
  /\ Keep(<<pausedAt, queued, started, f5Saw, stopInCapture>>)

(* A stale cancel/stop ack after the capture already ended (double F5, late daemon frame). Never resumes. *)
StaleEnd ==
  /\ capture = "idle" /\ f5Saw # "none" /\ event' = "stale_capture_end"
  /\ Keep(<<speech, pos, pausedAt, owner, capture, queued, started, pendingPause, f5Saw, stopInCapture, resumes, endOwner>>)

CaptureAdvance == CaptureStop \/ \E o \in Outcomes: EndCapture(o)

Next == NewSpeech \/ Tick \/ Dequeue \/ UserPause \/ UserPlay \/ UserStop \/ LatePause \/ F5Busy \/ StaleEnd
        \/ CaptureAdvance \/ \E g \in {"tap", "hold", "double"}: F5(g)

(* Fairness: a capture cannot last forever (3600 s timeout, transcription settles), and the daemon's late
   auto-pause, when modelled, eventually lands. Nothing is assumed about the user. *)
Spec == Init /\ [][Next]_vars /\ WF_vars(CaptureAdvance) /\ WF_vars(LatePause)

TypeOK == speech \in {"none", "playing", "paused", "done", "stopped"} /\ pos \in 0..SpeechLen /\ pausedAt \in 0..SpeechLen
          /\ owner \in {"none", "user", "f5"} /\ capture \in {"idle", "recording", "transcribing"} /\ queued \in 0..1
          /\ started \in 0..MaxSpeeches /\ resumes \in 0..2

(* Row 1: the speech never talks over an open mic or an in-flight transcription/paste. *)
NoSpeechDuringOpenMic == capture # "idle" => speech # "playing"
(* Row 1: an F5 press over a playing speech pauses it (owned by F5) and records; it never stops it or is ignored. *)
F5PausesPlayingSpeech == f5Saw = "playing" /\ event \in {"f5_hold_ignored", "f5_tap_stops", "f5_auto_pause_then_open"}
                         => (speech = "paused" /\ owner = "f5" /\ capture = "recording")
(* Row 2 and row 6: a user-owned pause survives the capture end. *)
ManualPausePersists == endOwner = "user" /\ event \in {"end_pasted", "end_empty", "end_failed", "end_cancelled", "end_timeout"}
                       => (speech = "paused" /\ owner = "user")
(* Row 3: an F5 pause exists only while its capture does; it is never left behind. *)
NoF5PauseOutsideCapture == owner = "f5" => capture # "idle"
(* Row 1: resume continues from the paused position. *)
ResumeFromPausedPosition == speech = "paused" => pos = pausedAt
(* Row 5: one capture resumes at most once. *)
NoDoubleResume == resumes <= 1
(* Row 4: a stop during the capture wins; nothing plays at its end. *)
StopWins == stopInCapture /\ event \in {"end_pasted", "end_empty", "end_failed", "end_cancelled", "end_timeout"}
            => speech # "playing"
(* Ownership is single-valued and consistent with the slot. *)
OwnerConsistent == owner # "none" => speech = "paused"

(* Liveness: an F5-paused speech eventually plays again, is stopped, or becomes the user's own pause. *)
AutoPauseNeverStuck == (owner = "f5") ~> (owner # "f5")
=============================================================================
