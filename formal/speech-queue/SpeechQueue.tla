--------------------------- MODULE SpeechQueue ---------------------------
EXTENDS Naturals, Sequences, FiniteSets
CONSTANT Variant
VARIABLES q, issued, event, result, staleChanged, steps
vars == <<q, issued, event, result, staleChanged, steps>>
Jobs == 1..4
Emit(s) == [s EXCEPT !.count = Len(s.pending), !.visible = IF s.session THEN s.current ELSE 0]
Clear(s) ==
  LET empty == [s EXCEPT !.pending = IF Variant = "stop-leaves" THEN @ ELSE <<>>,
                        !.current = 0, !.session = FALSE, !.suspended = FALSE]
  IN IF s.session \/ s.pending # <<>> THEN Emit(empty) ELSE empty
Launch(s, id) ==
  LET live == [s EXCEPT !.current = id, !.started = Append(@, id)]
  IN IF s.session THEN Emit(live) ELSE live
Advance(s) ==
  IF s.pending = <<>> THEN Clear(s)
  ELSE Launch([s EXCEPT !.pending = Tail(@)], Head(s.pending))
Init ==
  /\ q = [pending |-> <<>>, current |-> 0, suspended |-> FALSE, session |-> FALSE,
           started |-> <<>>, visible |-> 0, count |-> 0]
  /\ issued = 0 /\ event = 0 /\ result = "none" /\ staleChanged = FALSE /\ steps = 0
Step(op, state, answer) ==
  /\ steps < 8 /\ steps' = steps + 1
  /\ q' = state /\ event' = op /\ result' = answer
OptF5Different ==
  /\ issued < 4
  /\ LET id == issued + 1
         append == ~q.suspended /\ q.current # 0
         full == append /\ Len(q.pending) = 2
         state == IF full THEN q ELSE
           IF q.suspended THEN Launch([q EXCEPT !.suspended = FALSE], id)
           ELSE IF append THEN Emit([q EXCEPT !.pending = Append(@, id), !.session = TRUE])
           ELSE Launch(Clear(q), id)
     IN Step(id, state, IF full THEN "full" ELSE IF append THEN "queued" ELSE "started")
  /\ issued' = issued + 1 /\ UNCHANGED staleChanged
Replace ==
  /\ issued < 4
  /\ LET id == issued + 1
     IN Step(id + 4, IF q.suspended THEN Launch([q EXCEPT !.suspended = FALSE], id)
                    ELSE Launch(Clear(q), id), "started")
  /\ issued' = issued + 1 /\ UNCHANGED staleChanged
Own ==
  /\ issued < 4
  /\ LET id == issued + 1
         base == IF q.suspended THEN [q EXCEPT !.suspended = FALSE] ELSE Clear(q)
         live == [base EXCEPT !.current = id]
     IN Step(id + 26, IF live.session THEN Emit(live) ELSE live, "none")
  /\ issued' = issued + 1 /\ UNCHANGED staleChanged
NextButton(id) ==
  LET stale == id # q.current
      ignored == stale /\ Variant # "stale-next"
      state == IF ignored THEN (IF Variant = "stale-clear" THEN Clear(q) ELSE q)
               ELSE Advance([q EXCEPT !.suspended = FALSE])
      answer == IF ignored THEN "stale" ELSE IF q.pending = <<>> THEN "stopped" ELSE "advanced"
  IN /\ Step(id + 8, state, answer)
     /\ staleChanged' = (staleChanged \/ (stale /\ (q' # q \/ result' # "stale")))
     /\ UNCHANGED issued
Settled(id, outcome) ==
  LET ignored == id # q.current \/ q.suspended
      base == [q EXCEPT !.current = 0]
      state == IF ignored THEN q ELSE IF outcome = 0 THEN Advance(base) ELSE Clear(base)
  IN /\ Step(id + 12 + outcome * 4, state, "none")
     /\ UNCHANGED <<issued, staleChanged>>
RecordStart ==
  /\ Step(25, IF q.current = 0 \/ q.pending = <<>> THEN Clear(q)
              ELSE [q EXCEPT !.suspended = TRUE], "none")
  /\ UNCHANGED <<issued, staleChanged>>
Stop ==
  /\ Step(26, Clear(q), "none")
  /\ UNCHANGED <<issued, staleChanged>>
Next == OptF5Different \/ Replace \/ Own \/ RecordStart \/ Stop
        \/ (\E id \in Jobs: NextButton(id))
        \/ (\E id \in Jobs, outcome \in 0..2: Settled(id, outcome))
Spec == Init /\ [][Next]_vars
TypeOK ==
  /\ q.pending \in Seq(Jobs) /\ Len(q.pending) <= 2
  /\ q.current \in 0..4 /\ q.suspended \in BOOLEAN /\ q.session \in BOOLEAN
  /\ q.started \in Seq(Jobs) /\ Len(q.started) <= 4
  /\ q.visible \in 0..4 /\ q.count \in 0..2
  /\ issued \in 0..4 /\ event \in 0..30 /\ steps \in 0..8
  /\ staleChanged \in BOOLEAN
QueueOwnership ==
  /\ \A i \in 1..Len(q.pending): q.pending[i] # q.current
  /\ Cardinality({q.started[i]: i \in 1..Len(q.started)}) = Len(q.started)
Publication == q.count = Len(q.pending) /\ q.visible = IF q.session THEN q.current ELSE 0
StaleCannotAdvance == ~staleChanged
StopClearsQueues == event # 26 \/ (q.pending = <<>> /\ q.current = 0 /\ ~q.suspended)
=============================================================================
