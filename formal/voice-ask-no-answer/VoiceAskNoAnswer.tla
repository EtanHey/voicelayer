-------------------------- MODULE VoiceAskNoAnswer --------------------------
EXTENDS Naturals
CONSTANTS Deadline, GraceLimit, SilenceLimit, CancelOnSpeech, GuardPending,
          BoundStall, EnableNoAnswerClose, KeepRecording, SpeechCap, LockedClose
VARIABLES wall, budget, silence, grace, held, spoken, heard, pending, frameSpeech,
          stalled, closed, cause, kept
vars == <<wall, budget, silence, grace, held, spoken, heard, pending, frameSpeech,
          stalled, closed, cause, kept>>
Min(a,b) == IF a < b THEN a ELSE b
Init == /\ wall = 0 /\ budget = 0 /\ silence = 0 /\ grace = 0
        /\ held \in BOOLEAN /\ spoken = FALSE /\ heard = FALSE /\ pending = FALSE
        /\ frameSpeech = FALSE /\ stalled = FALSE /\ closed = FALSE
        /\ cause = "none" /\ kept = FALSE
Tick == /\ ~closed
        /\ wall' = Min(wall + 1, 5) /\ silence' = Min(silence + 1, SilenceLimit)
        /\ budget' = IF ~held /\ (~heard \/ ~CancelOnSpeech)
                      THEN Min(budget + 1, Deadline) ELSE budget
        /\ grace' = IF pending /\ budget = Deadline THEN Min(grace + 1, GraceLimit) ELSE grace
        /\ UNCHANGED <<held, spoken, heard, pending, frameSpeech, stalled, closed, cause, kept>>
\* A captured frame can arrive ON the deadline, before its asynchronous classification.
Capture(speech) == /\ ~closed /\ ~pending
                   /\ pending' = TRUE /\ frameSpeech' = speech /\ spoken' = spoken \/ speech
                   /\ UNCHANGED <<wall, budget, silence, grace, held, heard, stalled, closed, cause, kept>>
Classify == /\ ~closed /\ pending /\ ~stalled
            /\ pending' = FALSE /\ heard' = heard \/ frameSpeech
            /\ silence' = IF frameSpeech THEN 0 ELSE silence
            /\ UNCHANGED <<wall, budget, grace, held, spoken, frameSpeech, stalled, closed, cause, kept>>
VadStall == /\ ~closed /\ pending /\ ~stalled /\ stalled' = TRUE
            /\ UNCHANGED <<wall, budget, silence, grace, held, spoken, heard, pending, frameSpeech, closed, cause, kept>>
End(reason) == /\ closed' = TRUE /\ cause' = reason /\ kept' = KeepRecording
               /\ UNCHANGED <<wall, budget, silence, grace, held, spoken, heard, pending, frameSpeech, stalled>>
NoAnswer == /\ EnableNoAnswerClose /\ ~closed /\ ~held /\ (~heard \/ ~CancelOnSpeech)
            /\ budget = Deadline /\ (~pending \/ ~GuardPending) /\ End("no-answer")
GraceClose == /\ BoundStall /\ ~closed /\ ~held /\ ~heard /\ pending
              /\ budget = Deadline /\ grace = GraceLimit /\ End("unclassified")
NormalSilence == /\ ~closed /\ ~held /\ heard /\ ~pending /\ silence = SilenceLimit /\ End("silence")
LockedSilence == /\ LockedClose /\ ~closed /\ held /\ ~pending /\ silence = SilenceLimit /\ End("silence")
CapClose == /\ SpeechCap /\ ~closed /\ heard /\ wall >= 3 /\ End("cap")
Next == Tick \/ (\E speech \in BOOLEAN: Capture(speech)) \/ Classify \/ VadStall \/
        NoAnswer \/ GraceClose \/ NormalSilence \/ LockedSilence \/ CapClose
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ SF_vars(NoAnswer) /\ SF_vars(GraceClose)
        /\ WF_vars(LockedSilence)
NoCutOffMidAnswer == (closed /\ cause = "no-answer") => ~heard
PendingSpeechProtected == (closed /\ cause = "no-answer") => ~spoken
NoAnswerCloses == ([](~spoken /\ ~held)) => <>closed
StalledVadCloses == (stalled /\ ~held /\ ~heard /\ ~closed) ~> closed
RecordingKept == closed => kept
NoSpeechCap == cause # "cap"
LockedSilenceCloses == (held /\ silence = SilenceLimit /\ ~pending /\ ~closed)
                      ~> (closed \/ pending \/ silence < SilenceLimit)
=============================================================================
