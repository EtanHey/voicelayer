-------------------------- MODULE ArchiveGateEvidence --------------------------
EXTENDS Naturals
CONSTANTS KeepPartial, RecordBeforeCommit, ClearOnSuccess, DetailOnTranscribed
VARIABLES phase, transcribed, storedRemoval, notTranscribedDetail, hasText, removed
vars == <<phase, transcribed, storedRemoval, notTranscribedDetail, hasText, removed>>

Init == /\ phase = "ready" /\ transcribed \in BOOLEAN /\ storedRemoval \in BOOLEAN
        /\ notTranscribedDetail = FALSE /\ hasText = FALSE /\ removed = FALSE
Begin == /\ phase = "ready" /\ phase' = "before"
         /\ hasText' \in BOOLEAN /\ removed' \in BOOLEAN
         /\ UNCHANGED <<transcribed, storedRemoval, notTranscribedDetail>>

\* Gate facts are independent of whether any real transcript words survive.
EligibleRemoval == removed /\ (~hasText \/ KeepPartial)
RecordRemoval == /\ storedRemoval' = TRUE
                 /\ notTranscribedDetail' = (~transcribed \/ DetailOnTranscribed)
                 /\ UNCHANGED transcribed
MaybeRecord == IF EligibleRemoval THEN RecordRemoval
               ELSE UNCHANGED <<transcribed, storedRemoval, notTranscribedDetail>>
Before == /\ phase = "before" /\ phase' = "commit"
          /\ (IF RecordBeforeCommit THEN MaybeRecord
              ELSE UNCHANGED <<transcribed, storedRemoval, notTranscribedDetail>>)
          /\ UNCHANGED <<hasText, removed>>
\* Both transcript writers clear old diagnostics before the new gate record.
Commit == /\ phase = "commit" /\ phase' = "record"
          /\ transcribed' = (transcribed \/ hasText)
          /\ storedRemoval' = (IF hasText /\ ClearOnSuccess THEN FALSE ELSE storedRemoval)
          /\ notTranscribedDetail' = (IF hasText THEN FALSE ELSE notTranscribedDetail)
          /\ UNCHANGED <<hasText, removed>>
After == /\ phase = "record" /\ phase' = "done"
         /\ (IF ~RecordBeforeCommit THEN MaybeRecord
             ELSE UNCHANGED <<transcribed, storedRemoval, notTranscribedDetail>>)
         /\ UNCHANGED <<hasText, removed>>
Retry == /\ phase = "done" /\ phase' = "ready"
         /\ UNCHANGED <<transcribed, storedRemoval, notTranscribedDetail, hasText, removed>>
Next == Begin \/ Before \/ Commit \/ After \/ Retry
Spec == Init /\ [][Next]_vars

FinalTranscriptEvidence == (phase = "done" /\ hasText) => storedRemoval = removed
NoFailureDetailOnTranscript == transcribed => ~notTranscribedDetail
=============================================================================
