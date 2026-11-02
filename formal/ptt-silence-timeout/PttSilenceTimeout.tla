----------------------- MODULE PttSilenceTimeout -----------------------
EXTENDS Naturals, Sequences
CONSTANT Policy
VARIABLE s
vars == <<s>>
Init == s = [phase |-> "recording", speech |-> FALSE, silence |-> 0,
             wall |-> 0, pcm |-> <<>>, saved |-> <<>>, text |-> <<>>]
MinCap(n) == IF n > 2 THEN 2 ELSE n
Frame(spoken) == /\ s.phase = "recording" /\ Len(s.pcm) < 4
                 /\ s' = [s EXCEPT !.speech = spoken, !.pcm = Append(@, spoken),
                                   !.silence = IF spoken THEN 0 ELSE @]
Tick == /\ s.phase = "recording"
        /\ s' = [s EXCEPT !.wall = MinCap(@ + 1), !.speech = FALSE,
                          !.silence = MinCap(@ + 1)]
Timeout == /\ s.phase = "recording"
           /\ IF Policy = "wall" THEN s.wall = 2 ELSE ~s.speech /\ s.silence = 2
           /\ s' = [s EXCEPT !.phase = "ended",
                             !.saved = IF Policy = "dropArchive" THEN <<>> ELSE s.pcm]
Transcribe == /\ s.phase = "ended" /\ Policy # "stall"
              /\ s' = [s EXCEPT !.phase = "transcribed",
                                !.text = IF Policy = "trim" /\ Len(s.pcm) > 0
                                         THEN SubSeq(s.pcm, 1, Len(s.pcm) - 1) ELSE s.pcm]
Next == (\E spoken \in BOOLEAN: Frame(spoken)) \/ Tick \/ Timeout \/ Transcribe
Spec == Init /\ [][Next]_vars /\ WF_vars(Timeout) /\ WF_vars(Transcribe)
NoTimeoutDuringSpeech == s.phase # "recording" => ~s.speech /\ s.silence = 2
EveryEndedTakeRetained == s.phase # "recording" => s.saved = s.pcm
RawAccurate == s.phase = "transcribed" => s.text = s.pcm
SettlesAfterSilence == s.phase = "ended" ~> s.phase = "transcribed"
=============================================================================
