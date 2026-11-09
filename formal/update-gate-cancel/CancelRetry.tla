--------------------------- MODULE CancelRetry ---------------------------
EXTENDS Naturals
CONSTANT UseAcquisitionError
VARIABLES gate, held, phase, result, attempts, schedule, userGate, ledger, age, outcome, earlyRefusal, ack
userVars == <<userGate, ledger, age, outcome, earlyRefusal, ack>>
oldVars == <<gate, held, phase, result, attempts, schedule>>
vars == <<oldVars, userVars>>

(* Refine precommit Cancel into acquisition, holder release, and retry decision.
   The readback budget has already exhausted; Cancel owns its separate 8 tries.
   Each healthy schedule releases before the second acquisition at the latest.
   Never-release exercises bounded failure without promising recovery. *)
Init == /\ gate = "DRAINING" /\ held = TRUE /\ phase = "attempt"
        /\ result = "none" /\ attempts = 0
        /\ schedule \in {"before", "between", "after", "never"}
        /\ userGate = "OPEN" /\ ledger = 0 /\ age = 0 /\ outcome = "waiting" /\ earlyRefusal = FALSE /\ ack = FALSE
Release ==
  /\ held
  /\ ((schedule = "before" /\ phase = "attempt" /\ attempts = 0)
      \/ (schedule = "between" /\ phase = "decide" /\ attempts = 1)
      \/ (schedule = "after" /\ phase = "attempt" /\ attempts = 1))
  /\ held' = FALSE
  /\ UNCHANGED <<gate, phase, result, attempts, schedule>>
Attempt ==
  /\ phase = "attempt" /\ attempts < 8
  /\ ~(held /\ ((schedule = "before" /\ attempts = 0)
                 \/ (schedule = "after" /\ attempts = 1)))
  /\ result' = IF held THEN "locked" ELSE "applied"
  /\ gate' = IF held THEN gate ELSE "OPEN"
  /\ attempts' = attempts + 1 /\ phase' = "decide"
  /\ UNCHANGED <<held, schedule>>
Decide ==
  /\ phase = "decide"
  /\ ~(schedule = "between" /\ held /\ attempts = 1)
  /\ phase' = IF result = "applied" THEN "done"
               ELSE IF attempts < 8 /\ (UseAcquisitionError \/ held)
                    THEN "attempt" ELSE "recovery"
  /\ UNCHANGED <<gate, held, result, attempts, schedule>>
Next == (Release \/ Attempt \/ Decide) /\ UNCHANGED userVars
Spec == Init /\ [][Next]_vars /\ WF_oldVars(Release)
        /\ WF_oldVars(Attempt) /\ WF_oldVars(Decide)
RecoverableCancelReopens == (schedule # "never") ~> (gate = "OPEN" /\ phase = "done")

(* Logical clock ticks abstract the installer's monotonic deadline. Voice work
   may arrive throughout DRAINING. PREPARE and COMMIT are atomic locked ledger
   rechecks. A timed-out participant RPC yields to Cancel; ACKs may never arrive.
   Healthy storage/acquisition is assumed here; Fixed above models Cancel's
   recoverable lock contention, including its explicit recovery-only outcome. *)
DrainBound == 3
UserInit == /\ userGate = "OPEN" /\ ledger = 0 /\ age = 0
            /\ outcome = "waiting" /\ earlyRefusal = FALSE /\ ack \in BOOLEAN
            /\ gate = "DRAINING" /\ held = FALSE /\ phase = "done" /\ result = "none" /\ attempts = 0 /\ schedule = "never"
UserRequest == /\ userGate = "OPEN" /\ outcome = "waiting"
               /\ userGate' = "DRAINING"
               /\ UNCHANGED <<ledger, age, outcome, earlyRefusal, ack>>
UserVoice(allowDraining) ==
  /\ userGate \in {"OPEN", "DRAINING"} /\ ledger < 2
  /\ earlyRefusal' = (earlyRefusal \/ (userGate = "DRAINING" /\ ~allowDraining))
  /\ ledger' = IF userGate = "OPEN" \/ allowDraining THEN ledger + 1 ELSE ledger
  /\ UNCHANGED <<userGate, age, outcome, ack>>
UserFinish == /\ ledger > 0 /\ ledger' = ledger - 1
              /\ UNCHANGED <<userGate, age, outcome, earlyRefusal, ack>>
UserTick == /\ userGate \in {"DRAINING", "PREPARED"} /\ age < DrainBound
            /\ age' = age + 1
            /\ UNCHANGED <<userGate, ledger, outcome, earlyRefusal, ack>>
UserPrepare(recheck) ==
  /\ userGate = "DRAINING" /\ age < DrainBound /\ ack
  /\ (ledger = 0 \/ ~recheck) /\ userGate' = "PREPARED"
  /\ UNCHANGED <<ledger, age, outcome, earlyRefusal, ack>>
UserCommit(recheck) ==
  /\ userGate = "PREPARED" /\ age < DrainBound
  /\ (ledger = 0 \/ ~recheck) /\ userGate' = "COMMITTED" /\ outcome' = "commit"
  /\ UNCHANGED <<ledger, age, earlyRefusal, ack>>
UserCancel(bounded) ==
  /\ userGate \in {"DRAINING", "PREPARED"} /\ age = DrainBound /\ bounded
  /\ userGate' = "OPEN" /\ outcome' = "cancel"
  /\ UNCHANGED <<ledger, age, earlyRefusal, ack>>
UserNext(admit, bounded, recheck) == (UserRequest \/ UserVoice(admit) \/ UserFinish
  \/ UserTick \/ UserPrepare(recheck) \/ UserCommit(recheck) \/ UserCancel(bounded)) /\ UNCHANGED oldVars
UserRun(admit, bounded, recheck) == UserInit /\ [][UserNext(admit, bounded, recheck)]_vars
  /\ WF_userVars(UserRequest) /\ WF_userVars(UserTick)
  /\ WF_userVars(UserCommit(recheck)) /\ WF_userVars(UserCancel(bounded))
UserSpec == UserRun(TRUE, TRUE, TRUE)
OldAdmissionSpec == UserRun(FALSE, TRUE, TRUE)
UnboundedSpec == UserRun(TRUE, FALSE, TRUE)
NoLedgerSpec == UserRun(TRUE, TRUE, FALSE)
NoEarlyVoiceRefusal == ~earlyRefusal
NoSwapWithLedger == userGate \in {"PREPARED", "COMMITTED"} => ledger = 0
BoundedDrainResolves == (userGate \in {"DRAINING", "PREPARED"}) ~> (outcome \in {"commit", "cancel"} /\ age <= DrainBound)
=============================================================================
