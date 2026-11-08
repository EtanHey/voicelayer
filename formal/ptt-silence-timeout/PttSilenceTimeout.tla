----------------------- MODULE PttSilenceTimeout -----------------------
EXTENDS Naturals, Sequences
CONSTANT Policy
VARIABLE s
vars == <<s>>
\* BARE-STOP (2026-11-08): a take starts "opening" (record accepted, mic not yet open). A control that
\* arrives then is buffered and applied when the mic opens. `endedBy` records what ended the take.
Init == s = [phase |-> "opening", speech |-> FALSE, silence |-> 0,
             wall |-> 0, event |-> "init", pcm |-> <<>>, saved |-> <<>>, text |-> <<>>,
             buffered |-> "none", endedBy |-> "none"]
Open == /\ s.phase = "opening"
        /\ s' = IF s.buffered = "none" THEN [s EXCEPT !.phase = "recording", !.event = "open"]
                ELSE [s EXCEPT !.phase = "ended", !.event = "open", !.endedBy = s.buffered, !.saved = s.pcm]
\* The take's own stop: F5/side button, Stop button or PTT release, carrying its take id.
ScopedStop == /\ s.phase \in {"opening", "recording"}
              /\ s' = IF s.phase = "opening" THEN [s EXCEPT !.buffered = "scoped", !.event = "scoped-stop"]
                      ELSE [s EXCEPT !.phase = "ended", !.event = "scoped-stop", !.endedBy = "scoped", !.saved = s.pcm]
\* A stop with no take id (speak --stop, a read Stop, Hide over speech). Fixed: it stops speech only.
\* "unscopedEndsCapture" is the pre-fix redirect of a bare stop onto the live take (socket-handlers hasF5Capture
\* stamping); "openingFallback" is the pre-fix opening fallback (f5-capture bufferOpeningCaptureControl).
UnscopedStop ==
  /\ s.phase \in {"opening", "recording"}
  /\ s' = IF Policy = "unscopedEndsCapture" /\ s.phase = "recording"
            THEN [s EXCEPT !.phase = "ended", !.event = "unscoped-stop", !.endedBy = "unscoped", !.saved = s.pcm]
          ELSE IF Policy = "openingFallback" /\ s.phase = "opening" /\ s.buffered = "none"
            THEN [s EXCEPT !.buffered = "unscoped", !.event = "unscoped-stop"]
          ELSE [s EXCEPT !.event = "speech-stop"]
\* One timer step is one minute. Wall age is only a saturated observation monitor.
SilenceDeadline == 10
ObservationLimit == 20
MinSilence(n) == IF n > SilenceDeadline THEN SilenceDeadline ELSE n
Frame(spoken) == /\ s.phase = "recording"
                 /\ s' = [s EXCEPT !.speech = spoken, !.pcm = IF Len(@)<4 THEN Append(@, spoken) ELSE @,
                                   !.event = IF spoken THEN "speech" ELSE "silence",
                                   !.silence = IF spoken /\ Policy # "noRenewal" THEN 0 ELSE @]
Tick == /\ s.phase = "recording"
        /\ s' = [s EXCEPT !.wall = IF @<ObservationLimit + 1 THEN @+1 ELSE @, !.speech = FALSE, !.event="tick",
                          !.silence = MinSilence(@ + 1)]
Timeout == /\ s.phase = "recording"
           /\ Policy # "noTimeout"
           /\ IF Policy = "wall" THEN s.wall >= 2 ELSE
                 (~s.speech /\ s.silence = SilenceDeadline) \/ (Policy = "cap" /\ s.wall >= ObservationLimit)
           /\ s' = [s EXCEPT !.phase = "ended", !.event="end", !.endedBy = "timeout",
                             !.saved = IF Policy = "dropArchive" THEN <<>> ELSE s.pcm]
Transcribe == /\ s.phase = "ended" /\ Policy # "stall"
              /\ s' = [s EXCEPT !.phase = "transcribed", !.event="transcribe",
                                !.text = IF Policy = "trim" /\ Len(s.pcm) > 0
                                         THEN SubSeq(s.pcm, 1, Len(s.pcm) - 1) ELSE s.pcm]
Next == (\E spoken \in BOOLEAN: Frame(spoken)) \/ Tick \/ Timeout \/ Transcribe \/ Open \/ ScopedStop \/ UnscopedStop
Spec == Init /\ [][Next]_vars /\ WF_vars(Open) /\ WF_vars(Tick) /\ WF_vars(Timeout) /\ WF_vars(Transcribe)
NoTimeoutDuringSpeech == s.endedBy = "timeout" => ~s.speech /\ s.silence = SilenceDeadline
\* BARE-STOP: only the take's own scoped stop or its silence timeout ends a dictation capture.
UnscopedStopNeverEndsCapture == s.endedBy \in {"none", "scoped", "timeout"}
EveryEndedTakeRetained == s.phase # "recording" => s.saved = s.pcm
RawAccurate == s.phase = "transcribed" => s.text = s.pcm
SettlesAfterSilence == s.phase = "ended" ~> s.phase = "transcribed"
SpeechRenewsDeadline == s.event="speech" => s.silence=0
RecurringSpeechNeverTimesOut == (s.phase="recording" /\ (s.speech \/ s.silence < SilenceDeadline)) => ~ENABLED Timeout
SilenceTimesOut == (s.phase="recording" /\ ~s.speech /\ s.silence=SilenceDeadline)
                  ~> (s.phase # "recording" \/ s.speech)
=============================================================================
