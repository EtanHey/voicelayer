--------------------------- MODULE FirstInstall ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS AllowLive, IgnoreEvidence, BadRecord, SkipBootstrap, ReplaceExisting
VARIABLES gate, participants, evidence, mutex, phase, created, creation,
          scenario, available
vars == <<gate, participants, evidence, mutex, phase, created, creation,
          scenario, available>>

(* The external process sample is outside G1. The Create action abstracts its
   successful stopped-owner recheck followed by G1's exclusive publication.
   A legacy process can launch independently: this is a sampled proof, not an
   OS-wide prohibition on launching applications. The race scenario lets an
   owner appear between setup's initial check and its mutex-protected recheck. *)
Init ==
  /\ scenario \in {"fresh", "legacy258", "live", "race", "corrupt", "lock", "diag", "ledger", "controller"}
  /\ gate = IF scenario = "corrupt" THEN "UNKNOWN" ELSE "ABSENT"
  /\ participants = (scenario = "live")
  /\ evidence = (scenario \in {"lock", "diag", "ledger", "controller"})
  /\ mutex = FALSE
  /\ phase = "check"
  /\ created = FALSE
  /\ creation = [absent |-> FALSE, stopped |-> FALSE, clean |-> FALSE, held |-> FALSE, generation |-> 0]
  /\ available = FALSE

Acquire == /\ phase = "check"
           /\ mutex' = TRUE /\ phase' = "locked"
           /\ UNCHANGED <<gate, participants, evidence, created, creation, scenario, available>>
Arrive == /\ scenario = "race" /\ phase = "locked" /\ ~participants
          /\ participants' = TRUE
          /\ UNCHANGED <<gate, evidence, mutex, phase, created, creation, scenario, available>>
Create == /\ phase = "locked" /\ ~SkipBootstrap
          /\ (gate = "ABSENT" \/ ReplaceExisting)
          /\ (~participants \/ AllowLive)
          /\ (~evidence \/ IgnoreEvidence)
          /\ created' = TRUE /\ gate' = "OPEN"
          /\ creation' = [absent |-> gate = "ABSENT", stopped |-> ~participants,
                          clean |-> ~evidence, held |-> mutex,
                          generation |-> IF BadRecord THEN 1 ELSE 0]
          /\ phase' = "restoring"
          /\ UNCHANGED <<participants, evidence, mutex, scenario, available>>
Refuse == /\ phase = "locked"
          /\ (gate # "ABSENT" \/ participants \/ evidence \/ SkipBootstrap)
          /\ phase' = "restoring"
          /\ UNCHANGED <<gate, participants, evidence, mutex, created, creation, scenario, available>>
Restore == /\ phase = "restoring" /\ phase' = "done" /\ mutex' = FALSE
           /\ available' = TRUE
           /\ UNCHANGED <<gate, participants, evidence, created, creation, scenario>>
Next == Acquire \/ Arrive \/ Create \/ Refuse \/ Restore
Spec == Init /\ [][Next]_vars /\ WF_vars(Acquire) /\ WF_vars(Create) /\ WF_vars(Refuse) /\ WF_vars(Restore)

BootstrapOnlyQuiescent == created => creation.stopped
BootstrapPreservesEvidence == created => creation.clean
BootstrapExclusiveCreate == created => (creation.absent /\ creation.held)
BootstrapOpenGenerationZero == created => creation.generation = 0
FreshInstallCompletes == (scenario \in {"fresh", "legacy258"}) ~> (created /\ available /\ phase = "done" /\ gate = "OPEN")
=============================================================================
