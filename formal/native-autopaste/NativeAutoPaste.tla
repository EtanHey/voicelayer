-------------------------- MODULE NativeAutoPaste --------------------------
EXTENDS Naturals
CONSTANTS AllowNativeFallback, AllowAbsentEnabled, AllowExplicitFalse,
          AllowForeignTarget, AllowDoubleDelivery, DropRetention, BreakType,
          SkipAXElementGuard, SkipFallbackElementGuard,
          SkipAXWritableGuard, SkipFallbackWritableGuard
VARIABLES phase, front, editable, enabled, sameElement, attempts, recipient, retained,
          eligibleDecline, dispatchedSameElement, dispatchedEditable
vars == <<phase, front, editable, enabled, sameElement, attempts, recipient, retained,
          eligibleDecline, dispatchedSameElement, dispatchedEditable>>

Init == /\ phase = "ax"
        /\ front \in {"recording", "other", "none"}
        /\ editable \in BOOLEAN
        /\ enabled \in {"true", "false", "absent"}
        /\ sameElement = TRUE
        /\ attempts = 0 /\ recipient = "none"
        /\ retained = TRUE /\ eligibleDecline = FALSE
        /\ dispatchedSameElement = TRUE /\ dispatchedEditable = TRUE

\* Focus may move to another app, disappear, or change fields in the same app.
MoveFocus == /\ phase \in {"ax", "fallback"} /\ sameElement
             /\ front' \in {"recording", "other", "none"}
             /\ sameElement' = FALSE
             /\ UNCHANGED <<phase, editable, enabled, attempts, recipient, retained,
                             eligibleDecline, dispatchedSameElement, dispatchedEditable>>

\* A possible AX write consumes the operation, even if its result is uncertain.
\* AXEnabled is optional; independently writable text is disabled only by FALSE.
NativeEditable == editable /\ enabled # "false"
ImplEnabled == enabled = "true" \/ (AllowAbsentEnabled /\ enabled = "absent")
               \/ (AllowExplicitFalse /\ enabled = "false")
ImplTarget == front = "recording" \/ (AllowForeignTarget /\ front = "other")

AXConsumes == /\ phase = "ax" /\ ImplTarget /\ (editable \/ SkipAXWritableGuard)
              /\ ImplEnabled /\ (sameElement \/ SkipAXElementGuard)
              /\ phase' = IF BreakType THEN "invalid" ELSE "done"
              /\ attempts' = attempts + (IF AllowDoubleDelivery THEN 2 ELSE 1)
              /\ recipient' = front /\ retained' = (retained /\ ~DropRetention)
              /\ dispatchedSameElement' = sameElement /\ dispatchedEditable' = editable
              /\ UNCHANGED <<front, editable, enabled, sameElement, eligibleDecline>>

\* A clean pre-write decline is the only route to keyboard fallback.
AXDeclines == /\ phase = "ax" /\ phase' = "fallback"
              /\ UNCHANGED <<front, editable, enabled, sameElement, attempts, recipient,
                              retained, eligibleDecline, dispatchedSameElement, dispatchedEditable>>

Fallback ==
  LET eligible == front = "recording" /\ NativeEditable /\ sameElement
      post == AllowNativeFallback /\ (editable \/ SkipFallbackWritableGuard)
              /\ ImplEnabled /\ ImplTarget /\ (sameElement \/ SkipFallbackElementGuard)
  IN /\ phase = "fallback" /\ phase' = "done"
     /\ eligibleDecline' = eligible
     /\ attempts' = IF post THEN attempts + 1 ELSE attempts
     /\ recipient' = IF post THEN front ELSE "none"
     /\ dispatchedSameElement' = IF post THEN sameElement ELSE dispatchedSameElement
     /\ dispatchedEditable' = IF post THEN editable ELSE dispatchedEditable
     /\ UNCHANGED <<front, editable, enabled, sameElement, retained>>

Next == MoveFocus \/ AXConsumes \/ AXDeclines \/ Fallback
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"ax", "fallback", "done"}
          /\ front \in {"recording", "other", "none"}
          /\ editable \in BOOLEAN /\ sameElement \in BOOLEAN
          /\ enabled \in {"true", "false", "absent"}
          /\ attempts \in 0..2 /\ recipient \in {"recording", "other", "none"}
          /\ retained \in BOOLEAN /\ eligibleDecline \in BOOLEAN
          /\ dispatchedSameElement \in BOOLEAN /\ dispatchedEditable \in BOOLEAN
NoWrongApp == attempts = 0 \/ recipient = "recording"
NoDoubleDelivery == attempts <= 1
Retention == retained
NoDisabledDelivery == enabled # "false" \/ attempts = 0
\* Ghost values record the actual target evidence at dispatch, not policy approval.
NoChangedElementDelivery == attempts = 0 \/ dispatchedSameElement
NoUnwritableDelivery == attempts = 0 \/ dispatchedEditable
\* Eligibility is independent of the implementation's AXEnabled interpretation.
EligibleDelivery == phase # "done" \/ ~eligibleDecline \/ attempts = 1
=============================================================================
