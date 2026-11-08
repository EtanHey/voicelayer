----------------------- MODULE PttSilenceTimeout -----------------------
EXTENDS Naturals, Sequences
CONSTANT Policy
VARIABLE s
vars == <<s>>
\* Frames are "word" (speech), "quiet" (silence) or "aside": what the mic hears while the take is paused.
\* `said` and `quiet`, `owed` are spec ghosts: the frames the user is owed, the unpaused quiet minutes, and
\* the one tail frame (~200 ms) still owed after a Pause click. Everything else is the implementation.
Init == s = [phase |-> "recording", speech |-> FALSE, silence |-> 0, quiet |-> 0,
             wall |-> 0, event |-> "init", endedBy |-> "none",
             paused |-> FALSE, grace |-> 0, owed |-> 0, spanOpen |-> FALSE, spans |-> 0,
             pcm |-> <<>>, said |-> <<>>, saved |-> <<>>, text |-> <<>>]
\* One timer step is one minute. Wall age is only a saturated observation monitor.
SilenceDeadline == 10
ObservationLimit == 20
PcmBound == 4
SpanBound == 2
MinSilence(n) == IF n > SilenceDeadline THEN SilenceDeadline ELSE n
Keep(seq, frame) == IF Len(seq) < PcmBound THEN Append(seq, frame) ELSE seq
Frame(spoken) ==
  /\ s.phase = "recording"
  /\ LET owedFrame == ~s.paused \/ s.owed > 0
         admitted == ~s.paused \/ s.grace > 0 \/ Policy = "appendWhilePaused"
         frame == IF ~owedFrame THEN "aside" ELSE IF spoken THEN "word" ELSE "quiet"
     IN s' = [s EXCEPT !.pcm = IF admitted THEN Keep(@, frame) ELSE @,
                       !.said = IF owedFrame THEN Keep(@, frame) ELSE @,
                       !.grace = IF s.paused /\ @ > 0 THEN @ - 1 ELSE @,
                       !.owed = IF s.paused /\ @ > 0 THEN @ - 1 ELSE @,
                       !.speech = IF admitted THEN spoken ELSE @,
                       !.event = IF ~admitted THEN "gated" ELSE IF spoken THEN "speech" ELSE "silence",
                       !.silence = IF admitted /\ spoken /\ Policy # "noRenewal" THEN 0 ELSE @,
                       !.quiet = IF owedFrame /\ spoken THEN 0 ELSE @]
\* A paused minute is neither silence nor speech: the deadline clock stands still.
Tick == /\ s.phase = "recording"
        /\ s' = [s EXCEPT !.wall = IF @<ObservationLimit + 1 THEN @+1 ELSE @, !.event="tick",
                          !.speech = IF s.paused THEN @ ELSE FALSE,
                          !.silence = IF s.paused /\ Policy # "pauseCounts" THEN @ ELSE MinSilence(@ + 1),
                          !.quiet = IF s.paused THEN @ ELSE MinSilence(@ + 1)]
Timeout == /\ s.phase = "recording"
           /\ Policy # "noTimeout"
           /\ (~s.paused \/ Policy = "timeoutWhilePaused")
           /\ IF Policy = "wall" THEN s.wall >= 2 ELSE
                 (~s.speech /\ s.silence = SilenceDeadline) \/ (Policy = "cap" /\ s.wall >= ObservationLimit)
           /\ s' = [s EXCEPT !.phase = "ended", !.event="end", !.endedBy = "timeout",
                             !.saved = IF Policy = "dropArchive" THEN <<>> ELSE s.pcm]
\* The click keeps one more frame (~200 ms) so a word in flight is not clipped.
Pause == /\ s.phase = "recording" /\ ~s.paused /\ s.spans < SpanBound
         /\ s' = [s EXCEPT !.paused = TRUE, !.grace = IF Policy = "clip" THEN 0 ELSE 1, !.owed = 1,
                           !.spanOpen = TRUE, !.spans = @ + 1, !.event = "pause"]
Resume == /\ s.phase = "recording" /\ s.paused
          /\ s' = [s EXCEPT !.paused = FALSE, !.grace = 0, !.owed = 0, !.spanOpen = FALSE, !.event = "resume",
                            !.pcm = IF Policy = "newTake" THEN <<>> ELSE @]
\* Stop and Cancel end the take from either state; every take, cancelled too, is archived whole.
Finish(how) == /\ s.phase = "recording"
               /\ (~s.paused \/ Policy # "noStopWhilePaused")
               /\ s' = [s EXCEPT !.phase = IF how = "cancel" THEN "cancelled" ELSE "ended", !.event = "end",
                                 !.endedBy = how, !.saved = s.pcm, !.paused = FALSE, !.grace = 0, !.owed = 0,
                                 !.spanOpen = IF Policy = "openSpan" THEN @ ELSE FALSE]
Transcribe == /\ s.phase = "ended" /\ Policy # "stall"
              /\ s' = [s EXCEPT !.phase = "transcribed", !.event="transcribe",
                                !.text = IF Policy = "trim" /\ Len(s.pcm) > 0
                                         THEN SubSeq(s.pcm, 1, Len(s.pcm) - 1) ELSE s.pcm]
Next == (\E spoken \in BOOLEAN: Frame(spoken)) \/ Tick \/ Timeout \/ Pause \/ Resume
        \/ Finish("stop") \/ Finish("cancel") \/ Transcribe
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(Timeout) /\ WF_vars(Transcribe)
NoTimeoutDuringSpeech == s.endedBy = "timeout" => ~s.speech /\ s.silence = SilenceDeadline
EveryEndedTakeRetained == s.phase # "recording" => s.saved = s.pcm
RawAccurate == s.phase = "transcribed" => s.text = s.pcm
SettlesAfterSilence == s.phase = "ended" ~> s.phase = "transcribed"
SpeechRenewsDeadline == s.event="speech" => s.silence=0
RecurringSpeechNeverTimesOut == (s.phase="recording" /\ (s.speech \/ s.silence < SilenceDeadline)) => ~ENABLED Timeout
\* A paused take is not silent, so only unpaused silence owes a timeout.
SilenceTimesOut == (s.phase="recording" /\ ~s.paused /\ ~s.speech /\ s.silence=SilenceDeadline)
                  ~> (s.phase # "recording" \/ s.speech \/ s.paused)
\* Pause/resume (Etan 2026-11-08): nothing the mic hears while paused reaches the take...
NoPausedAudio == \A i \in 1..Len(s.pcm): s.pcm[i] # "aside"
\* ...and everything said while not paused, plus the click's tail, stays in the same take.
UnpausedRetained == s.pcm = s.said
\* Paused time never counts toward the silence deadline, and no timeout fires during a pause.
NoTimeoutDuringPause == s.endedBy = "timeout" => ~s.paused /\ s.quiet = SilenceDeadline
StopCancelFromPaused == s.phase = "recording" => ENABLED Finish("stop") /\ ENABLED Finish("cancel")
\* Every paused span is closed in the metadata once the take ends.
PausedSpansClosed == s.phase # "recording" => ~s.spanOpen
=============================================================================
