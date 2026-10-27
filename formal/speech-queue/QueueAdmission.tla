------------------------- MODULE QueueAdmission -------------------------
EXTENDS Naturals, Sequences, FiniteSets
CONSTANTS PlayingPolicy, QueuedPolicy
VARIABLES playing, pending, suspended, beforePlaying, beforePending, wasSuspended, selected, event, decision, steps
vars == <<playing, pending, suspended, beforePlaying, beforePending, wasSuspended, selected, event, decision, steps>>
Members(q) == {q[i] : i \in 1..Len(q)}
Unique(q) == Cardinality(Members(q)) = Len(q)
Init == playing = 0 /\ pending = <<>> /\ suspended = FALSE /\ beforePlaying = 0 /\ beforePending = <<>>
        /\ wasSuspended = FALSE /\ selected = 0 /\ event = "init" /\ decision = "none" /\ steps = 0
Snapshot(p, q, s) ==
  /\ steps = 0 /\ steps' = 1 /\ Unique(q) /\ p \notin Members(q)
  /\ (p = 0 => q = <<>>) /\ (s => p # 0 /\ Len(q) > 0)
  /\ playing' = p /\ pending' = q /\ suspended' = s
  /\ beforePlaying' = p /\ beforePending' = q /\ wasSuspended' = s
  /\ UNCHANGED <<selected, event, decision>>
Select(t) ==
  LET active == playing # 0 /\ ~suspended
      latest == IF Len(pending) > 0 THEN pending[Len(pending)] ELSE playing
      clear == (active /\ t = playing /\ PlayingPolicy = "clear")
               \/ (t = latest /\ Len(pending) > 0 /\ QueuedPolicy = "clear")
      advance == active /\ t = playing /\ PlayingPolicy = "next"
      hint == ~advance /\ t \in Members(pending) /\ QueuedPolicy = "hint"
  IN /\ steps = 1 /\ steps' = 2 /\ event' = "selection" /\ selected' = t
     /\ decision' = IF clear THEN "stop" ELSE IF advance THEN IF Len(pending) > 0 THEN "read_next" ELSE "stop"
                    ELSE IF hint THEN "hint" ELSE "speak_text"
     /\ playing' = IF clear THEN 0 ELSE IF advance THEN IF Len(pending) > 0 THEN Head(pending) ELSE 0
                   ELSE IF hint \/ active THEN playing ELSE t
     /\ pending' = IF clear THEN <<>> ELSE IF advance THEN IF Len(pending) > 0 THEN Tail(pending) ELSE <<>>
                   ELSE IF hint \/ ~active THEN pending ELSE Append(pending, t)
     /\ suspended' = (hint /\ suspended)
     /\ UNCHANGED <<beforePlaying, beforePending, wasSuspended>>
Stop == /\ steps = 1 /\ steps' = 2 /\ event' = "stop" /\ decision' = "stop"
        /\ playing' = 0 /\ pending' = <<>> /\ suspended' = FALSE
        /\ UNCHANGED <<beforePlaying, beforePending, wasSuspended, selected>>
F5 == /\ ~suspended /\ playing # 0 /\ steps = 1 /\ steps' = 2 /\ event' = "f5" /\ decision' = "stop"
      /\ pending' = pending /\ suspended' = (Len(pending) > 0)
      /\ playing' = IF Len(pending) > 0 THEN playing ELSE 0
      /\ UNCHANGED <<beforePlaying, beforePending, wasSuspended, selected>>
Next == (\E p \in 0..4, q \in UNION {[1..n -> 1..4] : n \in 0..2}, s \in BOOLEAN: Snapshot(p, q, s))
        \/ (\E t \in 1..4: Select(t)) \/ Stop \/ F5
Spec == Init /\ [][Next]_vars
TypeOK == playing \in 0..4 /\ pending \in Seq(1..4) /\ Len(pending) <= 3 /\ suspended \in BOOLEAN /\ steps \in 0..2
NoSilentClear == event # "selection" \/ Members(beforePending) \subseteq Members(pending) \cup {playing}
NoDuplicateIdentity == Unique(pending) /\ playing \notin Members(pending)
StopClearsAll == event # "stop" \/ (playing = 0 /\ pending = <<>> /\ ~suspended)
F5KeepsQueue == event # "f5" \/ pending = beforePending
=============================================================================
