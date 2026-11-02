------------------------------ MODULE TabMorph ------------------------------
(* N1: the note tab under the notch. How VoiceBarNotchView turns presented   *)
(* geometry changes into shell springs (VoiceBarNotchView.swift,             *)
(* onChange(of: presentation.geometry) and onChange(of: pendingTabMorph)).   *)
(*                                                                           *)
(* Geometries: "Rest"    bodiless shell, body extents flush with the wings   *)
(*             "RestTab" bodiless shell, body extents at the tab's (draws    *)
(*                       exactly like Rest: a bodiless body is invisible)    *)
(*             "Tab"     the note tab hanging under the notch                *)
(*             "Panel"   History (a body flush with/stepping out of wings)   *)
(* A spring between Rest and Tab interpolates the body extents from the      *)
(* wings to the notch while the body grows: the wing-wide slab sweep.        *)
(*                                                                           *)
(* SwiftUI batches: between updates the presentation may change any number   *)
(* of times; an update then runs the onChange handlers for each value that   *)
(* differs from the last update's, with that update's value, in either       *)
(* order. A state write made in a handler is seen by the next update, so a   *)
(* pending spring's handler can share an update with a newer geometry        *)
(* handler and run after it.                                                 *)
(*                                                                           *)
(* Mode "Old"       spring straight to the presented geometry (pre-N1).      *)
(*      "Async"     snap, then a DispatchQueue.main.async spring whose state *)
(*                  write is dropped (observed: the tab never grew).         *)
(*      "Unguarded" chained onChange without the stale-target guard.        *)
(*      "Fixed"     chained onChange, guarded by the presented geometry and  *)
(*                  by the shell still sitting at the snapped start.        *)
EXTENDS Naturals
CONSTANTS Mode, MaxChanges
Geos == {"Rest", "Tab", "Panel"}
None == [presented |-> "none", start |-> "none", target |-> "none"]
VARIABLES presented, rendered, pending, seenPresented, seenPending, todo, pendVal,
          lastSpring, changes
vars == <<presented, rendered, pending, seenPresented, seenPending, todo, pendVal,
          lastSpring, changes>>

Bodiless(g) == g \in {"Rest", "RestTab"}
Draw(g) == IF g = "RestTab" THEN "Rest" ELSE g

\* VoiceBarNotchShellTransition.morphEndpoints, abstracted.
Start(cur, next) == IF Bodiless(cur) /\ next = "Tab" THEN "RestTab"
                    ELSE IF Bodiless(cur) /\ next = "Panel" THEN "Rest"
                    ELSE cur
End(cur, next) == IF next = "Rest" /\ cur = "Tab" THEN "RestTab" ELSE next

Init == /\ presented = "Rest" /\ rendered = "Rest" /\ pending = None
        /\ seenPresented = "Rest" /\ seenPending = None
        /\ todo = {} /\ pendVal = None
        /\ lastSpring = <<"Rest", "Rest">> /\ changes = 0

\* Between updates the presentation changes (a note appears or clears, History opens).
Present == /\ todo = {} /\ changes < MaxChanges
           /\ presented' \in Geos \ {presented}
           /\ changes' = changes + 1
           /\ UNCHANGED <<rendered, pending, seenPresented, seenPending, todo, pendVal, lastSpring>>

\* An update starts: it schedules the handlers whose values changed since the last one.
BeginUpdate ==
  /\ todo = {}
  /\ presented # seenPresented \/ pending # seenPending
  /\ todo' = (IF presented # seenPresented THEN {"geo"} ELSE {})
             \cup (IF pending # seenPending THEN {"pend"} ELSE {})
  /\ seenPresented' = presented /\ seenPending' = pending /\ pendVal' = pending
  /\ UNCHANGED <<presented, rendered, pending, lastSpring, changes>>

OnGeometry ==
  /\ "geo" \in todo
  /\ LET next == presented IN
       IF Mode = "Old" THEN
         /\ rendered' = next /\ lastSpring' = <<rendered, next>>
         /\ UNCHANGED pending
       ELSE IF Start(rendered, next) = rendered THEN
         /\ rendered' = End(rendered, next)
         /\ lastSpring' = <<rendered, End(rendered, next)>>
         /\ pending' = None
       ELSE
         \* Snap the invisible extents now; spring from them later.
         /\ rendered' = Start(rendered, next)
         /\ lastSpring' = lastSpring
         /\ pending' = IF Mode = "Async" THEN pending   \* the deferred write is lost
                       ELSE [presented |-> next, start |-> Start(rendered, next),
                             target |-> End(rendered, next)]
  /\ todo' = todo \ {"geo"}
  /\ UNCHANGED <<presented, seenPresented, seenPending, pendVal, changes>>

OnPending ==
  /\ "pend" \in todo
  /\ LET p == pendVal IN
       IF p = None \/ (Mode = "Fixed" /\ (p.presented # presented \/ p.start # rendered))
         THEN UNCHANGED <<rendered, lastSpring>>
         ELSE /\ rendered' = p.target /\ lastSpring' = <<rendered, p.target>>
  /\ todo' = todo \ {"pend"}
  /\ UNCHANGED <<presented, pending, seenPresented, seenPending, pendVal, changes>>

Next == Present \/ BeginUpdate \/ OnGeometry \/ OnPending
Spec == Init /\ [][Next]_vars

\* No spring ever interpolates between a flush bodiless shell and the tab.
NoSlabSweep == /\ lastSpring # <<"Rest", "Tab">>
               /\ lastSpring # <<"Tab", "Rest">>
\* Once no update is due, the shell draws what is presented.
Quiescent == todo = {} /\ presented = seenPresented /\ pending = seenPending
SettlesOnPresented == Quiescent => Draw(rendered) = presented
=============================================================================
