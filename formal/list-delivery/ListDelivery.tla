--------------------------- MODULE ListDelivery ---------------------------
EXTENDS Naturals, Sequences, TLC
CONSTANTS Mutation, ListText, Segments, Deadline, Deliveries, Silent
VARIABLES d, app, element, secure, worker, reply, outcomes, receipts,
          closed, recording, watchdog, quitting, draining, bad
vars == <<d, app, element, secure, worker, reply, outcomes, receipts,
          closed, recording, watchdog, quitting, draining, bad>>
Text == [i \in 1..(2 * Segments) |-> i]
Empty == [id |-> 0, step |-> 0, kind |-> "none", same |-> FALSE, target |-> 0,
          reading |-> "unknown", landed |-> FALSE, marker |-> FALSE]
Delivery(id) == [id |-> id, active |-> TRUE, phase |-> IF ListText THEN "capture" ELSE "batch",
  step |-> 1, time |-> 0, posts |-> 0, ax |-> 0, target |-> 0, pos |-> 1, reached |-> <<>>, doubled |-> {},
  drop |-> FALSE, supplied |-> FALSE, fallback |-> FALSE,
  editor |-> "none", visible |-> FALSE]
Init == /\ d = Delivery(1) /\ app = 0 /\ element = 0 /\ secure = FALSE
        /\ worker = Empty /\ reply = Empty
        /\ outcomes = [i \in 1..Deliveries |-> "none"]
        /\ receipts = [i \in 1..Deliveries |-> 0] /\ closed = {}
        /\ recording = FALSE /\ watchdog = FALSE /\ quitting = FALSE /\ draining = FALSE
        /\ bad = [wrongApp |-> FALSE, fresh |-> FALSE, lost |-> FALSE, slow |-> FALSE,
                   plain |-> FALSE, outcome |-> FALSE]
Waiting == d.active /\ (worker.kind # "none" \/ reply.kind # "none")
Blocked == Mutation = "MainWait" /\ Waiting
Fresh(r) == r.id = d.id /\ r.step = d.step /\ r.kind = "check" /\ r.same
AppGuard == app = 0 /\ ~secure
CanRecord == ~Blocked /\ Mutation # "BlockRecording"
Record == /\ CanRecord /\ recording' = ~recording
          /\ UNCHANGED <<d, app, element, secure, worker, reply, outcomes, receipts,
                         closed, watchdog, quitting, draining, bad>>
Watch == /\ ~Blocked /\ watchdog' = ~watchdog
         /\ UNCHANGED <<d, app, element, secure, worker, reply, outcomes, receipts,
                        closed, recording, quitting, draining, bad>>
Finish(reason) ==
  LET partial == d.pos > 1 /\ d.pos <= Len(Text)
      result == IF reason = "posted" THEN "posted" ELSE IF d.pos = 1 THEN "refused" ELSE "partial"
      reported == IF Mutation = "PartialPosted" /\ partial THEN "posted" ELSE result
      count == IF Mutation = "TwoReceipts" THEN 2 ELSE
               IF Mutation = "NoQuitReceipt" /\ reason = "quit" THEN 0 ELSE 1
  IN /\ d' = [d EXCEPT !.active = FALSE, !.phase = "done"]
     /\ outcomes' = [outcomes EXCEPT ![d.id] = reported]
     /\ receipts' = [receipts EXCEPT ![d.id] = @ + count]
     /\ closed' = closed \cup {d.id}
     /\ bad' = [bad EXCEPT !.outcome = @ \/ (partial /\ reported = "posted"),
                 !.plain = @ \/ (~ListText /\ reason = "posted" /\ (d.ax # 0 \/ d.posts # 1))]
Post(r, batch) ==
  LET segmented == ~batch
      bypass == (Mutation = "FirstUnguarded" /\ d.posts = 0)
             \/ (Mutation = "FallbackUnguarded" /\ d.fallback)
             \/ Mutation = "CheckAwaitPost"
             \/ (Mutation = "Stale" /\ ~Fresh(r))
      allowed == bypass \/ (AppGuard /\ (~segmented \/ Fresh(r)))
      end == IF batch \/ d.fallback \/ d.time = Deadline THEN Len(Text) ELSE 2 * d.step
      dropping == d.drop /\ d.time < Deadline
      omitted == dropping /\ ~d.supplied
      chunk == IF omitted THEN SubSeq(Text, d.pos + 1, end) ELSE SubSeq(Text, d.pos, end)
  IN IF allowed THEN
       /\ d' = [d EXCEPT !.reached = @ \o chunk, !.pos = end + 1,
                  !.doubled = IF d.editor = "marker" /\ ~dropping THEN @ \cup {d.step} ELSE @,
                  !.posts = @ + 1, !.step = @ + 1, !.drop = FALSE,
                  !.supplied = FALSE, !.phase = IF end = Len(Text) THEN "finish" ELSE "read",
                  !.editor = IF end = Len(Text) THEN "none" ELSE "pending", !.visible = FALSE]
       /\ bad' = [bad EXCEPT !.wrongApp = @ \/ ~AppGuard,
          !.fresh = @ \/ (segmented /\ ~Fresh(r)),
          !.lost = @ \/ omitted, !.slow = @ \/ omitted,
          !.plain = @ \/ (~ListText /\ (segmented \/ d.ax # 0))]
       /\ UNCHANGED <<outcomes, receipts, closed>>
     ELSE Finish("refused")
Issue(kind) == /\ (Mutation # "CheckAwaitPost" \/ kind # "check" \/ AppGuard)
  /\ worker.kind = "none" /\ reply.kind = "none"
  /\ worker' = [Empty EXCEPT !.id = d.id, !.step = d.step, !.kind = kind]
  /\ d' = [d EXCEPT !.ax = @ + 1]
  /\ UNCHANGED <<reply, outcomes, receipts, closed, bad>>
Handle(r) ==
  CASE d.phase = "capture" ->
         /\ d' = [d EXCEPT !.phase = IF r.same THEN "check" ELSE "batch", !.target = r.target]
         /\ UNCHANGED <<outcomes, receipts, closed, bad>>
    [] d.phase = "read" ->
         /\ d' = [d EXCEPT !.phase = "check", !.fallback = r.reading = "unknown",
              !.drop = r.reading = "inserted" \/ Mutation \in {"DropUnknown", "DropSlow"},
              !.supplied = r.reading = "inserted" /\ r.landed /\ r.marker]
         /\ UNCHANGED <<outcomes, receipts, closed, bad>>
    [] d.phase = "check" -> Post(r, FALSE)
    [] OTHER -> /\ UNCHANGED <<d, outcomes, receipts, closed, bad>>
Main == /\ d.active /\ ~Blocked
  /\ UNCHANGED <<app, element, secure, recording, watchdog, quitting, draining>>
  /\ CASE d.phase = "finish" -> /\ Finish("posted") /\ UNCHANGED <<worker, reply>>
       [] d.time = Deadline /\ Mutation # "NoDeadline" ->
           /\ IF d.phase = "capture" \/ d.phase = "batch"
                 THEN Post(Empty, TRUE)
                 ELSE IF d.phase = "check" /\ Fresh(reply)
                      THEN Post(reply, FALSE) ELSE Finish("refused")
           /\ UNCHANGED <<worker, reply>>
       [] d.phase = "batch" /\ ~(Mutation = "PlainList" /\ ~ListText) ->
           /\ Post(Empty, TRUE) /\ UNCHANGED <<worker, reply>>
       [] d.phase = "batch" /\ Mutation = "PlainList" /\ ~ListText ->
           /\ d' = [d EXCEPT !.phase = "capture"]
           /\ UNCHANGED <<worker, reply, outcomes, receipts, closed, bad>>
       [] reply.kind # "none" ->
           /\ IF reply.id = d.id /\ reply.step = d.step
                  THEN Handle(reply)
                  ELSE IF Mutation = "Stale" /\ d.phase = "check"
                       THEN Post(reply, FALSE) ELSE UNCHANGED <<d, outcomes, receipts, closed, bad>>
           /\ reply' = Empty /\ UNCHANGED worker
       [] OTHER -> /\ Issue(d.phase) /\ UNCHANGED reply
Worker == /\ ~Silent /\ worker.kind # "none" /\ reply.kind = "none"
  /\ \E readable \in BOOLEAN :
       /\ reply' = [worker EXCEPT !.same = readable /\ (worker.kind = "capture" \/ element = d.target),
          !.target = element,
          !.reading = IF readable /\ worker.kind = "read" /\ d.visible /\ d.editor = "marker" THEN "inserted"
                 ELSE IF readable /\ worker.kind = "read" /\ d.visible /\ d.editor = "plain" THEN "plain"
                 ELSE IF Mutation = "PreBreak" /\ worker.kind = "read" /\ d.editor = "pending"
                      THEN "inserted" ELSE "unknown",
          !.landed = d.editor \in {"marker", "plain"}, !.marker = d.editor = "marker"]
       /\ worker' = Empty
  /\ UNCHANGED <<d, app, element, secure, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad>>
\* Models duplicate/late callbacks as well as a genuine outstanding old worker.
Late == /\ d.active /\ d.phase = "check" /\ reply.kind = "none"
  /\ \E id \in 0..d.id, step \in 0..d.step :
      /\ (id # d.id \/ step # d.step)
      /\ reply' = [Empty EXCEPT !.id = id, !.step = step, !.kind = "check", !.same = TRUE]
  /\ UNCHANGED <<d, app, element, secure, worker, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad>>
User == /\ \E a, e \in {0, 1}, s \in BOOLEAN : /\ app' = a /\ element' = e /\ secure' = s
        /\ UNCHANGED <<d, worker, reply, outcomes, receipts, closed, recording, watchdog, quitting, draining, bad>>
Editor == /\ d.active /\ d.editor = "pending"
  /\ \E value \in {"marker", "plain"} : d' = [d EXCEPT !.editor = value]
  /\ UNCHANGED <<app, element, secure, worker, reply, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad>>
Visible == /\ d.active /\ d.editor \in {"marker", "plain"} /\ ~d.visible
  /\ d' = [d EXCEPT !.visible = TRUE]
  /\ UNCHANGED <<app, element, secure, worker, reply, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad>>
Clock == /\ d.active /\ d.time < Deadline /\ d' = [d EXCEPT !.time = @ + 1]
  /\ UNCHANGED <<app, element, secure, worker, reply, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad>>
Quit == /\ d.active /\ ~Blocked /\ Finish("quit") /\ quitting' = TRUE
  /\ UNCHANGED <<app, element, secure, worker, reply, recording, watchdog, draining>>
Drain == /\ d.active /\ ~Blocked /\ ~draining /\ draining' = TRUE
  /\ (IF Mutation = "DrainWorker" /\ Waiting
         THEN UNCHANGED <<d, outcomes, receipts, closed, bad>> ELSE Finish("drain"))
  /\ UNCHANGED <<app, element, secure, worker, reply, recording, watchdog, quitting>>
StartNext == /\ ~d.active /\ d.id < Deliveries /\ ~quitting /\ ~draining
  /\ d' = Delivery(d.id + 1)
  /\ UNCHANGED <<app, element, secure, worker, reply, outcomes, receipts, closed,
                 recording, watchdog, quitting, draining, bad>>
Next == Main \/ Worker \/ Late \/ User \/ Editor \/ Visible \/ Clock \/ Quit \/ Drain \/ StartNext \/ Record \/ Watch
Spec == Init /\ [][Next]_vars /\ WF_vars(Main) /\ WF_vars(Clock)
NoPostToChangedApp == ~bad.wrongApp
NoSegmentWithoutFreshCheck == ~bad.fresh
MainNeverWaits == Waiting => (ENABLED Record /\ ENABLED Watch /\ ENABLED Quit)
BoundedDelivery == \A id \in 1..Deliveries : (d.id = id /\ d.active) ~> (id \in closed)
NoLostCharacter == ~bad.lost /\ d.reached \o SubSeq(Text, d.pos, Len(Text)) = Text
OnlyDoubledMarkerWhenSlow == ~bad.slow
  /\ d.reached \o SubSeq(Text, d.pos, Len(Text)) = Text
  /\ d.doubled \subseteq 2..Segments
PlainTextUntouched == ~bad.plain /\ (~ListText => d.ax = 0)
ExactlyOneOutcome == ~bad.outcome /\ \A id \in 1..Deliveries :
  IF id \in closed THEN outcomes[id] # "none" /\ receipts[id] = 1
  ELSE outcomes[id] = "none" /\ receipts[id] = 0
RecordingNeverBlocked == ENABLED Record
DrainBounded == draining => ~d.active
=============================================================================
