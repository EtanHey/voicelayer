----------------------------- MODULE History -----------------------------
EXTENDS Naturals
CONSTANT Variant
VARIABLES state, first, event, steps, moves, frozenMoves
vars == <<state, first, event, steps, moves, frozenMoves>>
Terminal == {"completed", "stopped", "cancelled", "failed", "interrupted"}
States == Terminal \cup {"requested", "preparing", "playing", "paused"}
Legal == [requested |-> {"preparing", "stopped", "cancelled", "failed", "interrupted"},
          preparing |-> {"playing", "paused", "stopped", "cancelled", "failed", "interrupted"},
          playing |-> {"paused", "completed", "stopped", "cancelled", "failed", "interrupted"},
          paused |-> {"playing", "stopped", "cancelled", "failed", "interrupted"},
          completed |-> {}, stopped |-> {}, cancelled |-> {}, failed |-> {}, interrupted |-> {}]
Init == state = "requested" /\ first = "" /\ event = "" /\ steps = 0 /\ moves = 0 /\ frozenMoves = 0
Move(to) ==
  LET accepted == to \in Legal[state] \/ (Variant = "mutable-terminal" /\ state \in Terminal /\ to \in Terminal)
  IN /\ steps < 4 /\ steps' = steps + 1 /\ event' = to
     /\ state' = IF accepted THEN to ELSE state
     /\ first' = IF first = "" /\ accepted /\ to \in Terminal THEN to ELSE first
     /\ moves' = IF accepted THEN moves + 1 ELSE moves
     /\ frozenMoves' = IF first = "" /\ accepted /\ to \in Terminal THEN moves + 1 ELSE frozenMoves
Next == \E to \in States: Move(to)
Spec == Init /\ [][Next]_vars
TypeOK == state \in States /\ first \in Terminal \cup {""} /\ steps \in 0..4 /\ moves \in 0..4 /\ frozenMoves \in 0..4
FirstAcceptedTerminalImmutable == first = "" \/ (state = first /\ moves = frozenMoves)
=============================================================================
