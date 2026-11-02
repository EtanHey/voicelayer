-------------------------- MODULE RuntimeSetup --------------------------
EXTENDS Naturals
CONSTANT Escalate
VARIABLES child, phase, cancelled
vars == <<child,phase,cancelled>>
Init == /\ child = "running" /\ phase = "setup" /\ cancelled = FALSE
Cancel == /\ phase = "setup" /\ ~cancelled
          /\ cancelled' = TRUE /\ child' = "ignores-term" /\ phase' = "joining"
Kill == /\ Escalate /\ cancelled /\ child = "ignores-term"
        /\ child' = "killed" /\ UNCHANGED <<phase,cancelled>>
Reap == /\ child = "killed" /\ phase = "joining"
        /\ child' = "exited" /\ UNCHANGED <<phase,cancelled>>
Cleanup == /\ child = "exited" /\ phase = "joining"
           /\ phase' = "cleaned" /\ UNCHANGED <<child,cancelled>>
Next == Cancel \/ Kill \/ Reap \/ Cleanup
Spec == Init /\ [][Next]_vars /\ WF_vars(Kill) /\ WF_vars(Reap) /\ WF_vars(Cleanup)
CancellationFinishes == cancelled ~> phase = "cleaned"
CleanupAfterExit == phase = "cleaned" => child = "exited"
=============================================================================
