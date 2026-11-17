------------------------------ MODULE AskDelivery ------------------------------
(***************************************************************************)
(* Caller-bound Ask delivery (src/ask-delivery.ts, lane c7).               *)
(*                                                                         *)
(* Actors: the caller's calls and its interrupt (a steer cancelling the    *)
(* tool call, with or without the daemon receiving the cancellation), the  *)
(* capture flow (archive, finalize), the original response write, claim on *)
(* the next call, explicit ack, bridge reconnect and daemon crash. Rows    *)
(* are durable; wires, waiting calls and daemon requests are not.          *)
(*                                                                         *)
(* Callers are bridge capabilities. A restarted bridge is just another     *)
(* caller with no binding to the old rows, so it is covered by the         *)
(* cross-caller property. Identical clientInfo/cwd/request ids carry no    *)
(* identity and are therefore not modelled.                                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets
CONSTANTS Mutation, Callers, MaxOps, MaxCalls, MaxLeases, MaxCrashes, MaxReconnects
VARIABLES rows, nextOp, nextLease, crid, waiting, dreq, wire, inbox, acks, crashes, reconnects
vars == <<rows, nextOp, nextLease, crid, waiting, dreq, wire, inbox, acks, crashes, reconnects>>

Ops == 1..MaxOps
NoRow == [state |-> "none", owner |-> "none", archive |-> FALSE, did |-> 0, lease |-> 0]
NoReq == [op |-> 0, rid |-> 0]
Plain(rid) == [rid |-> rid, op |-> 0, did |-> 0, lease |-> 0]

Init == /\ rows = [o \in Ops |-> NoRow]
        /\ nextOp = 1 /\ nextLease = 1
        /\ crid = [c \in Callers |-> 0] /\ waiting = [c \in Callers |-> FALSE]
        /\ dreq = [c \in Callers |-> NoReq]
        /\ wire = [c \in Callers |-> {}] /\ inbox = [c \in Callers |-> {}] /\ acks = [c \in Callers |-> {}]
        /\ crashes = 0 /\ reconnects = 0

Unacked(o) == rows[o].state \in {"pending", "ready"}
\* ScopeLeak: recovery keyed by something other than the capability (clientInfo, cwd, newest archive).
Visible(c, o) == Unacked(o) /\ (rows[o].owner = c \/ Mutation = "ScopeLeak")
Held(c) == {o \in Ops : Visible(c, o)}
Oldest(c) == CHOOSE o \in Held(c) : \A p \in Held(c) : o <= p

\* Claim: keep a live lease, else lease afresh. NewIdPerClaim mints a new delivery id per copy.
Fresh(r) == Mutation = "NewIdPerClaim" \/ r.lease = 0
CanClaim(r) == ~Fresh(r) \/ nextLease <= MaxLeases
Claimed(r) == IF Mutation = "NewIdPerClaim" THEN [r EXCEPT !.lease = nextLease, !.did = MaxOps + nextLease]
              ELSE [r EXCEPT !.lease = IF r.lease # 0 THEN r.lease ELSE nextLease]
\* DeleteOnWrite: treat the response write as delivery.
Written(r) == IF Mutation = "DeleteOnWrite" THEN [Claimed(r) EXCEPT !.state = "acked"] ELSE Claimed(r)
LeaseAfter(r) == IF Fresh(r) THEN nextLease + 1 ELSE nextLease
Msg(rid, r) == [rid |-> rid, op |-> 0, did |-> Claimed(r).did, lease |-> Claimed(r).lease]
Delivery(rid, o, r) == [Msg(rid, r) EXCEPT !.op = o]

(* A voice call. Admission is one transaction: recovery first, then (for an Ask) begin. *)
Call(c, kind) ==
  /\ ~waiting[c] /\ crid[c] < MaxCalls
  /\ LET rid == crid[c] + 1 IN
     /\ crid' = [crid EXCEPT ![c] = rid] /\ waiting' = [waiting EXCEPT ![c] = TRUE]
     /\ IF Held(c) # {} /\ ~(Mutation = "AdmitWhilePending" /\ kind = "ask" /\ rows[Oldest(c)].state = "pending")
        THEN LET o == Oldest(c) IN
             IF rows[o].state = "ready"
             THEN /\ CanClaim(rows[o])
                  /\ rows' = [rows EXCEPT ![o] = Written(rows[o])]
                  /\ nextLease' = LeaseAfter(rows[o])
                  /\ wire' = [wire EXCEPT ![c] = @ \cup {Delivery(rid, o, rows[o])}]
                  /\ UNCHANGED <<nextOp, dreq>>
             ELSE /\ wire' = [wire EXCEPT ![c] = @ \cup {Plain(rid)}] \* pending status; no capture opens
                  /\ UNCHANGED <<rows, nextOp, nextLease, dreq>>
        ELSE IF kind = "ask"
             THEN /\ nextOp <= MaxOps
                  /\ rows' = [rows EXCEPT ![nextOp] = [state |-> "pending", owner |-> c, archive |-> FALSE,
                                                         did |-> nextOp, lease |-> 0]]
                  /\ nextOp' = nextOp + 1
                  /\ dreq' = [dreq EXCEPT ![c] = [op |-> nextOp, rid |-> rid]]
                  /\ UNCHANGED <<wire, nextLease>>
             ELSE /\ wire' = [wire EXCEPT ![c] = @ \cup {Plain(rid)}] \* the new action runs
                  /\ UNCHANGED <<rows, nextOp, nextLease, dreq>>
  /\ UNCHANGED <<inbox, acks, crashes, reconnects>>

Archive(o) == /\ rows[o].state = "pending" /\ ~rows[o].archive
              /\ rows' = [rows EXCEPT ![o].archive = TRUE]
              /\ UNCHANGED <<nextOp, nextLease, crid, waiting, dreq, wire, inbox, acks, crashes, reconnects>>

(* The flow ends; nothing captured means nothing to recover (void). The original response is written only *)
(* to a live, uncancelled request on this connection.                                                      *)
Finalize(o) ==
  /\ rows[o].state = "pending"
  /\ LET c == rows[o].owner
         done == [rows[o] EXCEPT !.state = IF rows[o].archive THEN "ready" ELSE "void"]
         live == dreq[c].op = o
     IN IF live /\ done.state = "ready"
        THEN /\ CanClaim(done)
             /\ rows' = [rows EXCEPT ![o] = Written(done)]
             /\ nextLease' = LeaseAfter(done)
             /\ wire' = [wire EXCEPT ![c] = @ \cup {Delivery(dreq[c].rid, o, done)}]
             /\ dreq' = [dreq EXCEPT ![c] = NoReq]
        ELSE /\ rows' = [rows EXCEPT ![o] = done]
             /\ wire' = IF live THEN [wire EXCEPT ![c] = @ \cup {Plain(dreq[c].rid)}] ELSE wire
             /\ dreq' = IF live THEN [dreq EXCEPT ![c] = NoReq] ELSE dreq
             /\ UNCHANGED nextLease
  /\ UNCHANGED <<nextOp, crid, waiting, inbox, acks, crashes, reconnects>>

(* A steer cancels the tool call. The client discards responses to that request id. *)
Interrupt(c) == /\ waiting[c]
                /\ waiting' = [waiting EXCEPT ![c] = FALSE] /\ wire' = [wire EXCEPT ![c] = {}]
                /\ dreq' = [dreq EXCEPT ![c] = NoReq] \* cancellation received (connection AND request id)
                /\ UNCHANGED <<rows, nextOp, nextLease, crid, inbox, acks, crashes, reconnects>>
InterruptUnseen(c) == /\ waiting[c]
                      /\ waiting' = [waiting EXCEPT ![c] = FALSE] /\ wire' = [wire EXCEPT ![c] = {}]
                      /\ UNCHANGED <<rows, nextOp, nextLease, crid, dreq, inbox, acks, crashes, reconnects>>

(* The model reads a response to its current request; it deduplicates by delivery id. *)
Receive(c, m) ==
  /\ waiting[c] /\ m.rid = crid[c]
  /\ waiting' = [waiting EXCEPT ![c] = FALSE] /\ wire' = [wire EXCEPT ![c] = @ \ {m}]
  /\ IF m.op = 0 THEN UNCHANGED <<inbox, acks>>
     ELSE /\ inbox' = IF \E e \in inbox[c] : e.did = m.did THEN inbox
                      ELSE [inbox EXCEPT ![c] = @ \cup {[op |-> m.op, did |-> m.did]}]
          /\ acks' = [acks EXCEPT ![c] = @ \cup {[did |-> m.did, lease |-> m.lease]}]
  /\ UNCHANGED <<rows, nextOp, nextLease, crid, dreq, crashes, reconnects>>

(* Explicit ack: same caller, same delivery, current lease. A refused ack is simply spent. *)
Ack(c, a) ==
  /\ acks' = [acks EXCEPT ![c] = @ \ {a}]
  /\ rows' = [o \in Ops |-> IF rows[o].did = a.did /\ rows[o].owner = c /\ rows[o].state = "ready"
                               /\ rows[o].lease = a.lease
                            THEN [rows[o] EXCEPT !.state = "acked"] ELSE rows[o]]
  /\ UNCHANGED <<nextOp, nextLease, crid, waiting, dreq, wire, inbox, crashes, reconnects>>

(* Bridge-daemon reconnect: in-flight responses are lost, the request fails (never retried), leases drop. *)
Reconnect(c) ==
  /\ reconnects < MaxReconnects /\ reconnects' = reconnects + 1
  /\ waiting' = [waiting EXCEPT ![c] = FALSE] /\ wire' = [wire EXCEPT ![c] = {}]
  /\ dreq' = [dreq EXCEPT ![c] = NoReq]
  /\ rows' = [o \in Ops |-> IF rows[o].owner = c /\ rows[o].state = "ready" THEN [rows[o] EXCEPT !.lease = 0] ELSE rows[o]]
  /\ UNCHANGED <<nextOp, nextLease, crid, inbox, acks, crashes>>

(* Daemon crash: every connection and flow dies; durable rows survive. A pending row with an archive *)
(* becomes a ready pointer to it; without one, nothing was captured.                                 *)
Crash ==
  /\ crashes < MaxCrashes /\ crashes' = crashes + 1
  /\ waiting' = [c \in Callers |-> FALSE] /\ wire' = [c \in Callers |-> {}] /\ dreq' = [c \in Callers |-> NoReq]
  /\ rows' = [o \in Ops |->
       IF rows[o].state = "pending"
       THEN [rows[o] EXCEPT !.state = IF rows[o].archive /\ Mutation # "CrashDrops" THEN "ready" ELSE "void", !.lease = 0]
       ELSE [rows[o] EXCEPT !.lease = 0]]
  /\ UNCHANGED <<nextOp, nextLease, crid, inbox, acks, reconnects>>

Next == \/ \E c \in Callers : \/ Call(c, "ask") \/ Call(c, "other")
                              \/ Interrupt(c) \/ InterruptUnseen(c) \/ Reconnect(c)
                              \/ \E m \in wire[c] : Receive(c, m)
                              \/ \E a \in acks[c] : Ack(c, a)
        \/ \E o \in Ops : Archive(o) \/ Finalize(o)
        \/ Crash
Spec == Init /\ [][Next]_vars

PendingOf(c) == {o \in Ops : rows[o].owner = c /\ rows[o].state = "pending"}
ReadyOf(c) == {o \in Ops : rows[o].owner = c /\ rows[o].state = "ready"}

\* No caller ever reads another caller's Ask (including a restarted bridge reading its predecessor's).
NoCrossCallerDelivery == \A c \in Callers : \A e \in inbox[c] : rows[e.op].owner = c
\* Only a delivery the owner actually read can be acknowledged, and a captured Ask is never dropped.
NoLossBeforeAck == \A o \in Ops :
  /\ rows[o].state = "acked" => \E e \in inbox[rows[o].owner] : e.op = o
  /\ rows[o].archive => rows[o].state \in {"pending", "ready", "acked"}
\* At-least-once copies carry one delivery id, so the caller's inbox holds each Ask once.
NoDoubleInboxInsertion == \A c \in Callers : \A o \in Ops : Cardinality({e \in inbox[c] : e.op = o}) <= 1
\* While an earlier Ask is unacknowledged, no second capture opens for that caller.
NoNewCaptureWhileRecovering == \A c \in Callers :
  /\ Cardinality(PendingOf(c)) <= 1
  /\ PendingOf(c) # {} => ReadyOf(c) = {}
=============================================================================
