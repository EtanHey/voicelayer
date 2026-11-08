--------------------------- MODULE FirstInstall ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS AllowLive, IgnoreEvidence, BadRecord, SkipBootstrap, ReplaceExisting,
          SandboxedPostflight, LegacyAvailability, IgnoreUpgradeController,
          AbortTransitionalQuit, ReuseMeansGone, SkipQuitHeldCheck,
          SkipComplete, IgnoreCompleteSha, IgnoreCompleteOwner
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
  /\ gate \in IF scenario = "leaseOwner" THEN {"COMMITTED"} ELSE {"ABSENT", "OPEN"}
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

(* G3 exit observation. Reuses this module's variables for a separate spec:
   participants = sampled exit state, available = poll index, gate = held
   lease, evidence = unsafe observation, mutex = locked verification result.
   A healthy schedule exposes each Darwin exit class then becomes gone within
   the polling budget. This assumes healthy OS progress within five seconds;
   uncertainty forever instead exercises deadline refusal, never success. *)
QuitStates == <<"alive", "exiting", "unreaped", "teardown", "emptyPs", "defunct", "gone">>
QuitUnsafe == {"reused", "competitor"}
QuitTransitional == {"exiting", "unreaped", "teardown", "emptyPs", "defunct"}
QuitInit ==
  /\ scenario \in {"healthy", "reused", "competitor", "unknown", "lostLease"}
  /\ gate = IF scenario = "lostLease" THEN "LOST" ELSE "COMMITTED"
  /\ phase = "poll" /\ available = 1
  /\ participants = IF scenario = "healthy" THEN "alive"
                     ELSE IF scenario = "lostLease" THEN "gone" ELSE scenario
  /\ evidence = FALSE /\ mutex = FALSE /\ created = FALSE
  /\ creation = "none"
QuitSample ==
  /\ phase = "poll"
  /\ mutex' = (gate = "COMMITTED" \/ SkipQuitHeldCheck)
  /\ evidence' = (participants \in QuitUnsafe)
  /\ creation' = participants
  /\ phase' = "decide"
  /\ UNCHANGED <<gate, participants, scenario, available, created>>
QuitDecide ==
  /\ phase = "decide"
  /\ LET gone == participants = "gone" \/ (ReuseMeansGone /\ participants = "reused")
         unsafe == evidence /\ ~(ReuseMeansGone /\ participants = "reused")
     IN phase' = IF ~mutex \/ unsafe THEN "refused"
                  ELSE IF gone THEN "proceed"
                  ELSE IF (AbortTransitionalQuit /\ participants \in QuitTransitional) \/ available = 8
                       THEN "refused" ELSE "poll"
  /\ participants' = IF scenario = "healthy" THEN QuitStates[IF available < 7 THEN available + 1 ELSE 7]
                       ELSE participants
  /\ available' = IF available < 8 THEN available + 1 ELSE 8
  /\ UNCHANGED <<gate, evidence, mutex, created, creation, scenario>>
QuitNext == QuitSample \/ QuitDecide
QuitSpec == QuitInit /\ [][QuitNext]_vars /\ WF_vars(QuitSample) /\ WF_vars(QuitDecide)
HealthyQuitCompletes == (scenario = "healthy") ~> (phase = "proceed")
NeverProceedOnReusedOrCompetitor == phase = "proceed" => ~evidence
NeverProceedWithoutHeldLease == phase = "proceed" => (gate = "COMMITTED" /\ mutex)
(* G5: a leased controller has already committed and retired the old pair.
   Installed bytes and an authenticated NEW pair are sampled outside G1. Under
   the lock the owner rechecks the same generation, unchanged bytes and fresh
   proof. Failures retain COMMITTED. This bounded ordering model assumes a
   healthy child/pair makes progress; it does not prove OS or IPC availability. *)
CompletionLease == [generation |-> 1, operationId |-> "op", ownerId |-> "owner", targetSha |-> "target"]
CompletionInitFor(cases, step) ==
  /\ scenario \in cases
  /\ gate = [kind |-> "COMMITTED", generation |-> 1, released |-> "none"]
  /\ phase = "install" /\ available = FALSE /\ mutex = FALSE
  /\ evidence = [exitZero |-> FALSE, sha |-> FALSE, new |-> FALSE, owner |-> FALSE]
  /\ creation = [exitZero |-> FALSE, sha |-> FALSE, new |-> FALSE, owner |-> FALSE, held |-> FALSE]
  /\ participants = FALSE /\ created = step
CompletionInit == CompletionInitFor({"success", "exitFailure", "shaMismatch", "deadSuccessor", "nonOwner"}, FALSE)
CompletionObserve ==
  /\ phase = "install" /\ phase' = "verified"
  /\ evidence' = [exitZero |-> scenario # "exitFailure", sha |-> scenario # "shaMismatch",
                   new |-> scenario # "deadSuccessor", owner |-> scenario # "nonOwner"]
  /\ UNCHANGED <<gate, available, mutex, creation, participants, created, scenario>>
CompletionAcquire ==
  /\ phase = "verified" /\ phase' = "locked" /\ mutex' = TRUE
  /\ UNCHANGED <<gate, available, evidence, creation, participants, created, scenario>>
CompletionPublish ==
  /\ phase = "locked" /\ gate.kind = "COMMITTED" /\ ~SkipComplete
  /\ evidence.exitZero /\ evidence.new
  /\ (evidence.sha \/ IgnoreCompleteSha) /\ (evidence.owner \/ IgnoreCompleteOwner)
  /\ gate' = [kind |-> "OPEN", generation |-> CompletionLease.generation, released |-> CompletionLease]
  /\ creation' = [exitZero |-> evidence.exitZero, sha |-> evidence.sha, new |-> evidence.new,
                   owner |-> evidence.owner, held |-> mutex]
  /\ phase' = "completed" /\ mutex' = FALSE
  /\ UNCHANGED <<available, evidence, participants, created, scenario>>
CompletionAdmit ==
  /\ phase = "completed" /\ gate.kind = "OPEN"
  /\ available' = TRUE /\ phase' = "done"
  /\ UNCHANGED <<gate, mutex, evidence, creation, participants, created, scenario>>
CompletionNext == CompletionObserve \/ CompletionAcquire \/ CompletionPublish \/ CompletionAdmit
CompletionSpec == CompletionInit /\ [][CompletionNext]_vars
  /\ WF_vars(CompletionObserve) /\ WF_vars(CompletionAcquire)
  /\ WF_vars(CompletionPublish) /\ WF_vars(CompletionAdmit)
NeverReopenUnverified == gate.kind = "OPEN" =>
  (creation.exitZero /\ creation.sha /\ creation.new /\ creation.owner /\ creation.held /\
   gate.generation = CompletionLease.generation /\ gate.released = CompletionLease)
LeasedUpdateReopensAdmission ==
  ((phase = "verified" /\ evidence.exitZero /\ evidence.sha /\ evidence.new /\ evidence.owner) \/
   (scenario = "slow" /\ evidence.exitZero /\ evidence.sha /\ evidence.owner))
    ~> (gate.kind = "OPEN" /\ gate.released = CompletionLease /\ available)

(* G5 round 2: each Sample is a fresh authenticated round trip with the same
   identity/executable fences. The healthy successor is ready on sample k=3,
   within the five-sample abstract deadline. Never-ready expires, while a
   positively unsafe second sample refuses immediately. No cached proof can
   advance CompletionPublish. OneShot is the previous single-refresh caller. *)
SlowCompletionInit == CompletionInitFor({"slow", "never", "unsafe"}, 0)
SlowCompletionObserve ==
  /\ phase = "install" /\ phase' = "poll"
  /\ evidence' = [exitZero |-> TRUE, sha |-> TRUE, new |-> FALSE, owner |-> TRUE]
  /\ UNCHANGED <<gate, available, mutex, creation, participants, created, scenario>>
SlowCompletionSample ==
  /\ phase = "poll" /\ phase' = "sampled"
  /\ created' = created + 1
  /\ evidence' = [evidence EXCEPT !.new = (scenario = "slow" /\ created + 1 >= 3)]
  /\ UNCHANGED <<gate, available, mutex, creation, participants, scenario>>
SlowCompletionDecide(oneShot) ==
  /\ phase = "sampled"
  /\ phase' = IF evidence.new THEN "verified"
               ELSE IF oneShot \/ created = 5 \/ (scenario = "unsafe" /\ created = 2)
                    THEN "refused" ELSE "poll"
  /\ UNCHANGED <<gate, available, mutex, evidence, creation, participants, created, scenario>>
SlowCompletionNext(oneShot) == SlowCompletionObserve \/ SlowCompletionSample \/ SlowCompletionDecide(oneShot)
  \/ CompletionAcquire \/ CompletionPublish \/ CompletionAdmit
SlowCompletionSpecFor(oneShot) == SlowCompletionInit /\ [][SlowCompletionNext(oneShot)]_vars
  /\ WF_vars(SlowCompletionObserve) /\ WF_vars(SlowCompletionSample) /\ WF_vars(SlowCompletionDecide(oneShot))
  /\ WF_vars(CompletionAcquire) /\ WF_vars(CompletionPublish) /\ WF_vars(CompletionAdmit)
SlowCompletionSpec == SlowCompletionSpecFor(FALSE)
OneShotCompletionSpec == SlowCompletionSpecFor(TRUE)

(* R6 successor backstop. participants is controller liveness; created counts
   bounded observations after death. mutex is a transient live G1 holder, not
   lease ownership. The crash case begins alive; its controller dies later.
   No fairness can revive a dead controller. The model requires matching
   running/installed target, empty ledger and fresh successor proof. *)
RecoveryInit ==
  /\ scenario \in {"dead", "crash", "live", "wrongTarget", "busy"}
  /\ gate = "COMMITTED" /\ participants = (scenario \in {"crash", "live"})
  /\ evidence = [sha |-> scenario # "wrongTarget", ready |-> scenario # "busy"]
  /\ created = 0 /\ creation = [recovered |-> FALSE, live |-> FALSE, verified |-> FALSE]
  /\ phase = "watch" /\ mutex = TRUE /\ available = FALSE
RecoveryControllerExit ==
  /\ scenario = "crash" /\ participants /\ participants' = FALSE
  /\ UNCHANGED <<gate, evidence, mutex, phase, created, creation, scenario, available>>
RecoveryTick ==
  /\ phase = "watch" /\ created < 5
  /\ created' = IF participants /\ ~IgnoreCompleteOwner THEN 0 ELSE created + 1
  /\ UNCHANGED <<gate, participants, evidence, mutex, phase, creation, scenario, available>>
RecoveryHolderExit ==
  /\ mutex /\ created >= 2 /\ mutex' = FALSE
  /\ UNCHANGED <<gate, participants, evidence, phase, created, creation, scenario, available>>
RecoveryPublish ==
  /\ phase = "watch" /\ ~SkipComplete /\ ~mutex /\ created = 5
  /\ (~participants \/ IgnoreCompleteOwner) /\ (evidence.sha \/ IgnoreCompleteSha) /\ evidence.ready
  /\ gate' = "OPEN" /\ available' = TRUE /\ phase' = "done"
  /\ creation' = [recovered |-> TRUE, live |-> participants,
                  verified |-> evidence.sha /\ evidence.ready /\ ~mutex]
  /\ UNCHANGED <<participants, evidence, mutex, created, scenario>>
RecoveryNext == RecoveryControllerExit \/ RecoveryTick \/ RecoveryHolderExit \/ RecoveryPublish
RecoverySpec == RecoveryInit /\ [][RecoveryNext]_vars
  /\ WF_vars(RecoveryControllerExit) /\ WF_vars(RecoveryTick)
  /\ WF_vars(RecoveryHolderExit) /\ WF_vars(RecoveryPublish)
EventuallyOpenAfterAbandonedLease ==
  (scenario \in {"dead", "crash"}) ~> (gate = "OPEN" /\ available)
NeverRecoverLiveController == creation.recovered => ~creation.live
RecoveryOnlyVerified == creation.recovered => creation.verified

(* Admission participants are process incarnations, not bare PIDs. Reused means the
   recorded incarnation is gone even though that PID has a new owner. Unknown
   cannot justify retirement. Reap/Prepare abstract the same held G1 mutex. *)
reapVars == vars
OwnerIds == {"a", "b"}
ReapInit ==
  /\ participants \in [OwnerIds -> {"live", "dead", "reused", "unknown"}]
  /\ evidence = OwnerIds /\ creation = {} /\ scenario \in SUBSET OwnerIds
  /\ phase = "OPEN" /\ created = FALSE
  /\ gate = "OPEN" /\ mutex = FALSE /\ available = FALSE
OwnerDeath(i) ==
  /\ participants[i] = "live" /\ participants' = [participants EXCEPT ![i] = "dead"]
  /\ UNCHANGED <<evidence, creation, scenario, phase, created, gate, mutex, available>>
OwnerReap(i, ageMutant, disabled) ==
  /\ ~disabled /\ i \in evidence
  /\ (participants[i] \in {"dead", "reused"} \/ (ageMutant /\ i \in scenario))
  /\ evidence' = evidence \ {i} /\ creation' = creation \cup {i}
  /\ created' = (created \/ participants[i] \in {"live", "unknown"})
  /\ UNCHANGED <<participants, scenario, phase, gate, mutex, available>>
ReapRequest == /\ phase = "OPEN" /\ phase' = "DRAINING"
               /\ UNCHANGED <<participants, evidence, creation, scenario, created, gate, mutex, available>>
ReapPrepare == /\ phase = "DRAINING" /\ evidence = {} /\ phase' = "PREPARED"
               /\ UNCHANGED <<participants, evidence, creation, scenario, created, gate, mutex, available>>
ReapNext(ageMutant, disabled) == ReapRequest \/ ReapPrepare \/
  (\E i \in OwnerIds: OwnerDeath(i) \/ OwnerReap(i, ageMutant, disabled))
ReapSpec(ageMutant, disabled) == ReapInit /\ [][ReapNext(ageMutant, disabled)]_reapVars
  /\ WF_reapVars(ReapRequest) /\ WF_reapVars(ReapPrepare)
  /\ (\A i \in OwnerIds: WF_reapVars(OwnerReap(i, ageMutant, disabled)))
ReapFixedSpec == ReapSpec(FALSE, FALSE)
ReapAgeMutantSpec == ReapSpec(TRUE, FALSE)
ReapOldSpec == ReapSpec(FALSE, TRUE)
NeverReapLiveOwner == ~created
DeadRegistrationsCanPrepare ==
  (\A i \in evidence: participants[i] \in {"dead", "reused"}) ~> (phase = "PREPARED")

=============================================================================
