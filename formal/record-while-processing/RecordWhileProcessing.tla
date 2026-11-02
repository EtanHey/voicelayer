----------------------- MODULE RecordWhileProcessing -----------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Admission, CancelPolicy, PastePolicy, RetentionPolicy, Ingress
VARIABLE s
vars == <<s>>
Takes == {"A", "B"}
Stages == {"fresh", "recording", "captured", "transcribing", "ready", "cancelling", "pasted", "cancelled", "failed", "superseded"}
Active == {t \in Takes : s.stage[t] \in {"recording", "transcribing", "ready"}}
Mic == {t \in Takes : s.stage[t] = "recording"}
Worker == {t \in Takes : s.stage[t] \in {"transcribing", "cancelling"}}
Ready == {t \in Takes : s.stage[t] = "ready"}
Commit(x, e, t, failures) == s' = [x EXCEPT !.event = e, !.target = t,
                                              !.violations = s.violations \cup failures]
Init == s = [stage |-> [t \in Takes |-> "fresh"], saved |-> {},
             deliveries |-> [t \in Takes |-> 0], floor |-> [t \in Takes |-> 0],
             guard |-> "none", cooldown |-> 0, ring |-> FALSE,
             event |-> "init", target |-> "none", violations |-> {}]
Record(t, origin) ==
  LET blocked == Admission = "current" /\ (Worker # {} \/ (origin = "F5" /\ Ready # {}))
      victim == IF Worker # {} THEN CHOOSE a \in Worker: TRUE
                ELSE IF Ready # {} THEN CHOOSE a \in Ready: TRUE ELSE t
      nativeCancel == blocked /\ origin = "F5" /\ s.stage[victim] # "cancelling"
      after == IF nativeCancel THEN [s EXCEPT !.stage[victim] = IF @ = "ready" THEN "cancelled" ELSE "cancelling"]
               ELSE IF blocked THEN s ELSE [s EXCEPT !.stage[t] = "recording"]
      failures == (IF after.stage[t] # "recording" THEN {"N6Start"} ELSE {}) \cup
                  (IF nativeCancel THEN {"N6Preserve"} ELSE {})
  IN /\ s.stage[t] = "fresh" /\ Mic = {}
     /\ (Admission # "current" \/ {a \in Takes: s.stage[a] = "captured"} = {})
     /\ Commit(after, origin, t, failures)
Capture(t, reason) == /\ s.stage[t] = "recording"
                     /\ Commit([s EXCEPT !.stage[t] = "captured", !.saved = @ \cup {t}], reason, t, {})
Decode(t) == /\ s.stage[t] = "captured" /\ Worker = {}
             /\ Commit([s EXCEPT !.stage[t] = "transcribing", !.floor[t] = 2], "decode", t, {})
Complete(t) ==
  LET delayed == PastePolicy = "current" /\ s.floor[t] > 0
      after == [s EXCEPT !.stage[t] = IF delayed THEN "ready" ELSE "pasted",
                        !.deliveries[t] = IF delayed THEN @ ELSE @ + 1]
  IN /\ s.stage[t] = "transcribing"
     /\ Commit(after, "result", t, IF after.deliveries[t] # 1 THEN {"N8Immediate"} ELSE {})
Deliver(t) == /\ s.stage[t] = "ready" /\ s.floor[t] = 0
              /\ Commit([s EXCEPT !.stage[t] = "pasted", !.deliveries[t] = @ + 1], "deliver", t, {})
DropDeferred(t) == /\ Admission = "current" /\ s.stage[t] = "ready" /\ Mic # {}
                  /\ Commit([s EXCEPT !.stage[t] = "superseded"], "new-recording-event", t, {})
Fail(t) == /\ s.stage[t] = "transcribing"
           /\ Commit([s EXCEPT !.stage[t] = "failed"], "failure", t, {})
ReapCancelled(t) == /\ s.stage[t] = "cancelling"
                    /\ Commit([s EXCEPT !.stage[t] = "cancelled"], "cancel-settled", t, {})
Cancel(t, origin, victim) ==
  LET guarded == s.guard = t /\ s.cooldown = 0
      processingTarget == s.stage[t] \in {"transcribing", "ready"}
      clearsGuard == s.guard = victim
      saved == IF RetentionPolicy = "dropCancel" THEN s.saved ELSE s.saved \cup {victim}
      after == [s EXCEPT !.stage[victim] = IF s.stage[victim] = "transcribing" THEN "cancelling" ELSE "cancelled", !.saved = saved,
                        !.guard = IF clearsGuard THEN "none" ELSE @,
                        !.cooldown = IF clearsGuard THEN 0 ELSE @,
                        !.ring = IF clearsGuard THEN FALSE ELSE @]
      failures == (IF victim # t THEN {"N7Scope"} ELSE {}) \cup
                  (IF origin = "click" /\ processingTarget /\ ~guarded THEN {"N7Guard"} ELSE {})
  IN /\ t \in Active /\ victim \in Active
     /\ (origin = "Escape" /\ Mic # {} => t \in Mic)
     /\ (origin = "Escape" /\ Mic = {} /\ Worker # {} => t \in Worker)
     /\ (CancelPolicy = "global" \/ victim = t)
     /\ (origin = "Escape" \/ ~processingTarget \/ CancelPolicy = "current" \/ guarded)
     /\ Commit(after, origin, t, failures)
Arm(t) == /\ CancelPolicy # "current" /\ s.stage[t] \in {"transcribing", "ready"} /\ s.guard # t
          /\ Commit([s EXCEPT !.guard = t, !.cooldown = 2, !.ring = TRUE], "arm", t, {})
Tick == /\ s.cooldown > 0 \/ (\E t \in Takes: s.floor[t] > 0)
        /\ Commit([s EXCEPT !.cooldown = IF @ > 0 THEN @ - 1 ELSE 0,
                            !.ring = s.guard # "none" /\ s.cooldown > 1,
                            !.floor = [t \in Takes |-> IF s.floor[t] > 0 THEN s.floor[t] - 1 ELSE 0]],
                  "tick", "none", {})
DismissStaleGuard == /\ s.guard # "none" /\ s.guard \notin Active
                    /\ Commit([s EXCEPT !.guard = "none", !.cooldown = 0, !.ring = FALSE], "dismiss", s.guard, {})
Next == (\E t \in Takes: (\E origin \in (IF Ingress = "socket" THEN {"socket"} ELSE {"F5", "socket"}): Record(t, origin))
          \/ (\E reason \in {"stop", "timeout"}: Capture(t, reason)) \/ Decode(t)
          \/ Complete(t) \/ Deliver(t) \/ DropDeferred(t) \/ Fail(t) \/ ReapCancelled(t) \/ Arm(t)
          \/ (\E origin \in {"click", "Escape"}, victim \in Takes: Cancel(t, origin, victim)))
        \/ Tick \/ DismissStaleGuard
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick)
        /\ (\A t \in Takes: WF_vars(Decode(t)) /\ WF_vars(Complete(t)) /\ WF_vars(Deliver(t)) /\ WF_vars(ReapCancelled(t)))
TypeOK == /\ s.stage \in [Takes -> Stages] /\ s.saved \subseteq Takes
          /\ s.deliveries \in [Takes -> 0..1] /\ s.floor \in [Takes -> 0..2]
          /\ s.guard \in Takes \cup {"none"} /\ s.cooldown \in 0..2 /\ s.ring \in BOOLEAN
          /\ s.violations \subseteq {"N6Start", "N6Preserve", "N7Scope", "N7Guard", "N8Immediate"}
OneMic == Cardinality(Mic) <= 1
OneDecoder == Cardinality(Worker) <= 1
N6StartsB == "N6Start" \notin s.violations
N6PreservesA == "N6Preserve" \notin s.violations
N7ScopedCancel == "N7Scope" \notin s.violations
N7GuardedClick == "N7Guard" \notin s.violations
N7CooldownRing == s.ring = (s.guard # "none" /\ s.cooldown > 0)
N8ImmediatePaste == "N8Immediate" \notin s.violations
N8FinalNotSuperseded == \A t \in Takes: s.stage[t] # "superseded"
D3EveryTakeKept == {t \in Takes: s.stage[t] \notin {"fresh", "recording"}} \subseteq s.saved
NoDuplicatePaste == \A t \in Takes: s.deliveries[t] <= 1
NoCancelledPaste == \A t \in Takes: s.stage[t] = "cancelled" => s.deliveries[t] = 0
ProcessingSettles == \A t \in Takes: s.stage[t] \in {"captured", "transcribing", "ready", "cancelling"}
                                      ~> s.stage[t] \in {"pasted", "cancelled", "failed", "superseded"}
=============================================================================
