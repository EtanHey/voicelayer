--------------------------- MODULE LeasedUpdate ---------------------------
(* End-to-end leased-update lifecycle for the VoiceLayer update gate.

   FirstInstall.tla (lane G5) checks the final COMPLETE phase in isolation:
   CompletionSpec starts at COMMITTED with one controller and the old
   UpgradeSpec deliberately ends a leased upgrade at COMMITTED. Neither spec
   composes REQUEST -> PREPARE -> COMMIT -> install -> COMPLETE/CANCEL with a
   second updater, a voice admitter, process crash, an orphaned G1 lock, a
   detached installer child or evidence lost after verification. This module
   does, at the smallest granularity that still separates those orderings.

   Abstractions (see README.md for the line-by-line source mapping):
   - g1 is the mkdir(<gate>.lock) critical section. Every live G1 section is
     one atomic step (sections are synchronous, contain no awaits, and remove
     the lock on success and on REFUSED). Only a process dying inside a
     section orphans the lock; orphans are never reaped.
   - A lease is identified by its owning controller; each controller makes at
     most one attempt, so (generation, owner) is unique, like the UUID lease.
   - pair is the native/daemon participant pair: "old" before quit, "none"
     after the controlled quit, then the NEW pair "starting"/"ready", or
     "never" (a successor that cannot become ready within the retry budget),
     or "lost" (ready, then gone before the in-G1 recheck).
   - installed abstracts Info.plist GitCommit relative to the CURRENT owner's
     lease.targetSha: "old" before the install, then "target" or "other".
   - Crash is SIGKILL/power loss of a controller. Normal return is Exit; the
     2.2.61 trigger is a normal return, never excused as a crash.          *)
EXTENDS Naturals

CONSTANTS OmitComplete,        \* 2.2.61: child exit 0 -> return 0, lease held
          OmitCancel,          \* precommit abort returns without CANCEL
          RequestSteals,       \* REQUEST accepted from a non-OPEN gate
          IgnoreCompleteOwner, \* COMPLETE transition skips sameLease
          CancelAfterCommit,   \* rollback/CANCEL allowed after COMMIT
          CrashReopens,        \* absent/dead owner reopens the gate
          SkipCompleteRecheck  \* COMPLETE trusts pre-G1 evidence

Controllers == {"c1", "c2"}
None == "none"

VARIABLES gate,       \* durable update-gate.json
          receipt,    \* durable <gate>.controller custody record
          g1,         \* holder of <gate>.lock: None, a controller, or "voice"
          pc,         \* controller program counters
          child,      \* detached installer child per controller
          installed,  \* installed GitCommit vs the current owner's target
          pair,       \* native/daemon participant pair
          voice,      \* a registered voice admission in the ledger
          releasedBy, \* history: process that published the last reopen
          reopen      \* history: how the last reopen was justified
vars == <<gate, receipt, g1, pc, child, installed, pair, voice, releasedBy, reopen>>

LeasePCs == {"drain", "prepared", "committed", "installing", "verified", "aborting"}
Alive(c) == pc[c] \notin {"crashed", "exited"}
Owns(c, kind) == gate.kind = kind /\ gate.owner = c

Init ==
  /\ gate = [kind |-> "OPEN", gen |-> 0, owner |-> None, released |-> None]
  /\ receipt = None /\ g1 = None
  /\ pc = [c \in Controllers |-> "idle"]
  /\ child = [c \in Controllers |-> "none"]
  /\ installed = "old" /\ pair = "old" /\ voice = FALSE
  /\ releasedBy = None /\ reopen = "none"

(* Publish OPEN for the current lease. Storage removes only the matching
   controller receipt. The proof flag is what the reopening step saw. *)
Reopen(by) ==
  LET o == gate.owner
      proof == child[o] = "exit0" /\ installed = "target" /\ pair = "ready" /\ receipt = o
  IN /\ gate' = [kind |-> "OPEN", gen |-> gate.gen, owner |-> None, released |-> o]
     /\ receipt' = IF receipt = o THEN None ELSE receipt
     /\ releasedBy' = by
     /\ reopen' = IF gate.kind \in {"DRAINING", "PREPARED"} THEN "precommit"
                  ELSE IF proof THEN "verified" ELSE "unverified"

----------------------------------------------------------------------------
(* Controller c: runGatedInstall + completeGatedInstall. *)
Request(c) ==
  /\ pc[c] = "idle" /\ g1 = None /\ receipt = None
  /\ (gate.kind = "OPEN" \/ RequestSteals)
  /\ gate' = [kind |-> "DRAINING", gen |-> gate.gen + 1, owner |-> c, released |-> gate.released]
  /\ pc' = [pc EXCEPT ![c] = "drain"]
  /\ UNCHANGED <<receipt, g1, child, installed, pair, voice, releasedBy, reopen>>
RefuseStart(c) ==
  /\ pc[c] = "idle" /\ (gate.kind # "OPEN" \/ receipt # None)
  /\ pc' = [pc EXCEPT ![c] = "refused"]
  /\ UNCHANGED <<gate, receipt, g1, child, installed, pair, voice, releasedBy, reopen>>
Prepare(c) ==
  /\ pc[c] = "drain" /\ g1 = None /\ Owns(c, "DRAINING") /\ ~voice
  /\ gate' = [gate EXCEPT !.kind = "PREPARED"]
  /\ pc' = [pc EXCEPT ![c] = "prepared"]
  /\ UNCHANGED <<receipt, g1, child, installed, pair, voice, releasedBy, reopen>>
Commit(c) ==
  /\ pc[c] = "prepared" /\ g1 = None /\ Owns(c, "PREPARED") /\ ~voice
  /\ gate' = [gate EXCEPT !.kind = "COMMITTED"] /\ receipt' = c
  /\ pc' = [pc EXCEPT ![c] = "committed"]
  /\ UNCHANGED <<g1, child, installed, pair, voice, releasedBy, reopen>>
Abort(c) ==
  /\ pc[c] \in (IF CancelAfterCommit THEN {"drain", "prepared", "committed", "installing"}
                ELSE {"drain", "prepared"})
  /\ pc' = [pc EXCEPT ![c] = "aborting"]
  /\ UNCHANGED <<gate, receipt, g1, child, installed, pair, voice, releasedBy, reopen>>
CancelLease(c) ==
  /\ pc[c] = "aborting" /\ g1 = None
  /\ IF ~OmitCancel /\ gate.owner = c /\
        (gate.kind \in {"DRAINING", "PREPARED"} \/ (CancelAfterCommit /\ gate.kind = "COMMITTED"))
     THEN Reopen(c) ELSE UNCHANGED <<gate, receipt, releasedBy, reopen>>
  /\ pc' = [pc EXCEPT ![c] = "cancelled"]
  /\ UNCHANGED <<g1, child, installed, pair, voice>>
Spawn(c) ==
  /\ pc[c] = "committed"
  /\ child' = [child EXCEPT ![c] = "running"] /\ pair' = "none" /\ installed' = "old"
  /\ pc' = [pc EXCEPT ![c] = "installing"]
  /\ UNCHANGED <<gate, receipt, g1, voice, releasedBy, reopen>>
(* 2.2.61 (integration f401ae7, update-gate-installer.ts:241-243). *)
OldReturn(c) ==
  /\ OmitComplete /\ pc[c] = "installing" /\ child[c] \in {"exit0", "exitN"}
  /\ pc' = [pc EXCEPT ![c] = "exited"]
  /\ UNCHANGED <<gate, receipt, g1, child, installed, pair, voice, releasedBy, reopen>>
(* Outside G1: exit code, plist GitCommit, fresh successor round trips. *)
Verify(c) ==
  /\ ~OmitComplete /\ pc[c] = "installing"
  /\ child[c] = "exit0" /\ installed = "target" /\ pair = "ready"
  /\ pc' = [pc EXCEPT ![c] = "verified"]
  /\ UNCHANGED <<gate, receipt, g1, child, installed, pair, voice, releasedBy, reopen>>
VerifyFail(c) ==
  /\ ~OmitComplete /\ pc[c] = "installing" /\ child[c] \in {"exit0", "exitN"}
  /\ (child[c] = "exitN" \/ installed # "target" \/ pair \in {"never", "lost"})
  /\ pc' = [pc EXCEPT ![c] = "failed"]
  /\ UNCHANGED <<gate, receipt, g1, child, installed, pair, voice, releasedBy, reopen>>
Recheck == SkipCompleteRecheck \/ (installed = "target" /\ pair = "ready")
Complete(c) ==
  /\ ~OmitComplete /\ pc[c] = "verified" /\ g1 = None
  /\ Owns(c, "COMMITTED") /\ receipt = c /\ Recheck
  /\ Reopen(c)
  /\ pc' = [pc EXCEPT ![c] = "done"]
  /\ UNCHANGED <<g1, child, installed, pair, voice>>
CompleteRefused(c) ==
  /\ pc[c] = "verified" /\ g1 = None
  /\ ~(Owns(c, "COMMITTED") /\ receipt = c /\ Recheck)
  /\ pc' = [pc EXCEPT ![c] = "failed"]
  /\ UNCHANGED <<gate, receipt, g1, child, installed, pair, voice, releasedBy, reopen>>
CompleteGiveUp(c) ==
  /\ pc[c] = "verified" /\ g1 # None
  /\ pc' = [pc EXCEPT ![c] = "failed"]
  /\ UNCHANGED <<gate, receipt, g1, child, installed, pair, voice, releasedBy, reopen>>
(* A process that does not hold the current lease submits COMPLETE for its
   own (released, cancelled or never-granted) lease with self-asserted fields.
   Only transitionUpdateGate's sameLease fence stands in its way. *)
ForeignComplete(c) ==
  /\ pc[c] \in {"done", "cancelled", "refused"} /\ g1 = None
  /\ gate.kind = "COMMITTED" /\ (gate.owner = c \/ IgnoreCompleteOwner)
  /\ Reopen(c)
  /\ UNCHANGED <<g1, pc, child, installed, pair, voice>>
Exit(c) ==
  /\ pc[c] \in {"done", "failed", "cancelled", "refused"}
  /\ pc' = [pc EXCEPT ![c] = "exited"]
  /\ UNCHANGED <<gate, receipt, g1, child, installed, pair, voice, releasedBy, reopen>>
(* SIGKILL at any point. orphan: died inside a G1 section, lock retained. *)
Crash(c) ==
  /\ Alive(c) /\ pc[c] # "idle"
  /\ \E orphan \in BOOLEAN :
       /\ (orphan => g1 = None)
       /\ g1' = IF orphan THEN c ELSE g1
  /\ IF CrashReopens /\ gate.owner = c /\ gate.kind # "OPEN"
     THEN Reopen(c) ELSE UNCHANGED <<gate, receipt, releasedBy, reopen>>
  /\ pc' = [pc EXCEPT ![c] = "crashed"]
  /\ UNCHANGED <<child, installed, pair, voice>>

----------------------------------------------------------------------------
(* Environment: detached installer child, successor pair, voice admission. *)
ChildExit(c) ==
  /\ child[c] = "running"
  /\ \/ /\ child' = [child EXCEPT ![c] = "exit0"]
        /\ installed' \in {"target", "other"} /\ pair' \in {"starting", "never"}
     \/ /\ child' = [child EXCEPT ![c] = "exitN"]
        /\ installed' = "other" /\ UNCHANGED pair
  /\ UNCHANGED <<gate, receipt, g1, pc, voice, releasedBy, reopen>>
SuccessorReady ==
  /\ pair = "starting" /\ pair' = "ready"
  /\ UNCHANGED <<gate, receipt, g1, pc, child, installed, voice, releasedBy, reopen>>
EvidenceLost ==
  /\ \/ pair = "ready" /\ pair' = "lost" /\ UNCHANGED installed
     \/ installed = "target" /\ installed' = "other" /\ UNCHANGED pair
  /\ UNCHANGED <<gate, receipt, g1, pc, child, voice, releasedBy, reopen>>
Admit ==
  /\ ~voice /\ g1 = None /\ gate.kind = "OPEN" /\ voice' = TRUE
  /\ UNCHANGED <<gate, receipt, g1, pc, child, installed, pair, releasedBy, reopen>>
VoiceDone ==
  /\ voice /\ g1 = None /\ voice' = FALSE
  /\ UNCHANGED <<gate, receipt, g1, pc, child, installed, pair, releasedBy, reopen>>
VoiceCrashInG1 ==
  /\ g1 = None /\ g1' = "voice"
  /\ UNCHANGED <<gate, receipt, pc, child, installed, pair, voice, releasedBy, reopen>>

ControllerProgress(c) ==
  Prepare(c) \/ Commit(c) \/ CancelLease(c) \/ Spawn(c) \/ OldReturn(c) \/ Verify(c) \/
  VerifyFail(c) \/ Complete(c) \/ CompleteRefused(c) \/ CompleteGiveUp(c) \/ Exit(c)
Next ==
  \/ \E c \in Controllers :
       Request(c) \/ RefuseStart(c) \/ Abort(c) \/ ForeignComplete(c) \/ Crash(c) \/
       ControllerProgress(c) \/ ChildExit(c)
  \/ SuccessorReady \/ EvidenceLost \/ Admit \/ VoiceDone \/ VoiceCrashInG1

(* Fairness: a live controller keeps executing its own code; a detached
   child terminates; a successor that is starting becomes ready within the
   retry budget (G5's bounded-readiness assumption; "never" models the
   successor that does not); a voice turn finishes. Nothing forces a
   REQUEST, an abort, a crash, an admission or evidence loss. *)
Fairness ==
  /\ \A c \in Controllers : WF_vars(ControllerProgress(c)) /\ WF_vars(ChildExit(c))
  /\ WF_vars(SuccessorReady) /\ WF_vars(VoiceDone)
Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
(* SAFETY *)

(* Owner/lease exclusivity: a closed gate names exactly one owner, and every
   live controller that believes it holds a lease is that owner. *)
LeaseExclusive ==
  /\ (gate.kind = "OPEN") = (gate.owner = None)
  /\ \A c \in Controllers : pc[c] \in LeasePCs => gate.owner = c

(* Only the lease's own controller ever releases it (no foreign COMPLETE). *)
ReleaseByOwnerOnly == releasedBy = gate.released

(* The installer mutates bytes only under its owner's durable COMMITTED lease
   and custody receipt, with no voice admission registered. This is what a
   rollback after COMMIT or a dead-owner reopen would break. *)
MutationExclusive ==
  \A c \in Controllers : child[c] = "running" =>
    (Owns(c, "COMMITTED") /\ receipt = c /\ ~voice)

(* A committed lease reopens only on proof present at the reopening step. *)
ReopenOnlyVerified == reopen # "unverified"

(* The 2.2.61 bad terminal state, stated without assuming release: a
   controller returned normally after a healthy install (exit 0, target SHA,
   successor starting/ready, G1 free) while still holding its lease. *)
NoHealthyExitHoldingLease ==
  ~\E c \in Controllers :
     /\ pc[c] = "exited" /\ Owns(c, "COMMITTED")
     /\ child[c] = "exit0" /\ installed = "target" /\ pair \in {"starting", "ready"}
     /\ g1 = None

(* LIVENESS (conditional). The premises are environment facts, not controller
   program counters, so code that never reaches a "verified" state cannot
   satisfy them vacuously. The only excuses are the documented fail-closed
   cases: the owner process crashed, some process died inside G1 leaving the
   lock orphaned, or verified evidence disappeared before the in-G1 recheck.
   A normal return is never an excuse. *)
ReleasedBy(c) == gate.kind = "OPEN" /\ gate.released = c
Crashed(c) == pc[c] = "crashed"
G1Orphaned == g1 # None
EvidenceGone == pair = "lost" \/ installed = "other"
InstalledHealthy(c) ==
  /\ Owns(c, "COMMITTED") /\ child[c] = "exit0" /\ installed = "target"
  /\ pair \in {"starting", "ready"}

VerifiedUpdateReleases ==
  \A c \in Controllers :
    InstalledHealthy(c) ~> (ReleasedBy(c) \/ Crashed(c) \/ G1Orphaned \/ EvidenceGone)
AbortedUpdateReleases ==
  \A c \in Controllers :
    (pc[c] = "aborting") ~> (ReleasedBy(c) \/ Crashed(c) \/ G1Orphaned)

(* Boundary probes (boundary/*.cfg, expected to FAIL): each drops exactly one
   excuse to show it is necessary, i.e. the fail-closed design really does not
   promise release in that case. *)
ReleasesEvenIfCrashed ==
  \A c \in Controllers : InstalledHealthy(c) ~> (ReleasedBy(c) \/ G1Orphaned \/ EvidenceGone)
ReleasesEvenIfOrphaned ==
  \A c \in Controllers : InstalledHealthy(c) ~> (ReleasedBy(c) \/ Crashed(c) \/ EvidenceGone)
ReleasesEvenIfEvidenceGone ==
  \A c \in Controllers : InstalledHealthy(c) ~> (ReleasedBy(c) \/ Crashed(c) \/ G1Orphaned)
AbortReleasesEvenIfCrashed ==
  \A c \in Controllers : (pc[c] = "aborting") ~> (ReleasedBy(c) \/ G1Orphaned)
=============================================================================
