--------------------------- MODULE CancelRetry ---------------------------
EXTENDS Naturals
CONSTANT UseAcquisitionError
VARIABLES gate, held, phase, result, attempts, schedule
vars == <<gate, held, phase, result, attempts, schedule>>

(* Refine precommit Cancel into acquisition, holder release, and retry decision.
   The readback budget has already exhausted; Cancel owns its separate 8 tries.
   Each healthy schedule releases before the second acquisition at the latest.
   Never-release exercises bounded failure without promising recovery. *)
Init == /\ gate = "DRAINING" /\ held = TRUE /\ phase = "attempt"
        /\ result = "none" /\ attempts = 0
        /\ schedule \in {"before", "between", "after", "never"}
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
Next == Release \/ Attempt \/ Decide
Spec == Init /\ [][Next]_vars /\ WF_vars(Release)
        /\ WF_vars(Attempt) /\ WF_vars(Decide)
RecoverableCancelReopens == (schedule # "never") ~> (gate = "OPEN" /\ phase = "done")
=============================================================================
