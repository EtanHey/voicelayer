-------------------------- MODULE VoiceAskNoAnswer --------------------------
EXTENDS Naturals
CONSTANTS Deadline, CancelOnSpeech, EnableNoAnswerClose, KeepRecording
VARIABLES elapsed, heard, armed, closed, cause, kept
vars == <<elapsed, heard, armed, closed, cause, kept>>

Init == /\ elapsed = 0 /\ heard = FALSE /\ armed = TRUE
        /\ closed = FALSE /\ cause = "none" /\ kept = FALSE
Tick == /\ ~closed /\ elapsed < Deadline
        /\ elapsed' = elapsed + 1
        /\ UNCHANGED <<heard, armed, closed, cause, kept>>
Speech == /\ ~closed /\ ~heard /\ elapsed < Deadline
          /\ heard' = TRUE /\ armed' = ~CancelOnSpeech
          /\ UNCHANGED <<elapsed, closed, cause, kept>>
NoAnswer == /\ EnableNoAnswerClose /\ ~closed /\ armed /\ elapsed = Deadline
            /\ closed' = TRUE /\ kept' = KeepRecording /\ cause' = "no-answer"
            /\ UNCHANGED <<elapsed, heard, armed>>
NormalSilence == /\ ~closed /\ heard
                 /\ closed' = TRUE /\ kept' = KeepRecording /\ cause' = "silence"
                 /\ UNCHANGED <<elapsed, heard, armed>>
Next == Tick \/ Speech \/ NoAnswer \/ NormalSilence
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(NoAnswer)

\* Only the no-answer rule is prohibited after speech; normal silence is allowed.
NoCutOffMidAnswer == (closed /\ cause = "no-answer") => ~heard
NoAnswerCloses == ([]~heard) => <>closed
RecordingKept == closed => kept
=============================================================================
