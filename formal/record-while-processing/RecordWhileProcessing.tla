----------------------- MODULE RecordWhileProcessing -----------------------
\* Runtime projection: capture/drain -> recording, archived queue -> captured.
\* Complete is dispatch; RuntimeOwnership verifies bounded ACK settlement without
\* assuming a client acknowledgement. Cancel uses per-take AbortSignals.
EXTENDS Naturals, FiniteSets
CONSTANTS Admission, CancelPolicy, PastePolicy, RetentionPolicy, Ingress, Fault, SilenceLimit, CapLimit, Scenario
VARIABLE s
vars == <<s>>
Takes == {"A", "B"}
Origins == {"F5", "socket"}
Stages == {"fresh", "recording", "captured", "transcribing", "ready", "cancelling", "pasted", "cancelled", "failed", "superseded"}
Mic == {t \in Takes : s.stage[t] = "recording"}
Worker == {t \in Takes : s.stage[t] \in {"transcribing", "cancelling"}}
Ready == {t \in Takes : s.stage[t] = "ready"}
Active == Mic \cup Worker \cup Ready \cup {t \in Takes: s.stage[t]="captured"}
Unsettled == Active \cup {t \in Takes : s.stage[t] = "captured"}
Processing(t) == s.stage[t] \in {"captured", "transcribing", "ready"}
GuardReady(t) == s.guard = t /\ s.cooldown = 0
Newest(P) == IF "B" \in P THEN "B" ELSE IF "A" \in P THEN "A" ELSE "none"
Foreground(t, origin) == origin # "Escape" \/
  (IF Mic # {} THEN (t \in Mic \/ Fault="escape-mic") ELSE (t=Newest(Active) \/ Fault="escape-older"))
Shown == IF Worker # {} THEN CHOOSE t \in Worker: TRUE ELSE Newest(Active)
EscapeGuarded(t) == t \in Mic \/ t=Shown \/ GuardReady(t)
Commit(x, e, t) == s' = [x EXCEPT !.event = e, !.target = t, !.cancelToken = IF e \in {"click", "Escape"} THEN x.cancelToken ELSE "none"]
Init == s = [stage |-> [t \in Takes |-> "fresh"], saved |-> {}, cancelRequested |-> {},
             talking |-> [t \in Takes |-> FALSE], spoke |-> {},
             silence |-> [t \in Takes |-> 0], elapsed |-> [t \in Takes |-> 0], deliveries |-> [t \in Takes |-> IF Fault = "type" THEN 3 ELSE 0],
             floor |-> [t \in Takes |-> 0], guard |-> "none", cooldown |-> 0, ring |-> FALSE,
             event |-> "init", target |-> "none", requestId |-> "none", cancelToken |-> "none", reply |-> "none"]
Record(t, origin) ==
  LET blocked == Admission = "current" /\ (Worker # {} \/ (origin = "F5" /\ Ready # {}))
      owner == IF Worker # {} THEN CHOOSE a \in Worker: TRUE ELSE IF Ready # {} THEN CHOOSE a \in Ready: TRUE ELSE t
      cancels == (blocked /\ origin = "F5" /\ s.stage[owner] # "cancelling") \/ (Fault = "record-cancels" /\ Worker # {})
      after == IF cancels THEN [s EXCEPT !.stage[owner] = "cancelling", !.cancelRequested = @ \cup {owner}]
               ELSE IF blocked \/ (Fault = "reject-record" /\ Worker # {}) THEN s ELSE [s EXCEPT !.stage[t] = "recording"]
  IN /\ s.stage[t] = "fresh" /\ (Admission # "fixed" \/ t="A" \/ s.stage["A"] # "fresh") /\ (Scenario # "clock" \/ t = "A") /\ (Mic = {} \/ Fault = "two-mics")
     /\ (Fault # "stall-record" \/ Worker = {})
     /\ (Admission # "current" \/ {a \in Takes: s.stage[a] = "captured"} = {})
     /\ Commit([after EXCEPT !.reply = IF blocked THEN "reject" ELSE "accept"], origin, t)
\* ProductClock: one step = 60 seconds, silence 1, cap 20. No fairness on speech.
Talk(t, value) == /\ t \in Mic /\ s.talking[t] # value /\ (Fault # "no-speech" \/ ~value)
                  /\ Commit([s EXCEPT !.talking[t] = value, !.spoke = IF value THEN @ \cup {t} ELSE @,
                       !.silence[t] = IF value /\ Fault # "no-renew" THEN 0 ELSE @,
                       !.elapsed[t] = IF value /\ Fault = "cap-renew" THEN 0 ELSE @], IF value THEN "speech" ELSE "silence", t)
TimeoutDue(t) == ~s.talking[t] /\ s.silence[t] = SilenceLimit
CapDue(t) == s.elapsed[t] >= CapLimit
Capture(t, reason) == /\ t \in Mic
                     /\ (reason # "timeout" \/ (Fault # "no-timeout" /\
                          (Admission = "current" \/ Fault = "timeout-speaking" \/
                           (~s.talking[t] /\ (TimeoutDue(t) \/ Fault = "early-timeout")))))
                     /\ (reason # "cap" \/ (Admission # "current" /\ Fault # "no-cap" /\ CapDue(t) /\
                           (Fault # "cap-blocked-speaking" \/ ~s.talking[t])))
                     /\ Commit([s EXCEPT !.stage[t] = "captured", !.talking[t] = FALSE,
                                         !.silence[t] = 0, !.elapsed[t] = 0,
                                         !.saved = IF Fault = "drop-timeout" /\ reason = "timeout" THEN @ ELSE @ \cup {t}], reason, t)
Decode(t) == /\ s.stage[t] = "captured" /\ (Worker = {} \/ Fault = "two-decoders")
             /\ (Fault # "hold-decode" \/ t # "A" \/ Mic = {})
             /\ Commit([s EXCEPT !.stage[t] = "transcribing", !.floor[t] = 2], "decode", t)
Complete(t) ==
  LET cancelled == (s.stage[t] = "cancelling" \/ (CancelPolicy = "scoped" /\ t \in s.cancelRequested)) /\ Fault # "paste-after-cancel"
      delayed == PastePolicy = "current" /\ s.floor[t] > 0
        result == [s EXCEPT !.stage[t] = IF cancelled THEN "cancelled" ELSE IF delayed THEN "ready" ELSE "pasted",
                           !.deliveries[t] = IF cancelled \/ delayed THEN @ ELSE @ + 1]
      after == IF Fault = "result-stops-mic" THEN [result EXCEPT !.stage = [a \in Takes |-> IF a \in Mic THEN "captured" ELSE result.stage[a]]] ELSE result
  IN /\ s.stage[t] \in {"transcribing", "cancelling"}
     /\ (Fault # "hold-result" \/ Mic = {})
     /\ Commit(after, "result", t)
Deliver(t) == /\ s.stage[t] \in (IF Fault = "duplicate" THEN {"ready", "pasted"} ELSE {"ready"})
              /\ s.floor[t] = 0 /\ s.deliveries[t] < 2
              /\ Commit([s EXCEPT !.stage[t] = "pasted", !.deliveries[t] = @ + 1], "deliver", t)
DropDeferred(t) == /\ (Admission = "current" \/ Fault = "supersede") /\ s.stage[t] = "ready" /\ Mic # {}
                  /\ Commit([s EXCEPT !.stage[t] = "superseded"], "new-recording-event", t)
Fail(t) == /\ s.stage[t] = "transcribing" /\ Commit([s EXCEPT !.stage[t] = "failed"], "failure", t)
ReapCancelled(t) == /\ s.stage[t] = "cancelling" /\ Commit([s EXCEPT !.stage[t] = "cancelled"], "cancel-settled", t)
ApplyCancel(t, origin, id, victim) ==
  LET identityOK == CancelPolicy # "scoped" \/ Fault = "ignore-id" \/ id = t
      clear == s.guard = victim
      x == IF ~identityOK THEN [s EXCEPT !.reply = "noop", !.cancelToken = "none"] ELSE
           [s EXCEPT !.stage[victim] = IF @ \in {"transcribing", "cancelling"} THEN "cancelling" ELSE "cancelled",
                     !.cancelRequested = @ \cup {t},
                     !.cancelToken = IF Fault = "unscoped-signal" THEN "global" ELSE IF CancelPolicy # "scoped" THEN IF Mic = {} /\ Worker = {} THEN "none" ELSE "global" ELSE id,
                     !.saved = IF RetentionPolicy = "dropCancel" THEN @ ELSE @ \cup {victim},
                     !.talking[victim] = FALSE, !.silence[victim] = 0, !.elapsed[victim] = 0, !.guard = IF clear THEN "none" ELSE @,
                     !.cooldown = IF clear THEN 0 ELSE @, !.ring = IF clear THEN FALSE ELSE @,
                     !.reply = IF CancelPolicy # "scoped" /\ Mic = {} /\ Worker = {} THEN "noop" ELSE "accept"]
  IN /\ t \in Active /\ victim \in Active /\ Foreground(t, origin)
     /\ (CancelPolicy # "scoped" \/ victim = t \/ Fault = "wrong-victim")
     /\ (CancelPolicy = "scoped" \/ IF Mic \cup Worker = {} THEN victim = t ELSE victim \in Mic \cup Worker)
     /\ (origin # "Escape" \/ CancelPolicy # "scoped" \/ EscapeGuarded(t))
     /\ (origin # "click" \/ ~Processing(t) \/ CancelPolicy # "scoped" \/ GuardReady(t) \/ Fault = "unguarded")
     /\ (Fault # "stall-cancel" \/ ~(t = "B" /\ "A" \in Worker))
     /\ Commit([x EXCEPT !.requestId = id], origin, t)
Cancel(t, origin, id) == \E victim \in Takes: ApplyCancel(t, origin, id, victim)
Click(t) ==
  /\ t \in Active /\ (Fault # "stall-click" \/ ~Processing(t))
  /\ IF Processing(t) /\ CancelPolicy = "scoped" /\ ~GuardReady(t) /\ Fault # "unguarded"
     THEN Commit([s EXCEPT !.guard = t, !.cooldown = IF s.guard = t THEN s.cooldown ELSE 2,
                          !.ring = TRUE, !.reply = "guard"], "arm", t)
     ELSE Cancel(t, "click", t)
Escape(t,id) == /\ t \in Active /\ Foreground(t,"Escape")
                /\ IF CancelPolicy="scoped" /\ ~EscapeGuarded(t)
                    THEN Commit([s EXCEPT !.guard=t, !.cooldown=IF s.guard=t THEN s.cooldown ELSE 2, !.ring=TRUE, !.reply="guard"],"arm",t)
                    ELSE Cancel(t,"Escape",id)
\* Available deadline handlers are urgent with respect to clock advancement.
\* A broken/disabled handler lets time advance, so the bounded contracts expose it.
\* Pipeline checks use a short abstract cap; ProductClock and every timing
\* mutant run the same operators with the exact 1-minute / 20-minute ratio.
AdvanceElapsed(t) == IF s.elapsed[t] < CapLimit + 1 THEN s.elapsed[t] + 1 ELSE s.elapsed[t]
ClockCanAdvance == \A t \in Mic:
                    (Admission = "current" \/ ~(ENABLED Capture(t, "cap"))) /\
                    ~(Admission # "current" /\ ENABLED Capture(t, "timeout"))
Tick == /\ s.cooldown > 0 \/ (\E t \in Takes: s.floor[t] > 0) \/ (Mic # {} /\ ClockCanAdvance)
        /\ Commit([s EXCEPT !.cooldown = IF @ > 0 THEN @ - 1 ELSE 0,
                            !.ring = IF Fault = "ring" THEN @ ELSE s.guard # "none" /\ s.cooldown > 1,
                            !.floor = [t \in Takes |-> IF s.floor[t] > 0 THEN s.floor[t] - 1 ELSE 0],
                            !.silence = [t \in Takes |-> IF t \in Mic /\ ClockCanAdvance /\ ~s.talking[t]
                                          THEN IF s.silence[t] < SilenceLimit + 1 THEN s.silence[t] + 1 ELSE s.silence[t] ELSE s.silence[t]],
                            !.elapsed = [t \in Takes |-> IF t \in Mic /\ ClockCanAdvance
                                          THEN AdvanceElapsed(t) ELSE s.elapsed[t]]], "tick", "none")
DismissStaleGuard == /\ Fault # "stale-guard" /\ s.guard # "none" /\ s.guard \notin Active
                    /\ Commit([s EXCEPT !.guard = "none", !.cooldown = 0, !.ring = FALSE], "dismiss", s.guard)
Next == (\E t \in Takes:
          (\E origin \in (IF Ingress = "socket" THEN {"socket"} ELSE Origins): Record(t, origin))
          \/ (\E reason \in {"stop", "timeout", "cap"}: Capture(t, reason)) \/ (\E v \in BOOLEAN: Talk(t, v))
          \/ Decode(t) \/ Complete(t) \/ Deliver(t) \/ DropDeferred(t) \/ Fail(t) \/ ReapCancelled(t) \/ Click(t)
          \/ (\E id \in (IF CancelPolicy = "scoped" THEN {t, "stale"} ELSE Takes \cup {"stale"}): Escape(t, id))) \/ Tick \/ DismissStaleGuard
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(DismissStaleGuard)
        /\ (\A t \in Takes: (Fault = "unfair-decode" \/ WF_vars(Decode(t))) /\ (Fault = "unfair" \/ WF_vars(Complete(t)))
                            /\ WF_vars(Deliver(t)) /\ WF_vars(ReapCancelled(t))
                            /\ WF_vars(Capture(t, "timeout")) /\ WF_vars(Capture(t, "cap")))
TypeOK == /\ s.stage \in [Takes -> Stages] /\ s.saved \subseteq Takes /\ s.cancelRequested \subseteq Takes
          /\ s.spoke \subseteq Takes /\ s.silence \in [Takes -> 0..(SilenceLimit + 1)]
          /\ s.elapsed \in [Takes -> 0..(CapLimit + 1)]
          /\ s.talking \in [Takes -> BOOLEAN] /\ s.deliveries \in [Takes -> 0..2] /\ s.floor \in [Takes -> 0..2]
          /\ s.cancelToken \in Takes \cup {"none", "global"}
          /\ s.guard \in Takes \cup {"none"} /\ s.cooldown \in 0..2 /\ s.ring \in BOOLEAN
OneMic == Cardinality(Mic) <= 1
OneDecoder == Cardinality(Worker) <= 1
RequiredRecord(t) == s.stage[t] = "fresh" /\ Mic = {} /\ Worker # {}
N6Admissible == \A t \in Takes: RequiredRecord(t) => ENABLED Record(t, "F5")
N6StartsB == \A t \in Takes, origin \in Origins: RequiredRecord(t) =>
             /\ ENABLED Record(t, origin) /\ ~ENABLED (Record(t, origin) /\ s'.stage[t] # "recording")
N6PreservesA == \A t \in Takes, origin \in Origins: RequiredRecord(t) =>
             /\ ENABLED Record(t, origin)
             /\ ~ENABLED (Record(t, origin) /\ (s'.cancelRequested # s.cancelRequested \/
                           (\E a \in Worker: s'.stage[a] # s.stage[a])))
EligibleCancel(t, origin) == t \in Active /\ Foreground(t, origin) /\
                            (origin # "click" \/ ~Processing(t) \/ GuardReady(t)) /\
                            (origin # "Escape" \/ CancelPolicy # "scoped" \/ EscapeGuarded(t))
N7ScopedCancel == \A t \in Takes, origin \in {"click", "Escape"}: EligibleCancel(t, origin) =>
                  /\ ENABLED Cancel(t, origin, t)
                  /\ ~ENABLED (Cancel(t, origin, t) /\
                       ((\E a \in Takes \ {t}: s'.stage[a] # s.stage[a]) \/ s'.cancelRequested # s.cancelRequested \cup {t} \/ s'.cancelToken # t))
N7GuardedClick == \A t \in Takes: t \in Active =>
                  /\ ENABLED Click(t)
                  /\ (Processing(t) /\ ~GuardReady(t) => ~ENABLED (Click(t) /\ s'.cancelRequested # s.cancelRequested))
N7Identity == \A t \in Takes, origin \in {"click", "Escape"}: EligibleCancel(t, origin) =>
               ~ENABLED (Cancel(t, origin, "stale") /\ (s'.stage # s.stage \/ s'.cancelRequested # s.cancelRequested \/ s'.cancelToken # "none"))
N7CooldownRing == s.ring = (s.guard # "none" /\ s.cooldown > 0)
N8DecodeAdmissible == \A t \in Takes: s.stage[t] = "captured" /\ Worker = {} =>
                      /\ ENABLED Decode(t) /\ ~ENABLED (Decode(t) /\ Mic' # Mic)
N8ImmediatePaste == /\ N8DecodeAdmissible
                    /\ (\A t \in Takes: s.stage[t] = "transcribing" /\ t \notin s.cancelRequested =>
                         /\ ENABLED Complete(t)
                         /\ ~ENABLED (Complete(t) /\ (s'.deliveries[t] # s.deliveries[t] + 1 \/ Mic' # Mic)))
N8FinalNotSuperseded == \A t \in Takes: s.stage[t] # "superseded"
D3EveryTakeKept == {t \in Takes: s.stage[t] \notin {"fresh", "recording"}} \subseteq s.saved
NoTimeoutWhileTalking == \A t \in Takes: s.talking[t] => ~ENABLED Capture(t, "timeout")
NoDuplicatePaste == \A t \in Takes: s.deliveries[t] <= 1
NoCancelledPaste == \A t \in s.cancelRequested: s.deliveries[t] = 0
ProcessingSettles == \A t \in Takes: s.stage[t] \in {"captured", "transcribing", "ready", "cancelling"}
                                      ~> s.stage[t] \in {"pasted", "cancelled", "failed", "superseded"}
\* Progress starts at capture. Availability clauses forbid serializing decode/result
\* behind B's bounded recording; weak fairness alone cannot promise that ordering.
\* A single temporal formula keeps TLC's diagnostic bound to this property name,
\* rather than splitting out anonymous safety conjuncts from PROPERTIES.
OverlapPastes == ~(~((s.stage["A"] \in {"captured", "transcribing"} /\ s.stage["B"] = "recording")
                      ~> (s.deliveries["A"] = 1 \/ s.stage["A"] = "failed" \/ "A" \in s.cancelRequested))
                  \/ <>((s.stage["A"] = "captured" /\ Worker = {} /\ "B" \in Mic /\ ~ENABLED Decode("A"))
                     \/ (s.stage["A"] = "transcribing" /\ "B" \in Mic /\ "A" \notin s.cancelRequested /\ ~ENABLED Complete("A"))))
EventuallyIdle == (\A t \in Takes: s.stage[t] \notin {"fresh", "recording"}) ~> Unsettled = {}
SpeechRenewsDeadline == \A t \in Mic: ~s.talking[t] =>
                        /\ ENABLED Talk(t, TRUE)
                        /\ ~ENABLED (Talk(t, TRUE) /\ s'.silence[t] # 0)
NoEarlySilenceTimeout == \A t \in Mic: ~TimeoutDue(t) => ~ENABLED Capture(t, "timeout")
CaptureWithinCap == \A t \in Mic: s.elapsed[t] <= CapLimit
CapAlwaysFires == ~(~(\A t \in Takes: (t \in Mic) ~> (t \notin Mic))
                    \/ <>(\E t \in Mic: CapDue(t) /\ ~ENABLED Capture(t, "cap")))
SilenceTimesOut == ~(<>(\E t \in Mic: TimeoutDue(t) /\ ~CapDue(t) /\ ~ENABLED Capture(t, "timeout"))
                     \/ ~(\A t \in Takes: (t \in Mic /\ TimeoutDue(t)) ~> (t \notin Mic \/ s.talking[t])))
NoDecodeDuringRecording == ~(s.event = "decode" /\ s.target = "A" /\ s.stage["B"] = "recording")
NoSpeechSilenceTimeout == ~(s.event = "timeout" /\ s.target \in s.spoke)
NoOverlapPaste == ~(s.event = "result" /\ s.target = "A" /\ s.stage["B"] = "recording" /\ s.deliveries["A"] = 1)
NoScopedCancelDuringDecode == ~(s.event \in {"click", "Escape"} /\ s.target = "B" /\
                                s.stage["A"] = "transcribing" /\ "B" \in s.cancelRequested)
EscapeTargetsNewest == \A t \in Takes: t \in Active /\ t # (IF Mic # {} THEN CHOOSE m \in Mic: TRUE ELSE Newest(Active)) =>
  ~ENABLED Escape(t,t)
NoStaleGuard == (s.guard # "none" /\ s.guard \notin Active) ~> s.guard="none"
=============================================================================
