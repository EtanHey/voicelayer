----------------------- MODULE PttSilenceTimeout -----------------------
EXTENDS Naturals, Sequences
CONSTANT Policy
VARIABLE s
vars == <<s>>
Init == s = [phase |-> "recording", speech |-> FALSE, silence |-> 0,
             wall |-> 0, event |-> "init", pcm |-> <<>>, saved |-> <<>>, text |-> <<>>]
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
           /\ s' = [s EXCEPT !.phase = "ended", !.event="end",
                             !.saved = IF Policy = "dropArchive" THEN <<>> ELSE s.pcm]
Transcribe == /\ s.phase = "ended" /\ Policy # "stall"
              /\ s' = [s EXCEPT !.phase = "transcribed", !.event="transcribe",
                                !.text = IF Policy = "trim" /\ Len(s.pcm) > 0
                                         THEN SubSeq(s.pcm, 1, Len(s.pcm) - 1) ELSE s.pcm]
Next == (\E spoken \in BOOLEAN: Frame(spoken)) \/ Tick \/ Timeout \/ Transcribe
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(Timeout) /\ WF_vars(Transcribe)
NoTimeoutDuringSpeech == s.phase # "recording" => ~s.speech /\ s.silence = SilenceDeadline
EveryEndedTakeRetained == s.phase # "recording" => s.saved = s.pcm
RawAccurate == s.phase = "transcribed" => s.text = s.pcm
SettlesAfterSilence == s.phase = "ended" ~> s.phase = "transcribed"
SpeechRenewsDeadline == s.event="speech" => s.silence=0
RecurringSpeechNeverTimesOut == (s.phase="recording" /\ (s.speech \/ s.silence < SilenceDeadline)) => ~ENABLED Timeout
SilenceTimesOut == (s.phase="recording" /\ ~s.speech /\ s.silence=SilenceDeadline)
                  ~> (s.phase # "recording" \/ s.speech)
=============================================================================
