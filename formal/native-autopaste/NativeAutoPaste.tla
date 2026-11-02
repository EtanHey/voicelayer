-------------------------- MODULE NativeAutoPaste --------------------------
EXTENDS Naturals
CONSTANT AllowNativeFallback
VARIABLES phase, front, editable, sameElement, attempts, recipient, retained,
          eligibleDecline
vars == <<phase, front, editable, sameElement, attempts, recipient, retained,
          eligibleDecline>>

Init == /\ phase = "ax"
        /\ front \in {"recording", "other", "none"}
        /\ editable \in BOOLEAN
        /\ sameElement = TRUE
        /\ attempts = 0 /\ recipient = "none"
        /\ retained = TRUE /\ eligibleDecline = FALSE

\* Focus may move to another app, disappear, or change fields in the same app.
MoveFocus == /\ phase \in {"ax", "fallback"} /\ sameElement
             /\ front' \in {"recording", "other", "none"}
             /\ sameElement' = FALSE
             /\ UNCHANGED <<phase, editable, attempts, recipient, retained,
                             eligibleDecline>>

\* A possible AX write consumes the operation, even if its result is uncertain.
AXConsumes == /\ phase = "ax" /\ front = "recording" /\ editable /\ sameElement
              /\ phase' = "done" /\ attempts' = attempts + 1 /\ recipient' = front
              /\ UNCHANGED <<front, editable, sameElement, retained,
                              eligibleDecline>>

\* A clean pre-write decline is the only route to keyboard fallback.
AXDeclines == /\ phase = "ax" /\ phase' = "fallback"
              /\ UNCHANGED <<front, editable, sameElement, attempts, recipient,
                              retained, eligibleDecline>>

Fallback ==
  LET eligible == front = "recording" /\ editable /\ sameElement
      post == AllowNativeFallback /\ eligible
  IN /\ phase = "fallback" /\ phase' = "done"
     /\ eligibleDecline' = eligible
     /\ attempts' = IF post THEN attempts + 1 ELSE attempts
     /\ recipient' = IF post THEN front ELSE "none"
     /\ UNCHANGED <<front, editable, sameElement, retained>>

Next == MoveFocus \/ AXConsumes \/ AXDeclines \/ Fallback
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"ax", "fallback", "done"}
          /\ front \in {"recording", "other", "none"}
          /\ editable \in BOOLEAN /\ sameElement \in BOOLEAN
          /\ attempts \in 0..2 /\ recipient \in {"recording", "other", "none"}
          /\ retained \in BOOLEAN /\ eligibleDecline \in BOOLEAN
NoWrongApp == attempts = 0 \/ recipient = "recording"
NoDoubleDelivery == attempts <= 1
Retention == retained
\* The old policy is safe but fails delivery after a stable editable AX decline.
EligibleDelivery == phase # "done" \/ ~eligibleDecline \/ attempts = 1
=============================================================================
