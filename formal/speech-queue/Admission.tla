---------------------------- MODULE Admission ----------------------------
EXTENDS Naturals
CONSTANT Variant
VARIABLES latest, playing, queued, selection, stopped, steps
vars == <<latest, playing, queued, selection, stopped, steps>>
Init == latest = 0 /\ playing = 0 /\ queued = 0 /\ selection = 0 /\ stopped = FALSE /\ steps = 0
Snapshot(l, p, q) ==
  /\ steps = 0 /\ steps' = 1
  /\ latest' = l /\ playing' = p /\ queued' = q
  /\ UNCHANGED <<selection, stopped>>
Admit(text) ==
  LET replacing == latest # 0 \/ playing # 0 \/ queued # 0
      sameSelection == text = IF latest # 0 THEN latest ELSE playing
      samePlaying == latest # 0 /\ text = playing
  IN /\ steps = 1 /\ steps' = 2 /\ selection' = text
     /\ stopped' = ((Variant = "current") /\ replacing /\ (sameSelection \/ samePlaying))
     /\ UNCHANGED <<latest, playing, queued>>
Next == (\E l, p, q \in 0..3: Snapshot(l, p, q)) \/ (\E text \in 1..3: Admit(text))
Spec == Init /\ [][Next]_vars
TypeOK == latest \in 0..3 /\ playing \in 0..3 /\ queued \in 0..3
          /\ selection \in 0..3 /\ stopped \in BOOLEAN /\ steps \in 0..2
OnlyComparedIdentitiesStop == ~stopped \/ selection \in {latest, playing}
NonemptySelectionDoesNotStop == ~stopped
EveryQueuedMatchStops == steps # 2 \/ latest = 0 \/ playing = 0 \/ latest = playing
                        \/ queued = 0 \/ queued \in {latest, playing} \/ selection # queued \/ stopped
=============================================================================
