------------------------------- MODULE F5Pause -------------------------------
(* Lane F round 2. One Option+F5 read, two waiting requests, two capture identities.
   Readiness/audio decoding is abstracted: playing denotes logical read launch.
   Physical key ownership is independent of capture settlement. No product code. *)
EXTENDS Naturals, Sequences, FiniteSets, TLC
CONSTANTS Fixed, PauseBeforeOpen, ResumeOnEveryEnd, SpeechLen, MaxSpeeches,
          MaxCaptures, CaptureBound, Fault
VARIABLES s, pressPos, beforeRead, manualHold, f5Saw, transcribingBefore,
          issuedBefore, obligations
vars == <<s, pressPos, beforeRead, manualHold, f5Saw, transcribingBefore, issuedBefore, obligations>>
IDs == 1..MaxCaptures (* Total, never reused: pause/resume/pause/N6 needs a larger bound. *)
Active(caps) == {c \in IDs : caps[c] # "idle"}
Recording == {c \in IDs : s.caps[c] = "recording"}
Transcribing == {c \in IDs : s.caps[c] = "transcribing"}
Settled == Active(s.caps) = {}
Live == s.speech \in {"preparing", "playing", "paused", "parked_preparing"}
Parked == s.speech \in {"paused", "parked_preparing"}
WordAt(p) == p \div 2
Boundary(p) == 2 * WordAt(p)
ParkWord(p) == CASE Fault = "ParkZero" -> 0
                   [] Fault = "ParkNextWord" -> IF WordAt(p) < SpeechLen THEN WordAt(p) + 1 ELSE SpeechLen
                   [] OTHER -> WordAt(p)
ParkPosition(p) == IF Fault = "WordBoundary" \/ ~Fixed THEN p ELSE 2 * ParkWord(p)
Read == <<s.speech, s.pos, s.owner>>
Goal(read) == read.speech \in {"playing", "stopped"} \/ read.owner = "user"
Outcomes == {"pasted", "empty", "failed", "cancelled", "timeout"}
EndEvents == {"end_" \o o : o \in Outcomes}
F5Events == {"f5_pause", "f5_capture", "f5_open_first", "f5_hold_ignored", "f5_tap_stops", "f5_cancel_transcribing"}
ResumeEvents == {"end_" \o o \o "_auto_resume" : o \in Outcomes}
QueueDisplay(q, phase) == q + IF phase = "preparing" /\ (~Fixed \/ Fault = "QueueCount") THEN 1 ELSE 0
Timed(t) == IF t = "none" /\ Fixed /\ Fault # "TimingBlank" THEN "estimate" ELSE t
Key(g) == IF g = "hold" THEN "hold" ELSE IF g = "double" THEN "locked" ELSE "no"

Initial == [speech |-> "none", pos |-> 0, pausedAt |-> 0, owner |-> "none",
            caps |-> [c \in IDs |-> "idle"], age |-> [c \in IDs |-> 0], issued |-> 0,
            queued |-> 0, shownQueued |-> 0, started |-> 0, held |-> "no", keyCap |-> 0,
            pendingPause |-> FALSE, stopWon |-> FALSE, timing |-> "none",
            lastOutcome |-> "none", event |-> "init"]
Init == s = Initial /\ pressPos = 0 /\ beforeRead = <<>> /\ manualHold = FALSE
        /\ f5Saw = "none" /\ transcribingBefore = {} /\ issuedBefore = 0
        /\ obligations = [AutoPauseNeverStuck |-> FALSE]

(* Boundary replay: a target daemon has parked word 1 while take A transcribes;
   the CurrentCancelPostRelease config selects today's cancel/up-edge router. *)
CancelUpInit == s = [Initial EXCEPT !.speech = "paused", !.pos = 2, !.pausedAt = 1,
                     !.owner = "f5", !.caps[1] = "transcribing", !.issued = 1,
                     !.started = 1, !.timing = "real"]
                /\ pressPos = 3 /\ beforeRead = <<>> /\ manualHold = FALSE
                /\ f5Saw = "none" /\ transcribingBefore = {} /\ issuedBefore = 0
                /\ obligations = [AutoPauseNeverStuck |-> FALSE]

(* Current slot and waiting requests are separate. Three requests explore +2 queued. *)
NewSpeech ==
  /\ s.started < MaxSpeeches
  /\ IF Settled /\ ~Live
       THEN s' = [s EXCEPT !.speech = "preparing", !.pos = 0, !.pausedAt = 0, !.owner = "none",
                          !.timing = "none", !.shownQueued = QueueDisplay(s.queued, "preparing"),
                          !.started = @ + 1, !.stopWon = FALSE, !.event = "prepare_speech"]
       ELSE /\ s.queued < MaxSpeeches - 1 /\ (Settled \/ Fixed)
            /\ s' = [s EXCEPT !.queued = @ + 1, !.shownQueued = QueueDisplay(s.queued + 1, s.speech),
                               !.started = @ + 1, !.event = "queue_speech"]
StartPlayback ==
  /\ s.speech = "preparing" \/ (s.speech = "parked_preparing" /\ s.owner = "f5")
  /\ Settled \/ Fault = "StartDuringCapture"
  /\ s' = [s EXCEPT !.speech = "playing", !.pos = 0, !.owner = "none", !.shownQueued = s.queued,
                    !.timing = Timed(s.timing), !.event = "start_playback"]
TimingArrives ==
  /\ s.speech = "playing" /\ s.timing # "real"
  /\ s' = [s EXCEPT !.timing = "real", !.event = "timing_arrives"]
Tick ==
  /\ s.speech = "playing"
  /\ IF s.pos < 2 * SpeechLen
       THEN s' = [s EXCEPT !.pos = @ + 1, !.event = "tick"]
       ELSE s' = [s EXCEPT !.speech = "done", !.event = "speech_done"]
Dequeue ==
  /\ s.queued > 0 /\ ~Live /\ Settled
  /\ s' = [s EXCEPT !.speech = "preparing", !.pos = 0, !.pausedAt = 0, !.owner = "none",
                    !.queued = @ - 1, !.shownQueued = QueueDisplay(s.queued - 1, "preparing"),
                    !.timing = "none", !.stopWon = FALSE, !.event = "dequeue"]
UserPause ==
  \/ /\ s.speech \in {"playing", "preparing"} /\ Settled
     /\ s' = [s EXCEPT !.speech = IF s.speech = "preparing" THEN "parked_preparing" ELSE "paused",
                       !.pos = IF Fixed THEN Boundary(s.pos) ELSE s.pos, !.pausedAt = WordAt(s.pos),
                       !.owner = "user", !.event = "user_pause"]
  \/ /\ Fixed /\ ~Settled /\ Parked /\ s.owner = "f5"
     /\ s' = [s EXCEPT !.owner = "user", !.event = "user_pause_converts"]
UserPlay ==
  /\ Parked /\ Settled
  /\ s' = [s EXCEPT !.speech = "playing",
                    !.pos = IF Fault = "ResumePosition" THEN 0 ELSE IF Fixed THEN 2 * s.pausedAt ELSE s.pos,
                    !.owner = IF Fault = "KeepOwner" THEN "user" ELSE "none",
                    !.timing = Timed(s.timing), !.event = "user_play"]
UserStop ==
  /\ Live /\ (Settled \/ Fixed)
  /\ s' = [s EXCEPT !.speech = "stopped", !.owner = "none", !.queued = 0, !.shownQueued = 0,
                    !.pendingPause = FALSE, !.stopWon = ~Settled, !.event = "user_stop"]

Open(c, g) == [s EXCEPT !.caps[c] = "recording", !.age[c] = 0, !.issued = c,
                       !.held = Key(g), !.keyCap = IF Key(g) = "no" THEN 0 ELSE c, !.event = "f5_capture"]
ParkRead(opened) == [opened EXCEPT !.speech = IF s.speech = "preparing" THEN "parked_preparing" ELSE "paused",
                                  !.pos = ParkPosition(s.pos), !.pausedAt = ParkWord(s.pos),
                                  !.owner = IF Fault = "InvalidOwner" THEN "invalid" ELSE "f5",
                                  !.event = "f5_pause"]
(* Settlement changes a capture identity, never a physical key. Logical launch of
   a parked preparing read is atomic with the final settlement, with usable timing.
   No synthesis latency/word-timing accuracy is claimed by this abstraction. *)
Finish(c, o) == [s EXCEPT !.caps[c] = "idle", !.age[c] = 0, !.lastOutcome = o, !.event = "end_" \o o]
AfterFinish(ended, o) ==
  IF (s.owner = "f5" \/ (Fault = "ManualResume" /\ s.owner = "user")
                       \/ (Fault = "StopResumes" /\ s.stopWon))
     /\ (Active(ended.caps) = {} \/ Fault = "ResumeEarly")
     /\ (ResumeOnEveryEnd \/ o = "pasted")
  THEN [ended EXCEPT !.speech = IF Fault = "DropAtEnd" THEN "stopped" ELSE "playing",
                    !.pos = IF Fault = "ResumePosition" THEN 0 ELSE 2 * s.pausedAt,
                    !.owner = "none", !.timing = Timed(s.timing), !.pendingPause = FALSE,
                    !.event = "end_" \o o \o "_auto_resume"]
  ELSE ended

F5(g) ==
  /\ s.held = "no" /\ Recording = {}
  /\ IF Transcribing # {} /\ (~Fixed \/ Fault = "CancelPrevious" \/ Fault = "LegacyRouter")
       THEN LET c == CHOOSE c \in Transcribing : TRUE
                cancelled == AfterFinish(Finish(c, "cancelled"), "cancelled")
            IN s' = [cancelled EXCEPT !.held = Key(g), !.keyCap = IF Key(g) = "no" THEN 0 ELSE c,
                                     !.event = "f5_cancel_transcribing"]
       ELSE /\ s.issued < MaxCaptures
            /\ LET c == s.issued + 1
                   opened == Open(c, g)
               IN IF s.speech \in {"playing", "preparing"} /\
                     (~Fixed \/ Fault = "IgnoreF5" \/ (Fault = "IgnorePreparing" /\ s.speech = "preparing"))
                  THEN s' = [s EXCEPT !.held = Key(g), !.keyCap = 0,
                                     !.speech = IF g = "hold" THEN s.speech ELSE "stopped",
                                     !.owner = "none", !.event = IF g = "hold" THEN "f5_hold_ignored" ELSE "f5_tap_stops"]
                  ELSE IF s.speech \in {"playing", "preparing"}
                       THEN s' = IF PauseBeforeOpen THEN ParkRead(opened)
                                 ELSE [opened EXCEPT !.pendingPause = TRUE, !.event = "f5_open_first"]
                       ELSE s' = IF Fault = "N6DropsRead" /\ Transcribing # {} /\ Live
                                 THEN [opened EXCEPT !.speech = "stopped", !.owner = "none"] ELSE opened
LatePause ==
  /\ s.pendingPause /\ ~Settled /\ s.speech \in {"playing", "preparing"}
  /\ s' = [s EXCEPT !.speech = IF s.speech = "preparing" THEN "parked_preparing" ELSE "paused",
                    !.pos = Boundary(s.pos), !.pausedAt = WordAt(s.pos), !.owner = "f5",
                    !.pendingPause = FALSE, !.event = "late_pause"]
HoldRelease ==
  /\ s.held # "no"
  /\ LET released == [s EXCEPT !.held = "no", !.keyCap = 0, !.event = "hold_release"]
         stoppedCapture == IF s.keyCap \in IDs /\ s.caps[s.keyCap] = "recording" /\ s.held # "locked"
                           THEN [released EXCEPT !.caps[s.keyCap] = "transcribing", !.age[s.keyCap] = 0]
                           ELSE released
         drops == Live /\ (Fault = "ReleaseDrops" \/
                  ((~Fixed \/ Fault = "PostRelease" \/ Fault = "LegacyRouter") /\ Settled /\ ~Parked))
     IN s' = IF drops THEN [stoppedCapture EXCEPT !.speech = "stopped", !.owner = "none"] ELSE stoppedCapture
CaptureStop(c) ==
  /\ c \in Recording /\ s.held = "no"
  /\ s' = [s EXCEPT !.caps[c] = "transcribing", !.age[c] = 0, !.event = "capture_stop"]
EndCapture(c, o) ==
  /\ c \in Active(s.caps)
  /\ (s.caps[c] = "transcribing" \/ o \in {"failed", "cancelled", "timeout"})
  /\ (o # "timeout" \/ s.age[c] = CaptureBound)
  /\ s' = AfterFinish(Finish(c, o), o)
StaleEnd(c) ==
  /\ c <= s.issued /\ s.caps[c] = "idle"
  /\ s' = IF Settled /\ ((Fault = "DoubleResume" /\ Parked) \/
                            (Fault = "StaleResumesPaused" /\ s.speech = "paused"))
          THEN [s EXCEPT !.speech = "playing", !.pos = 2 * s.pausedAt, !.owner = "none",
                         !.timing = Timed(s.timing), !.event = "stale_capture_end"]
          ELSE [s EXCEPT !.event = "stale_capture_end"]
Clock ==
  /\ \E c \in Active(s.caps): s.age[c] < CaptureBound
  /\ s' = [s EXCEPT !.age = [c \in IDs |-> IF c \in Active(s.caps) THEN CaptureBound ELSE 0], !.event = "clock"]
Timeout(c) == EndCapture(c, "timeout")

(* Diagnostic ghosts observe the pre-state, never the mutant's chosen parked word.
   They retain no unnecessary history outside the event that needs a snapshot. *)
Observe(action) ==
  /\ action
  /\ pressPos' = IF s'.event \in {"prepare_speech", "dequeue"} THEN 0
                 ELSE IF s'.event = "user_pause" \/
                         (s'.event \in F5Events /\ s.speech \in {"playing", "preparing"}) THEN s.pos ELSE pressPos
  /\ beforeRead' = IF s'.event \in ({"hold_release", "stale_capture_end"} \cup EndEvents \cup ResumeEvents)
                     \/ (s'.event \in F5Events /\ Transcribing # {}) THEN Read ELSE <<>>
  /\ manualHold' = IF s'.event \in {"user_pause", "user_pause_converts"} THEN TRUE
                   ELSE IF s'.event \in {"user_play", "user_stop"} THEN FALSE ELSE manualHold
  /\ f5Saw' = IF s'.event \in F5Events THEN s.speech ELSE "none"
  /\ transcribingBefore' = IF s'.event \in F5Events THEN Transcribing ELSE {}
  /\ issuedBefore' = IF s'.event \in F5Events THEN s.issued ELSE 0
  /\ obligations' = [AutoPauseNeverStuck |-> Goal(s')]
NormalNext == Observe(NewSpeech \/ StartPlayback \/ TimingArrives \/ Tick \/ Dequeue \/ UserPause \/ UserPlay
                \/ UserStop \/ LatePause \/ HoldRelease \/ Clock
                \/ (\E g \in {"hold", "tap", "double"}: F5(g))
                \/ (\E c \in IDs: CaptureStop(c) \/ StaleEnd(c) \/ (\E o \in Outcomes: EndCapture(c, o))))
(* OpenFirst reverses the ordering inside one handler. Its wrong open-mic frame
   remains reachable; the handler's pause continuation then quiesces playback
   before unrelated actions. Fixed never enters this deliberately broken phase. *)
Next == IF s.pendingPause THEN Observe(LatePause) ELSE NormalNext
(* Clock and deadline callbacks progress; a transcription hang is explicitly ended
   by the per-identity deadline. No fairness on user input or ordinary settlement. *)
(* PTT deadline fairness is a liveness assumption, not a cutoff while speaking; VAD needs its own assumption. *)
Fair == (IF Fault = "NoFairness" THEN TRUE ELSE WF_vars(Observe(Clock)))
        /\ \A c \in IDs: WF_vars(Observe(Timeout(c)))
Spec == Init /\ [][Next]_vars /\ Fair
SpecCancelUp == CancelUpInit /\ [][Next]_vars /\ Fair

TypeOK == s.speech \in {"none", "preparing", "playing", "paused", "parked_preparing", "done", "stopped"}
          /\ s.pos \in 0..(2 * SpeechLen) /\ s.pausedAt \in 0..SpeechLen /\ pressPos \in 0..(2 * SpeechLen)
          /\ s.owner \in {"none", "user", "f5"} /\ s.caps \in [IDs -> {"idle", "recording", "transcribing"}]
          /\ s.age \in [IDs -> 0..CaptureBound] /\ s.issued \in 0..MaxCaptures
          /\ s.queued \in 0..(MaxSpeeches - 1) /\ s.shownQueued \in 0..MaxSpeeches
          /\ s.started \in 0..MaxSpeeches /\ s.held \in {"no", "hold", "locked"} /\ s.keyCap \in 0..MaxCaptures
          /\ s.timing \in {"none", "estimate", "real"} /\ manualHold \in BOOLEAN
          /\ s.stopWon \in BOOLEAN /\ s.pendingPause \in BOOLEAN /\ s.event \in STRING
NoSpeechDuringOpenMic == ~Settled => s.speech # "playing" (* Includes transcribing captures under D-S4. *)
F5PausesPlayingSpeech == f5Saw = "playing" /\ s.event \in F5Events
                         => s.speech = "paused" /\ s.owner = "f5" /\ Recording # {}
F5HoldsPreparingRead == f5Saw = "preparing" /\ s.event \in F5Events
                       => s.speech = "parked_preparing" /\ s.owner = "f5" /\ Recording # {}
F5DuringTranscriptionStartsCapture == s.event \in F5Events /\ transcribingBefore # {}
                                     => transcribingBefore \subseteq Transcribing /\ s.issued = issuedBefore + 1
                                        /\ s.caps[s.issued] = "recording" /\ Read = beforeRead
ManualPausePersists == manualHold => Parked /\ s.owner = "user"
NoF5PauseOutsideCapture == s.owner = "f5" => ~Settled
ResumeFromPausedPosition ==
  /\ (s.event \in (ResumeEvents \cup {"user_play"}) => s.speech = "playing" /\ s.pos = Boundary(pressPos))
  /\ IF s.event \in (EndEvents \cup ResumeEvents) /\ Settled
        THEN (beforeRead[3] = "f5" => s.speech = "playing" /\ s.owner = "none" /\ s.pos = Boundary(pressPos))
        ELSE TRUE
NoDoubleResume == s.event = "stale_capture_end" \/
                  (s.event \in (EndEvents \cup ResumeEvents) /\ ~Settled) => Read = beforeRead
StopWins == s.stopWon => s.speech = "stopped"
OwnerConsistent == (s.owner # "none" => Parked) /\ (s.owner = "user" => manualHold)
ReleaseNeverDropsRead == s.event = "hold_release" => Read = beforeRead
PauseAtWordBoundary == Parked => s.pos = Boundary(pressPos) /\ s.pausedAt = WordAt(pressPos)
QueuedCountExcludesCurrent == s.shownQueued = s.queued
TimingNeverBlankWhilePlaying == s.speech = "playing" => s.timing \in {"estimate", "real"}
AutoPauseNeverStuck == (s.owner = "f5") ~> Goal(s)

(* TLC -continue stops its invariant list at the first false invariant in each
   successor. This constraint never filters: PrintT returns TRUE. It evaluates
   every actual predicate so later failures cannot be mislabeled as survivors. *)
CrossDiagnostics ==
  /\ (TypeOK \/ PrintT("CrossKill:TypeOK"))
  /\ (NoSpeechDuringOpenMic \/ PrintT("CrossKill:NoSpeechDuringOpenMic"))
  /\ (F5PausesPlayingSpeech \/ PrintT("CrossKill:F5PausesPlayingSpeech"))
  /\ (ManualPausePersists \/ PrintT("CrossKill:ManualPausePersists"))
  /\ (NoF5PauseOutsideCapture \/ PrintT("CrossKill:NoF5PauseOutsideCapture"))
  /\ (ResumeFromPausedPosition \/ PrintT("CrossKill:ResumeFromPausedPosition"))
  /\ (NoDoubleResume \/ PrintT("CrossKill:NoDoubleResume"))
  /\ (StopWins \/ PrintT("CrossKill:StopWins"))
  /\ (OwnerConsistent \/ PrintT("CrossKill:OwnerConsistent"))
  /\ (ReleaseNeverDropsRead \/ PrintT("CrossKill:ReleaseNeverDropsRead"))
  /\ (PauseAtWordBoundary \/ PrintT("CrossKill:PauseAtWordBoundary"))
  /\ (QueuedCountExcludesCurrent \/ PrintT("CrossKill:QueuedCountExcludesCurrent"))
  /\ (TimingNeverBlankWhilePlaying \/ PrintT("CrossKill:TimingNeverBlankWhilePlaying"))
  /\ (F5HoldsPreparingRead \/ PrintT("CrossKill:F5HoldsPreparingRead"))
  /\ (F5DuringTranscriptionStartsCapture \/ PrintT("CrossKill:F5DuringTranscriptionStartsCapture"))
=============================================================================
