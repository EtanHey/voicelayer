-------------------- MODULE SelectionSnapshotStartup --------------------
EXTENDS Naturals
CONSTANTS SharedBudget, SkipStartupBound, SkipReadBound, AcceptInvalid, BreakType
VARIABLES phase, time, readyAt, startupDelay, workDelay, valid, delivered
vars == <<phase, time, readyAt, startupDelay, workDelay, valid, delivered>>
StartupBudget == 4
ReadBudget == 2
StartupDeadline == IF SharedBudget THEN ReadBudget ELSE StartupBudget
ReadDeadline == IF SharedBudget THEN ReadBudget ELSE readyAt + ReadBudget

Init == /\ phase = "startup" /\ time = 0 /\ readyAt = 0
        /\ startupDelay \in 0..5 /\ workDelay \in 0..3
        /\ valid \in BOOLEAN /\ delivered = FALSE

\* One tick abstracts scheduler/loader delay, then promised-data read and exit.
\* Readiness is emitted before the first pasteboard access in runIfRequested.
Startup == /\ phase = "startup"
           /\ IF time = startupDelay /\ (SkipStartupBound \/ time < StartupDeadline)
                 THEN /\ phase' = IF BreakType THEN "invalid" ELSE "snapshot"
                      /\ readyAt' = time /\ UNCHANGED time
                 ELSE IF ~SkipStartupBound /\ time >= StartupDeadline
                      THEN /\ phase' = "done" /\ UNCHANGED <<time, readyAt>>
                      ELSE /\ time' = time + 1 /\ UNCHANGED <<phase, readyAt>>
           /\ UNCHANGED <<startupDelay, workDelay, valid, delivered>>
Snapshot == /\ phase = "snapshot"
            /\ IF time - readyAt = workDelay /\ (SkipReadBound \/ time < ReadDeadline)
                  THEN /\ phase' = "done" /\ delivered' = (valid \/ AcceptInvalid)
                       /\ UNCHANGED time
                  ELSE IF ~SkipReadBound /\ time >= ReadDeadline
                       THEN /\ phase' = "done" /\ UNCHANGED <<time, delivered>>
                       ELSE /\ time' = time + 1 /\ UNCHANGED <<phase, delivered>>
            /\ UNCHANGED <<readyAt, startupDelay, workDelay, valid>>
Next == Startup \/ Snapshot \/ (phase = "done" /\ UNCHANGED vars)
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"startup", "snapshot", "done"}
          /\ time \in 0..8 /\ readyAt \in 0..5
          /\ startupDelay \in 0..5 /\ workDelay \in 0..3
          /\ valid \in BOOLEAN /\ delivered \in BOOLEAN
StartupBound == phase # "startup" \/ time <= StartupBudget
ReadBound == phase # "snapshot" \/ time <= readyAt + ReadBudget
ValidDelivery == ~delivered \/ valid
\* Spec eligibility is independent of the implementation's deadline choice.
ColdDelivery == phase # "done" \/ ~(valid /\ startupDelay < StartupBudget /\ workDelay < ReadBudget)
                \/ delivered
=============================================================================
