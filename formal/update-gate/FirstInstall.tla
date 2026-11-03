--------------------------- MODULE FirstInstall ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS AllowLive, IgnoreEvidence, BadRecord, SkipBootstrap, ReplaceExisting,
          SandboxedPostflight, LegacyAvailability, IgnoreUpgradeController
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

(* 2.2.58 keeps its OLD updater process while formula upgrade installs NEW
   dedupe/autostart scripts. Cask replacement stops VoiceBar first. Missing
   target/lease cannot authorize a new gated mutation. Compatibility instead
   calls setup availability, which never stops/moves bundles or changes a
   committed lease. A modern updater's live controller permits plists only
   until its owning finalizer starts the replacement.

   Availability success abstracts working host launchd/LaunchServices, NOT a
   claim that macOS cannot fail. SandboxedPostflight represents the observed
   Homebrew 7 denial. created records completion of the OLD updater's entire
   repair sequence, not just cask success; otherwise fixing A alone hides B. *)
UpgradeInit ==
  /\ scenario \in {"oldUpdater", "leaseOwner"}
  /\ gate = IF scenario = "leaseOwner" THEN "COMMITTED" ELSE "ABSENT"
  /\ mutex = (scenario = "leaseOwner")
  /\ available = (scenario = "oldUpdater")
  /\ phase = "formula"
  /\ participants = FALSE /\ evidence = FALSE /\ created = FALSE
  /\ creation = [absent |-> FALSE, stopped |-> FALSE, clean |-> FALSE, held |-> FALSE, generation |-> 0]
UpgradeFormula == /\ phase = "formula" /\ phase' = "cask"
                  /\ UNCHANGED <<gate, participants, evidence, mutex, created, creation, scenario, available>>
UpgradeCask == /\ phase = "cask" /\ phase' = "postflight" /\ available' = FALSE
               /\ UNCHANGED <<gate, participants, evidence, mutex, created, creation, scenario>>
UpgradePostflight ==
  /\ phase = "postflight" /\ phase' = "dedupe"
  /\ available' = ~SandboxedPostflight /\ (~mutex \/ IgnoreUpgradeController)
  /\ gate' = IF gate = "ABSENT" /\ ~SandboxedPostflight THEN "OPEN" ELSE gate
  /\ UNCHANGED <<participants, evidence, mutex, created, creation, scenario>>
UpgradeDedupe ==
  /\ phase = "dedupe"
  /\ phase' = IF mutex \/ LegacyAvailability THEN "autostart" ELSE "done"
  /\ available' = IF LegacyAvailability /\ ~mutex THEN TRUE ELSE available
  /\ gate' = IF LegacyAvailability /\ ~mutex /\ gate = "ABSENT" THEN "OPEN" ELSE gate
  /\ UNCHANGED <<participants, evidence, mutex, created, creation, scenario>>
UpgradeAutostart ==
  /\ phase = "autostart"
  /\ phase' = IF mutex THEN "ownerRestore" ELSE "done"
  /\ created' = ~mutex /\ LegacyAvailability
  /\ available' = IF LegacyAvailability /\ ~mutex THEN TRUE ELSE available
  /\ UNCHANGED <<gate, participants, evidence, mutex, creation, scenario>>
UpgradeOwnerRestore ==
  /\ phase = "ownerRestore" /\ phase' = "done"
  /\ mutex' = FALSE /\ available' = TRUE /\ created' = TRUE
  /\ UNCHANGED <<gate, participants, evidence, creation, scenario>>
UpgradeNext == UpgradeFormula \/ UpgradeCask \/ UpgradePostflight \/ UpgradeDedupe \/ UpgradeAutostart \/ UpgradeOwnerRestore
UpgradeSpec == UpgradeInit /\ [][UpgradeNext]_vars
               /\ WF_vars(UpgradeFormula) /\ WF_vars(UpgradeCask) /\ WF_vars(UpgradePostflight)
               /\ WF_vars(UpgradeDedupe) /\ WF_vars(UpgradeAutostart) /\ WF_vars(UpgradeOwnerRestore)
VoiceBarRunningAfterUpgrade == (scenario = "oldUpdater") ~> (phase = "done" /\ created /\ available /\ gate = "OPEN")
UpgradeControllerOwnsStartup == mutex => ~available
=============================================================================
