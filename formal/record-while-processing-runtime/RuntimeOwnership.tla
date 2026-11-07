----------------------- MODULE RuntimeOwnership -----------------------
EXTENDS Naturals, FiniteSets
CONSTANT Mutation
VARIABLE s
vars == <<s>>
Takes == {"A", "B"}
Mic == {t \in Takes: s.stage[t] \in {"recording", "draining"}}
Processing == {t \in Takes: s.stage[t] \in {"captured", "processing"}}
Waiting == {t \in Takes: s.stage[t]="waiting"}
CaptureIntents == Mic \cup Waiting
Active == CaptureIntents \cup Processing
Worker == {t \in Takes: s.stage[t] \in {"processing", "ack"}}
Newest(P) == IF "B" \in P THEN "B" ELSE IF "A" \in P THEN "A" ELSE "none"
Shown == IF Worker # {} THEN CHOOSE t \in Worker: TRUE ELSE Newest(Processing)
EscapeTarget == IF Waiting # {} THEN CHOOSE t \in Waiting: TRUE ELSE IF Mic # {} THEN CHOOSE t \in Mic: TRUE ELSE Newest(Processing)
Commit(x,e,t) == s' = [x EXCEPT !.event=e, !.target=t]
Init == s = [stage |-> [t \in Takes |-> "fresh"], capable |-> [t \in Takes |-> FALSE],
             age |-> [t \in Takes |-> 0], readable |-> [t \in Takes |-> TRUE], matches |-> [t \in Takes |-> TRUE],
             focusSame |-> TRUE, guard |-> "none", cooldown |-> 0,
             event |-> "init", target |-> "none", expected |-> "none",
             escapedGuarded |-> TRUE, notice |-> FALSE, captureReleased |-> TRUE]
Record(t,c,r) == /\ s.stage[t]="fresh" /\ Mic={} /\ Waiting={} /\ s.captureReleased /\ (t="A" \/ s.stage["A"] # "fresh")
               /\ Commit([s EXCEPT !.stage[t]="recording", !.captureReleased=FALSE, !.capable[t]=c, !.readable[t]=r], "record", t)
Stop(t) == /\ s.stage[t]="recording" /\ Commit([s EXCEPT !.stage[t]="draining"],"stop",t)
DrainEligible(t) == s.stage[t]="fresh" /\ Waiting={} /\
                    (t="A" \/ s.stage["A"] # "fresh") /\ (\E owner \in Mic: s.stage[owner]="draining")
DrainPress(t,c,r) == /\ DrainEligible(t)
                    /\ Commit([s EXCEPT !.stage[t]=IF Mutation \in {"rejectDrain","silentDrain"} THEN "fresh" ELSE "waiting",
                                          !.capable[t]=c, !.readable[t]=r,
                                          !.notice=Mutation # "silentDrain"],"drain-press",t)
StartQueued(t) == /\ t \in Waiting /\ Mic={} /\ s.captureReleased /\ Mutation # "stallQueued"
                  /\ Commit([s EXCEPT !.stage[t]="recording", !.captureReleased=FALSE],"start-queued",t)
Archive(t) == /\ s.stage[t]="draining" /\ Commit([s EXCEPT !.stage[t]="captured", !.captureReleased=TRUE],"archive",t)
ProveExit == /\ Mic={} /\ ~s.captureReleased /\ (\E t \in Takes: s.stage[t] \in {"failed","cancelled"})
             /\ Commit([s EXCEPT !.captureReleased=TRUE],"exit-proof","none")
Decode(t) == /\ s.stage[t]="captured" /\ Worker={}
             /\ Commit([s EXCEPT !.stage[t]="processing"],"decode",t)
ChangeTarget(t) == /\ s.stage[t]="processing" /\ s.readable[t] /\ s.matches[t]
                   /\ Commit([s EXCEPT !.matches[t]=FALSE],"target-change",t)
ChangeFocus == /\ s.focusSame /\ Commit([s EXCEPT !.focusSame=FALSE],"focus-change","none")
Complete(t) ==
  LET identityOK == IF s.readable[t] THEN (s.matches[t] \/ Mutation="retarget")
                    ELSE (CaptureIntents={} \/ Mutation="unreadableOverlap") /\ Mutation # "rejectUnreadable"
      allowed == identityOK /\ (s.focusSame \/ Mutation="stealFocus")
      wait == s.capable[t] \/ Mutation="legacyAck"
  IN /\ s.stage[t]="processing" /\ Mutation # "stall"
     /\ Commit([s EXCEPT !.stage[t]=IF allowed /\ wait THEN "ack" ELSE "done"],
               IF allowed THEN "deliver" ELSE "keep-history",t)
Ack(t) == /\ s.stage[t]="ack" /\ Commit([s EXCEPT !.stage[t]="done"],"ack",t)
AckTimeout(t) == /\ s.stage[t]="ack" /\ s.age[t]=2
                  /\ Commit([s EXCEPT !.stage[t]="done"],"unverified",t)
Arm(t) == /\ t \in Processing /\ s.guard # t
          /\ Commit([s EXCEPT !.guard=t, !.cooldown=2],"arm",t)
Escape(t) ==
  LET expected == EscapeTarget
      eligible == (Waiting={} \/ t \in Waiting \/ Mutation="escapeMic") /\
                  (CaptureIntents={} \/ t \in CaptureIntents \/ Mutation="escapeMic") /\
                  (CaptureIntents # {} \/ t=Newest(Processing) \/ Mutation="escapeOlder")
      guarded == t=Shown \/ t \in CaptureIntents \/ (s.guard=t /\ s.cooldown=0)
      after == [s EXCEPT !.stage[t]="cancelled", !.expected=expected, !.escapedGuarded=guarded,
                        !.guard=IF s.guard=t THEN "none" ELSE @]
  IN /\ t \in Active /\ eligible /\ (guarded \/ Mutation="unguardedEscape")
     /\ Commit(after,"Escape",t)
Click(t) == /\ t \in Active /\ ((t \in CaptureIntents /\ (Waiting={} \/ t \in Waiting)) \/ (t \in Processing /\ s.guard=t /\ s.cooldown=0))
            /\ Commit([s EXCEPT !.stage[t]="cancelled",
                         !.guard=IF s.guard=t THEN "none" ELSE @],"click",t)
Tick == /\ s.cooldown>0 \/ \E t \in Takes: s.stage[t]="ack" /\ s.age[t]<2
        /\ Commit([s EXCEPT !.cooldown=IF @>0 THEN @-1 ELSE 0,
                            !.age=[t \in Takes |-> IF s.stage[t]="ack" /\ s.age[t]<2 /\ Mutation # "noAckBound" THEN s.age[t]+1 ELSE s.age[t]]],"tick","none")
DismissStaleGuard == /\ Mutation # "staleGuard" /\ s.guard # "none" /\ s.guard \notin Active
                     /\ Commit([s EXCEPT !.guard="none"],"dismiss","none")
CaptureFailure(t) == /\ t \in Mic
                     /\ Commit([s EXCEPT !.stage[t]=IF Mutation="failedMic" THEN "recording" ELSE "failed", !.captureReleased=FALSE],"capture-failed",t)
MicReleaseOnFailure == s.event="capture-failed" => s.stage[s.target]="failed" /\ s.target \notin Mic
Next == (\E t \in Takes: (\E c,r \in BOOLEAN: Record(t,c,r) \/ DrainPress(t,c,r)) \/ StartQueued(t) \/ Stop(t) \/ Archive(t) \/ Decode(t)
         \/ CaptureFailure(t) \/ Complete(t) \/ Ack(t) \/ AckTimeout(t) \/ Arm(t) \/ Escape(t) \/ Click(t) \/ ChangeTarget(t))
        \/ Tick \/ DismissStaleGuard \/ ProveExit \/ ChangeFocus
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(DismissStaleGuard)
        /\ (\A t \in Takes: WF_vars(Archive(t)) /\ WF_vars(StartQueued(t)) /\ WF_vars(Decode(t)) /\ WF_vars(Complete(t)) /\ WF_vars(AckTimeout(t)))
EscapeTargetsNewest == s.event="Escape" => s.target=s.expected
GuardedEscape == s.event="Escape" => s.escapedGuarded
NoStaleGuard == (s.guard # "none" /\ s.guard \notin Active) ~> s.guard="none"
NoDeliveryOutsideCapturedTarget == s.event="deliver" =>
  IF s.readable[s.target] THEN s.matches[s.target] ELSE CaptureIntents={}
UnreadableIdentitySingleTakeDelivers == \A t \in Takes:
  (s.stage[t]="processing" /\ ~s.readable[t] /\ s.focusSame /\ CaptureIntents={}) =>
    /\ ENABLED Complete(t)
    /\ ~ENABLED (Complete(t) /\ s'.event # "deliver")
NoFocusStealDuringCapture == s.event="deliver" /\ CaptureIntents # {} => s.focusSame
DrainRequestVisible == s.event="drain-press" => s.notice /\ s.stage[s.target]="waiting"
N6StartsB == /\ \A t \in Takes, c,r \in BOOLEAN: DrainEligible(t) =>
                  /\ ENABLED DrainPress(t,c,r)
                  /\ ~ENABLED (DrainPress(t,c,r) /\ (s'.stage[t] # "waiting" \/
                       (\E owner \in Mic: s'.stage[owner] # s.stage[owner])))
             /\ \A t \in Waiting: (Mic={} /\ s.captureReleased) => ENABLED StartQueued(t)
QueuedCaptureStarts == \A t \in Takes:
  (s.stage[t]="waiting" /\ Mic={} /\ s.captureReleased) ~> s.stage[t] \in {"recording","draining","captured","processing","ack","done","cancelled","failed"}
LegacyNoAckWait == \A t \in Takes: s.stage[t]="ack" => s.capable[t]
DeliveryAckBound == \A t \in Takes: s.stage[t]="ack" ~> s.stage[t]="done"
ProcessingSettles == \A t \in Takes: s.stage[t] \in {"captured","processing","ack"} ~> s.stage[t] \in {"done","cancelled","failed"}
=============================================================================
