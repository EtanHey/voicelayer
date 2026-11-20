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
(* MCP tasks (T4): a task-capable Ask is answered at once with a task      *)
(* handle (TaskCall); tasks/get reads the task's row (TaskGet, its         *)
(* response possibly lost) and tasks/cancel moves a working task to        *)
(* cancelled (TaskCancel). The task row is durable and created in the same *)
(* transaction as its delivery row; its first terminal state wins.         *)
(*                                                                         *)
(* Callers are bridge capabilities. A restarted bridge is just another     *)
(* caller with no binding to the old rows, so it is covered by the         *)
(* cross-caller properties. Identical clientInfo/cwd/request ids carry no  *)
(* identity and are therefore not modelled; any caller may name any task.  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets
CONSTANTS Mutation, Callers, MaxOps, MaxCalls, MaxLeases, MaxCrashes, MaxReconnects
VARIABLES rows, nextOp, nextLease, crid, waiting, dreq, wire, inbox, acks, crashes, reconnects,
          tasks, tinbox, tcancelled
vars == <<rows, nextOp, nextLease, crid, waiting, dreq, wire, inbox, acks, crashes, reconnects,
          tasks, tinbox, tcancelled>>
taskVars == <<tasks, tinbox, tcancelled>>

Ops == 1..MaxOps
NoRow == [state |-> "none", owner |-> "none", archive |-> FALSE, did |-> 0, lease |-> 0]
NoTask == [state |-> "none", owner |-> "none"]
NoReq == [op |-> 0, rid |-> 0]
Plain(rid) == [rid |-> rid, op |-> 0, did |-> 0, lease |-> 0]

Init == /\ rows = [o \in Ops |-> NoRow]
        /\ nextOp = 1 /\ nextLease = 1
        /\ crid = [c \in Callers |-> 0] /\ waiting = [c \in Callers |-> FALSE]
        /\ dreq = [c \in Callers |-> NoReq]
        /\ wire = [c \in Callers |-> {}] /\ inbox = [c \in Callers |-> {}] /\ acks = [c \in Callers |-> {}]
        /\ crashes = 0 /\ reconnects = 0
        /\ tasks = [o \in Ops |-> NoTask] /\ tinbox = [c \in Callers |-> {}] /\ tcancelled = {}

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
  /\ UNCHANGED <<inbox, acks, crashes, reconnects>> /\ UNCHANGED taskVars

(* A task-capable Ask with nothing held: delivery row and task row begin together, and the call is answered *)
(* at once with the task handle; no request stays live for the flow. (With something held, the call takes   *)
(* Call(c, "ask")'s recovery path; a wait_seconds answer in time is Call's live response.)                 *)
TaskCall(c) ==
  /\ ~waiting[c] /\ crid[c] < MaxCalls /\ Held(c) = {} /\ nextOp <= MaxOps
  /\ crid' = [crid EXCEPT ![c] = @ + 1]
  /\ rows' = [rows EXCEPT ![nextOp] = [state |-> "pending", owner |-> c, archive |-> FALSE, did |-> nextOp, lease |-> 0]]
  \* CompleteOnAccept: the task reports completed before its Ask has any result.
  /\ tasks' = [tasks EXCEPT ![nextOp] = [state |-> IF Mutation = "CompleteOnAccept" THEN "completed" ELSE "working", owner |-> c]]
  /\ nextOp' = nextOp + 1
  /\ UNCHANGED <<nextLease, waiting, dreq, wire, inbox, acks, crashes, reconnects, tinbox, tcancelled>>

(* tasks/get by caller c naming task o. Only the owner's capability resolves it (TaskScopeLeak: keyed by the *)
(* task id alone). A completed task returns the normal Ask result: with a captured row that is a leased    *)
(* delivery receipt. The response may be lost (seen = FALSE); polling again re-reads it.                  *)
TaskGet(c, o, seen) ==
  /\ tasks[o].state = "completed"
  /\ tasks[o].owner = c \/ Mutation = "TaskScopeLeak"
  /\ IF rows[o].state = "ready"
     THEN /\ CanClaim(rows[o])
          /\ rows' = [rows EXCEPT ![o] = Written(rows[o])]
          /\ nextLease' = LeaseAfter(rows[o])
          /\ IF seen
             THEN /\ inbox' = IF \E e \in inbox[c] : e.did = Claimed(rows[o]).did THEN inbox
                              ELSE [inbox EXCEPT ![c] = @ \cup {[op |-> o, did |-> Claimed(rows[o]).did]}]
                  /\ acks' = [acks EXCEPT ![c] = @ \cup {[did |-> Claimed(rows[o]).did, lease |-> Claimed(rows[o]).lease]}]
             ELSE UNCHANGED <<inbox, acks>>
     ELSE UNCHANGED <<rows, nextLease, inbox, acks>>
  /\ tinbox' = IF seen THEN [tinbox EXCEPT ![c] = @ \cup {o}] ELSE tinbox
  /\ UNCHANGED <<nextOp, crid, waiting, dreq, wire, crashes, reconnects, tasks, tcancelled>>

(* tasks/cancel: a working task becomes cancelled (terminal). The Ask's abort makes its flow finalize later. *)
TaskCancel(c, o) ==
  /\ tasks[o].owner = c /\ tasks[o].state = "working"
  /\ tasks' = [tasks EXCEPT ![o].state = "cancelled"]
  /\ tcancelled' = tcancelled \cup {o}
  /\ UNCHANGED <<rows, nextOp, nextLease, crid, waiting, dreq, wire, inbox, acks, crashes, reconnects, tinbox>>

Archive(o) == /\ rows[o].state = "pending" /\ ~rows[o].archive
              /\ rows' = [rows EXCEPT ![o].archive = TRUE]
              /\ UNCHANGED <<nextOp, nextLease, crid, waiting, dreq, wire, inbox, acks, crashes, reconnects>>
              /\ UNCHANGED taskVars

(* The flow ends; nothing captured means nothing to recover (void). The original response is written only *)
(* to a live, uncancelled request on this connection. A working task completes in the same transaction;    *)
(* a cancelled one stays cancelled (CancelThenComplete: finalize overwrites it).                           *)
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
  /\ tasks' = [tasks EXCEPT ![o].state =
                 IF @ = "working" \/ (Mutation = "CancelThenComplete" /\ @ = "cancelled") THEN "completed" ELSE @]
  /\ UNCHANGED <<nextOp, crid, waiting, inbox, acks, crashes, reconnects, tinbox, tcancelled>>

(* A steer cancels the tool call. The client discards responses to that request id. *)
Interrupt(c) == /\ waiting[c]
                /\ waiting' = [waiting EXCEPT ![c] = FALSE] /\ wire' = [wire EXCEPT ![c] = {}]
                /\ dreq' = [dreq EXCEPT ![c] = NoReq] \* cancellation received (connection AND request id)
                /\ UNCHANGED <<rows, nextOp, nextLease, crid, inbox, acks, crashes, reconnects>> /\ UNCHANGED taskVars
InterruptUnseen(c) == /\ waiting[c]
                      /\ waiting' = [waiting EXCEPT ![c] = FALSE] /\ wire' = [wire EXCEPT ![c] = {}]
                      /\ UNCHANGED <<rows, nextOp, nextLease, crid, dreq, inbox, acks, crashes, reconnects>>
                      /\ UNCHANGED taskVars

(* The model reads a response to its current request; it deduplicates by delivery id. *)
Receive(c, m) ==
  /\ waiting[c] /\ m.rid = crid[c]
  /\ waiting' = [waiting EXCEPT ![c] = FALSE] /\ wire' = [wire EXCEPT ![c] = @ \ {m}]
  /\ IF m.op = 0 THEN UNCHANGED <<inbox, acks>>
     ELSE /\ inbox' = IF \E e \in inbox[c] : e.did = m.did THEN inbox
                      ELSE [inbox EXCEPT ![c] = @ \cup {[op |-> m.op, did |-> m.did]}]
          /\ acks' = [acks EXCEPT ![c] = @ \cup {[did |-> m.did, lease |-> m.lease]}]
  /\ UNCHANGED <<rows, nextOp, nextLease, crid, dreq, crashes, reconnects>> /\ UNCHANGED taskVars

(* Explicit ack: same caller, same delivery, current lease. A refused ack is simply spent. *)
Ack(c, a) ==
  /\ acks' = [acks EXCEPT ![c] = @ \ {a}]
  /\ rows' = [o \in Ops |-> IF rows[o].did = a.did /\ rows[o].owner = c /\ rows[o].state = "ready"
                               /\ rows[o].lease = a.lease
                            THEN [rows[o] EXCEPT !.state = "acked"] ELSE rows[o]]
  /\ UNCHANGED <<nextOp, nextLease, crid, waiting, dreq, wire, inbox, crashes, reconnects>> /\ UNCHANGED taskVars

(* Bridge-daemon reconnect: in-flight responses are lost, the request fails (never retried), leases drop. *)
(* Task rows are durable and the capability is unchanged, so tasks stay readable by their owner.          *)
Reconnect(c) ==
  /\ reconnects < MaxReconnects /\ reconnects' = reconnects + 1
  /\ waiting' = [waiting EXCEPT ![c] = FALSE] /\ wire' = [wire EXCEPT ![c] = {}]
  /\ dreq' = [dreq EXCEPT ![c] = NoReq]
  /\ rows' = [o \in Ops |-> IF rows[o].owner = c /\ rows[o].state = "ready" THEN [rows[o] EXCEPT !.lease = 0] ELSE rows[o]]
  /\ UNCHANGED <<nextOp, nextLease, crid, inbox, acks, crashes>> /\ UNCHANGED taskVars

(* Daemon crash: every connection and flow dies; durable rows survive. A pending row with an archive *)
(* becomes a ready pointer to it (its task completes); without one, nothing was captured (it fails).  *)
Crash ==
  /\ crashes < MaxCrashes /\ crashes' = crashes + 1
  /\ waiting' = [c \in Callers |-> FALSE] /\ wire' = [c \in Callers |-> {}] /\ dreq' = [c \in Callers |-> NoReq]
  /\ rows' = [o \in Ops |->
       IF rows[o].state = "pending"
       THEN [rows[o] EXCEPT !.state = IF rows[o].archive /\ Mutation # "CrashDrops" THEN "ready" ELSE "void", !.lease = 0]
       ELSE [rows[o] EXCEPT !.lease = 0]]
  /\ tasks' = [o \in Ops |->
       IF rows[o].state = "pending" /\ tasks[o].state = "working"
       THEN [tasks[o] EXCEPT !.state = IF rows[o].archive /\ Mutation # "CrashDrops" THEN "completed" ELSE "failed"]
       ELSE tasks[o]]
  /\ UNCHANGED <<nextOp, nextLease, crid, inbox, acks, reconnects, tinbox, tcancelled>>

Next == \/ \E c \in Callers : \/ Call(c, "ask") \/ Call(c, "other") \/ TaskCall(c)
                              \/ Interrupt(c) \/ InterruptUnseen(c) \/ Reconnect(c)
                              \/ \E m \in wire[c] : Receive(c, m)
                              \/ \E a \in acks[c] : Ack(c, a)
                              \/ \E o \in Ops : TaskCancel(c, o) \/ \E seen \in BOOLEAN : TaskGet(c, o, seen)
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
\* No task result (tasks/get) ever reaches a caller other than the one whose capability created the task.
NoTaskResultToOtherCaller == \A c \in Callers : \A o \in tinbox[c] : tasks[o].owner = c
\* A cancelled task never later completes (or fails): cancelled is terminal.
CancelledNeverCompletes == \A o \in tcancelled : tasks[o].state = "cancelled"
\* A task reports completed only once its Ask's row has left pending (its result exists).
TaskCompletesAfterRow == \A o \in Ops : tasks[o].state = "completed" => rows[o].state # "pending"
=============================================================================
