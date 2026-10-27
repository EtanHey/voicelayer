------------------------- MODULE QueueAdmission -------------------------
EXTENDS Naturals, Sequences, FiniteSets
CONSTANTS PlayingPolicy, QueuedPolicy, ClearOnStop, RetainOnF5, FreshKeepsQueue
VARIABLES playing, pending, suspended, beforePlaying, beforePending, wasSuspended, selected, event, decision, steps, preempted
vars == <<playing, pending, suspended, beforePlaying, beforePending, wasSuspended, selected, event, decision, steps, preempted>>
Members(q) == {q[i] : i \in 1..Len(q)}
Unique(q) == Cardinality(Members(q)) = Len(q)
Init == playing = 0 /\ pending = <<>> /\ suspended = FALSE /\ beforePlaying = 0 /\ beforePending = <<>>
        /\ wasSuspended = FALSE /\ selected = 0 /\ event = "init" /\ decision = "none" /\ steps = 0 /\ preempted = FALSE
Snapshot(p, q, s) ==
  /\ steps = 0 /\ steps' = 1 /\ Unique(q) /\ p \notin Members(q)
  /\ (p = 0 => q = <<>>) /\ (s => p # 0 /\ Len(q) > 0)
  /\ playing' = p /\ pending' = q /\ suspended' = s
  /\ beforePlaying' = p /\ beforePending' = q /\ wasSuspended' = s
  /\ UNCHANGED <<selected, event, decision, preempted>>
Select(t) ==
  LET active == playing # 0 /\ ~suspended
      latest == IF Len(pending) > 0 THEN pending[Len(pending)] ELSE playing
      clear == (active /\ t = playing /\ PlayingPolicy = "clear")
               \/ (t = latest /\ Len(pending) > 0 /\ QueuedPolicy = "clear")
      advance == active /\ t = playing /\ PlayingPolicy = "next"
      hint == ~advance /\ t \in Members(pending) /\ QueuedPolicy = "hint"
  IN /\ (steps = 1 \/ (steps = 2 /\ event = "preempt")) /\ steps' = steps + 1 /\ event' = "selection" /\ selected' = t
     /\ decision' = IF clear THEN "stop" ELSE IF advance THEN IF Len(pending) > 0 THEN "read_next" ELSE "stop"
                    ELSE IF hint THEN "hint" ELSE "speak_text"
     /\ playing' = IF clear THEN 0 ELSE IF advance THEN IF Len(pending) > 0 THEN Head(pending) ELSE 0
                   ELSE IF hint \/ active THEN playing ELSE t
     /\ pending' = IF clear \/ (~FreshKeepsQueue /\ ~advance /\ ~hint) THEN <<>> ELSE IF advance THEN IF Len(pending) > 0 THEN Tail(pending) ELSE <<>>
                   ELSE IF hint \/ ~active THEN pending ELSE Append(pending, t)
     /\ suspended' = (hint /\ suspended)
     /\ UNCHANGED <<beforePlaying, beforePending, wasSuspended, preempted>>
Stop == /\ steps = 1 /\ steps' = 2 /\ event' = "stop" /\ decision' = "stop"
        /\ UNCHANGED <<playing, pending, suspended, beforePlaying, beforePending, wasSuspended, selected, preempted>>
ApplyStop == /\ steps = 2 /\ event = "stop" /\ steps' = 3
             /\ playing' = IF ClearOnStop THEN 0 ELSE playing
             /\ pending' = IF ClearOnStop THEN <<>> ELSE pending
             /\ suspended' = IF ClearOnStop THEN FALSE ELSE suspended
             /\ UNCHANGED <<beforePlaying, beforePending, wasSuspended, selected, event, decision, preempted>>
F5 == /\ ~suspended /\ playing # 0 /\ steps = 1 /\ steps' = 2 /\ event' = "f5" /\ decision' = "stop"
      /\ UNCHANGED <<playing, pending, suspended, beforePlaying, beforePending, wasSuspended, selected, preempted>>
ApplyF5 == /\ steps = 2 /\ event = "f5" /\ steps' = 3
           /\ pending' = IF RetainOnF5 THEN pending ELSE <<>>
           /\ suspended' = (Len(pending) > 0)
           /\ playing' = IF Len(pending) > 0 THEN playing ELSE 0
           /\ UNCHANGED <<beforePlaying, beforePending, wasSuspended, selected, event, decision, preempted>>
Preempt == /\ steps = 1 /\ playing # 0 /\ steps' = 2 /\ event' = "preempt" /\ preempted' = TRUE
           /\ playing' = 0 /\ pending' = <<>> /\ suspended' = FALSE
           /\ UNCHANGED <<beforePlaying, beforePending, wasSuspended, selected, decision>>
Next == (\E p \in 0..4, q \in UNION {[1..n -> 1..4] : n \in 0..2}, s \in BOOLEAN: Snapshot(p, q, s))
        \/ (\E t \in 1..4: Select(t)) \/ Stop \/ ApplyStop \/ F5 \/ ApplyF5 \/ Preempt
Spec == Init /\ [][Next]_vars
TypeOK == playing \in 0..4 /\ pending \in Seq(1..4) /\ Len(pending) <= 3 /\ suspended \in BOOLEAN /\ steps \in 0..3
NoSilentClear == event # "selection"
                 \/ Members(IF preempted THEN <<>> ELSE beforePending) \subseteq Members(pending) \cup {playing}
NoDuplicateIdentity == Unique(pending) /\ playing \notin Members(pending)
StopClearsAll == event # "stop" \/ steps # 3 \/ (playing = 0 /\ pending = <<>> /\ ~suspended)
F5KeepsQueue == event # "f5" \/ steps # 3 \/ pending = beforePending
=============================================================================
