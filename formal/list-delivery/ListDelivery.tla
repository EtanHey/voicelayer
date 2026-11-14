--------------------------- MODULE ListDelivery ---------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC
CONSTANTS Mutation, ListText, Segments, Deadline, Deliveries, Silent, GenReliable, QueueCapacity
VARIABLES d, app, element, secure, worker, reply, outcomes, receipts,
          closed, recording, watchdog, quitting, draining, bad, queue, arrived, history, late
vars == <<d, app, element, secure, worker, reply, outcomes, receipts,
          closed, recording, watchdog, quitting, draining, bad, queue, arrived, history, late>>
Text == [i \in 1..(2 * Segments) |-> i]
Empty == [id |-> 0, step |-> 0, kind |-> "none", same |-> FALSE, target |-> 0,
          aged |-> FALSE, reading |-> "unknown", landed |-> FALSE, marker |-> FALSE]
Delivery(id, capturedApp) == [id |-> id, active |-> TRUE, phase |-> IF ListText THEN "capture" ELSE "batch",
  capturedApp |-> capturedApp, genChanged |-> FALSE, step |-> 1, time |-> 0, posts |-> 0, ax |-> 0, target |-> 0, pos |-> 1, reached |-> <<>>, doubled |-> {},
  drop |-> FALSE, supplied |-> FALSE, fallback |-> FALSE,
  editor |-> "none", visible |-> FALSE]
Init == /\ d = Delivery(1, 0) /\ app = 0 /\ element = 0 /\ secure = FALSE
        /\ queue = <<>> /\ arrived = {1} /\ history = [i \in 1..Deliveries |-> <<>>] /\ late = 0
        /\ worker = Empty /\ reply = Empty
        /\ outcomes = [i \in 1..Deliveries |-> "none"]
        /\ receipts = [i \in 1..Deliveries |-> 0] /\ closed = {}
        /\ recording = FALSE /\ watchdog = FALSE /\ quitting = FALSE /\ draining = FALSE
        /\ bad = [wrongApp |-> FALSE, fresh |-> FALSE, lost |-> FALSE, slow |-> FALSE,
                   ax |-> FALSE, plain |-> FALSE, outcome |-> FALSE]
Waiting == d.active /\ (worker.kind # "none" \/ reply.kind # "none")
Blocked == Mutation = "MainWait" /\ d.active /\ worker.kind # "none"
Fresh(r) == r.id = d.id /\ r.step = d.step /\ r.kind = "check" /\ r.same /\ ~r.aged
AppGuard == app = d.capturedApp /\ ~secure /\ (~GenReliable \/ ~d.genChanged)
CanRecord == ~Blocked /\ ~(Mutation = "BlockRecording" /\ Waiting)
Record == /\ CanRecord /\ recording' = ~recording
          /\ UNCHANGED <<d, app, element, secure, worker, reply, outcomes, receipts,
                         closed, watchdog, quitting, draining, bad, queue, arrived, history, late>>
Watch == /\ ~Blocked /\ watchdog' = ~watchdog
         /\ UNCHANGED <<d, app, element, secure, worker, reply, outcomes, receipts,
                        closed, recording, quitting, draining, bad, queue, arrived, history, late>>
Finish(reason) ==
  LET partial == d.pos > 1 /\ d.pos <= Len(Text)
      result == IF reason = "posted" \/ d.pos > Len(Text) THEN "posted" ELSE IF d.pos = 1 THEN "refused" ELSE "partial"
      reported == IF Mutation = "PartialPosted" /\ partial THEN "posted" ELSE result
      count == IF Mutation = "TwoReceipts" THEN 2 ELSE
               IF Mutation = "NoQuitReceipt" /\ reason = "quit" THEN 0 ELSE 1
      cancelled == IF reason \in {"quit", "drain"} THEN {queue[i] : i \in 1..Len(queue)} ELSE {}
  IN /\ d' = [d EXCEPT !.active = FALSE, !.phase = "done"]
     /\ outcomes' = [i \in 1..Deliveries |-> IF i = d.id THEN reported ELSE IF i \in cancelled THEN "refused" ELSE outcomes[i]]
     /\ receipts' = [i \in 1..Deliveries |-> IF i = d.id THEN receipts[i] + (IF d.active THEN count ELSE 0) ELSE IF i \in cancelled THEN 1 ELSE receipts[i]]
     /\ closed' = closed \cup {d.id} \cup cancelled
     /\ queue' = IF cancelled = {} THEN queue ELSE <<>>
     /\ history' = [i \in 1..Deliveries |-> IF i = d.id \/ i \in cancelled THEN Text ELSE history[i]]
     /\ bad' = [bad EXCEPT !.outcome = @ \/ (reported # (IF d.pos = 1 THEN "refused" ELSE IF partial THEN "partial" ELSE "posted")),
                 !.plain = @ \/ (~ListText /\ reason = "posted" /\ (d.ax # 0 \/ d.posts # 1))]
Post(r, batch) ==
  LET segmented == ~batch
      appBypass == (Mutation = "FirstUnguarded" /\ d.posts = 0 /\ segmented)
             \/ (Mutation = "FallbackUnguarded" /\ d.fallback /\ segmented)
             \/ (Mutation = "CheckAwaitPost" /\ segmented)
             \/ (Mutation = "BatchUnguarded" /\ batch)
      checkBypass == Mutation = "Stale" /\ r.kind = "check" /\ r.same /\ ~r.aged
      ageBypass == Mutation = "AgedCheck" /\ Fresh([r EXCEPT !.aged = FALSE])
      allowed == ~secure /\ (AppGuard \/ appBypass) /\ (~segmented \/ Fresh(r) \/ checkBypass \/ ageBypass)
      end == IF batch \/ d.fallback \/ d.time = Deadline THEN Len(Text) ELSE 2 * d.step
      dropping == (d.drop /\ d.time < Deadline) \/ (Mutation = "DropSlow" /\ d.time = Deadline /\ d.posts > 0)
      omitted == dropping /\ ~d.supplied
      chunk == IF omitted THEN SubSeq(Text, d.pos + 1, end) ELSE SubSeq(Text, d.pos, end)
  IN IF allowed THEN
       \E built \in BOOLEAN : IF ~built THEN Finish("failed") ELSE
       /\ d' = [d EXCEPT !.reached = @ \o chunk, !.pos = end + 1,
                  !.doubled = IF d.editor = "marker" /\ ~dropping THEN @ \cup {d.step} ELSE @,
                  !.posts = @ + 1, !.step = @ + 1, !.drop = FALSE,
                  !.supplied = FALSE, !.phase = IF end = Len(Text) THEN "finish" ELSE "read",
                  !.editor = IF end = Len(Text) THEN "none" ELSE "pending", !.visible = FALSE]
       /\ bad' = [bad EXCEPT !.wrongApp = @ \/ ~AppGuard,
          !.fresh = @ \/ (segmented /\ ~Fresh(r)),
          !.lost = @ \/ omitted, !.slow = @ \/ omitted,
          !.plain = @ \/ (~ListText /\ (segmented \/ d.ax # 0))]
       /\ UNCHANGED <<outcomes, receipts, closed, queue, history>>
     ELSE Finish("refused")
Issue(kind) == /\ (Mutation # "CheckAwaitPost" \/ kind # "check" \/ AppGuard)
  /\ worker.kind = "none" /\ reply.kind = "none"
  /\ worker' = [Empty EXCEPT !.id = d.id, !.step = d.step, !.kind = kind]
  /\ d' = [d EXCEPT !.ax = IF @ < 2 THEN @ + 1 ELSE @]
  /\ bad' = [bad EXCEPT !.ax = @ \/ d.time = Deadline]
  /\ UNCHANGED <<reply, outcomes, receipts, closed, queue, history>>
Handle(r) ==
  CASE d.phase = "capture" ->
         /\ d' = [d EXCEPT !.phase = IF r.same THEN "check" ELSE "batch", !.target = r.target]
         /\ UNCHANGED <<outcomes, receipts, closed, bad, queue, history>>
    [] d.phase = "read" ->
         /\ d' = [d EXCEPT !.phase = "check", !.fallback = ~(r.reading = "inserted" /\ r.same),
              !.drop = (r.reading = "inserted" /\ (r.same \/ Mutation = "ForeignRead")) \/ Mutation = "DropUnknown",
              !.supplied = r.reading = "inserted" /\ r.same /\ r.landed /\ r.marker]
         /\ UNCHANGED <<outcomes, receipts, closed, bad, queue, history>>
    [] d.phase = "check" ->
         IF r.aged /\ Mutation # "AgedCheck" THEN UNCHANGED <<d, outcomes, receipts, closed, bad, queue, history>>
         ELSE Post(r, FALSE)
    [] OTHER -> /\ UNCHANGED <<d, outcomes, receipts, closed, bad, queue, history>>
ActiveMain == /\ d.active /\ ~Blocked
  /\ late' = late + (IF d.time = Deadline THEN 1 ELSE 0)
  /\ UNCHANGED <<app, element, secure, recording, watchdog, quitting, draining, arrived>>
  /\ CASE d.phase = "finish" -> /\ Finish("posted") /\ UNCHANGED <<worker, reply>>
       [] d.phase # "finish" /\ d.time = Deadline /\ Mutation \notin {"NoDeadline", "LateMain"} ->
           /\ IF Mutation = "LateAX" /\ worker.kind = "none" /\ reply.kind = "none"
                 THEN /\ Issue(d.phase) /\ UNCHANGED reply
                 ELSE /\ IF d.phase = "capture" \/ d.phase = "batch"
                               THEN Post(Empty, TRUE)
                               ELSE IF d.phase = "check" /\ Fresh(reply)
                                    THEN Post(reply, FALSE) ELSE Finish("refused")
                      /\ UNCHANGED <<worker, reply>>
       [] d.time < Deadline /\ d.phase = "batch" /\ ~(Mutation = "PlainList" /\ ~ListText) ->
           /\ Post(Empty, TRUE) /\ UNCHANGED <<worker, reply>>
       [] d.time < Deadline /\ d.phase = "batch" /\ Mutation = "PlainList" /\ ~ListText ->
           /\ d' = [d EXCEPT !.phase = "capture"]
           /\ UNCHANGED <<worker, reply, outcomes, receipts, closed, bad, queue, history>>
       [] d.phase \notin {"finish", "batch"} /\ (d.time < Deadline \/ Mutation = "LateMain") /\ reply.kind # "none" ->
           /\ IF reply.id = d.id /\ reply.step = d.step
                  THEN Handle(reply)
                  ELSE IF Mutation = "Stale" /\ d.phase = "check"
                       THEN Post(reply, FALSE) ELSE UNCHANGED <<d, outcomes, receipts, closed, bad, queue, history>>
           /\ reply' = Empty /\ UNCHANGED worker
       [] d.phase \notin {"finish", "batch"} /\ (d.time < Deadline \/ Mutation = "LateMain") /\ reply.kind = "none" -> /\ Issue(d.phase) /\ UNCHANGED reply
       [] OTHER -> FALSE
Worker == /\ ~Silent /\ worker.kind # "none" /\ reply.kind = "none"
  /\ \E readable \in BOOLEAN, foreign \in {"inserted", "plain", "unknown"} :
       /\ reply' = IF worker.id # d.id THEN
          [Empty EXCEPT !.id = worker.id, !.step = worker.step, !.kind = worker.kind, !.same = TRUE]
          ELSE [worker EXCEPT !.same = readable /\ (worker.kind = "capture" \/ element = d.target),
          !.target = IF worker.kind = "capture" THEN element ELSE 0,
          !.reading = IF worker.kind = "read" /\ element # d.target THEN foreign
                 ELSE IF readable /\ worker.kind = "read" /\ d.visible /\ d.editor = "marker" THEN "inserted"
                 ELSE IF readable /\ worker.kind = "read" /\ d.visible /\ d.editor = "plain" THEN "plain"
                 ELSE IF Mutation = "PreBreak" /\ worker.kind = "read" /\ d.editor = "pending"
                      THEN "inserted" ELSE "unknown",
          !.landed = worker.kind = "read" /\ element = d.target /\ d.editor \in {"marker", "plain"}, !.marker = worker.kind = "read" /\ element = d.target /\ d.editor = "marker"]
       /\ worker' = Empty
  /\ UNCHANGED <<d, app, element, secure, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad, queue, arrived, history, late>>
\* Models duplicate/late callbacks as well as a genuine outstanding old worker.
Late == /\ d.active /\ d.phase = "check" /\ reply.kind = "none"
  /\ \E id \in 0..d.id, step \in 0..d.step :
      /\ (id # d.id \/ step # d.step)
      /\ reply' = [Empty EXCEPT !.id = id, !.step = step, !.kind = "check", !.same = TRUE]
  /\ UNCHANGED <<d, app, element, secure, worker, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad, queue, arrived, history, late>>
User == /\ \E a, e \in {0, 1}, s \in BOOLEAN :
            /\ app' = a /\ element' = e /\ secure' = s
            /\ d' = [d EXCEPT !.genChanged = GenReliable /\ (@ \/ a # app \/ e # element)]
        /\ UNCHANGED << worker, reply, outcomes, receipts, closed, recording, watchdog, quitting, draining, bad, queue, arrived, history, late>>
Editor == /\ d.active /\ d.editor = "pending"
  /\ \E value \in {"marker", "plain"} : d' = [d EXCEPT !.editor = value]
  /\ UNCHANGED <<app, element, secure, worker, reply, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad, queue, arrived, history, late>>
Visible == /\ d.active /\ d.editor \in {"marker", "plain"} /\ ~d.visible
  /\ d' = [d EXCEPT !.visible = TRUE]
  /\ UNCHANGED <<app, element, secure, worker, reply, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad, queue, arrived, history, late>>
Clock == /\ d.active /\ d.time < Deadline /\ d' = [d EXCEPT !.time = @ + 1]
  /\ reply' = (IF reply.kind # "none" THEN [reply EXCEPT !.aged = TRUE] ELSE reply)
  /\ UNCHANGED <<app, element, secure, worker, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad, queue, arrived, history, late>>
Quit == /\ (d.active \/ Len(queue) > 0) /\ ~Blocked /\ Finish("quit") /\ quitting' = TRUE
  /\ UNCHANGED <<app, element, secure, worker, reply, recording, watchdog, draining, arrived, late>>
Drain == /\ (d.active \/ Len(queue) > 0) /\ ~Blocked /\ ~draining /\ draining' = TRUE
  /\ (IF Mutation = "DrainWorker" /\ Waiting
         THEN UNCHANGED <<d, outcomes, receipts, closed, bad, queue, history>> ELSE Finish("drain"))
  /\ UNCHANGED <<app, element, secure, worker, reply, recording, watchdog, quitting, arrived, late>>
Arrive == /\ Cardinality(arrived) < Deliveries /\ Len(queue) < QueueCapacity /\ ~quitting /\ ~draining
  /\ LET id == Cardinality(arrived) + 1 IN
       /\ queue' = Append(queue, id) /\ arrived' = arrived \cup {id}
  /\ UNCHANGED <<d, app, element, secure, worker, reply, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad, history, late>>
StartNext == /\ ~d.active /\ Len(queue) > 0 /\ ~quitting /\ ~draining
  /\ d' = Delivery(Head(queue), app) /\ queue' = Tail(queue) /\ late' = 0
  /\ UNCHANGED <<app, element, secure, worker, reply, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad, arrived, history>>
Main == ActiveMain \/ StartNext
Next == Main \/ User \/ Worker \/ Late \/ Editor \/ Visible \/ Clock \/ Quit \/ Drain \/ Arrive \/ Record \/ Watch
Spec == Init /\ [][Next]_vars /\ WF_vars(Main) /\ WF_vars(Clock)
NoPostToChangedApp == ~bad.wrongApp
NoSegmentWithoutFreshCheck == ~bad.fresh
MainNeverWaits == Waiting => (ENABLED Record /\ ENABLED Watch /\ ENABLED Quit)
BoundedDelivery == \A id \in 1..Deliveries : (id \in arrived) ~> (id \in closed)
NoLostCharacter == ~bad.lost /\ d.reached \o SubSeq(Text, d.pos, Len(Text)) = Text
SlowNeverLoses == (Silent \/ d.time = Deadline) => NoLostCharacter
DeadlineBound == late <= 2 /\ d.posts <= Segments
NoAXAfterExpiry == ~bad.ax
PlainTextUntouched == ~bad.plain /\ (~ListText => d.ax = 0)
ExactlyOneOutcome == ~bad.outcome
  /\ arrived = closed \cup {queue[i] : i \in 1..Len(queue)} \cup (IF d.active THEN {d.id} ELSE {})
  /\ Len(queue) <= QueueCapacity
  /\ \A id \in 1..Deliveries :
  IF id \in closed THEN outcomes[id] # "none" /\ receipts[id] = 1 /\ history[id] = Text
  ELSE outcomes[id] = "none" /\ receipts[id] = 0
RecordingNeverBlocked == ENABLED Record
DrainBounded == draining => ~d.active /\ queue = <<>>
=============================================================================
