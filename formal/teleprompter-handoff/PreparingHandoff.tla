-------------------------- MODULE PreparingHandoff --------------------------
(* R2-04: the teleprompter body shows either "Preparing speech…" or the      *)
(* reading text (BarView.notchTeleprompterBody). Each switch removes the     *)
(* shown view and inserts the other; a new read can switch back at any time, *)
(* including mid-handoff. Time is in ticks of 1/120 s.                       *)
(*                                                                           *)
(* A view is visible while its opacity is above 0. An inserted view is       *)
(* visible after Delay + 0 ticks (strictly later). A removed view stays      *)
(* visible for Exit ticks only if it had become visible; one removed before  *)
(* its entrance started never shows. This abstracts SwiftUI's opacity        *)
(* transitions to their supports; curve shapes do not matter here.          *)
(*                                                                           *)
(* Old:   symmetric .opacity crossfade, 0.2 s each way, no delay.            *)
(* Fixed: TeleprompterPreparingHandoff: exit 0.1 s, entry waits 0.1 s + one  *)
(*        60 Hz frame (Exit 12, Delay 14 ticks).                             *)
EXTENDS Naturals, Sequences
CONSTANTS Exit, Delay, Horizon, MaxSwitches, EntryRuns
\* EntryRuns = FALSE is the mutant for NewestShows: a "fix" that never shows the new view also never
\* overlaps, so NoOverlap alone cannot tell it from the real one.
NoTime == Horizon + Exit + Delay + 1
VARIABLES now, views
vars == <<now, views>>
\* A view: [inserted |-> tick or 0 for the initial one, removed |-> tick or NoTime, initial |-> BOOLEAN]

Entered(v, t) == v.initial \/ (EntryRuns /\ t > v.inserted + Delay)
Visible(v, t) ==
  /\ Entered(v, t)
  /\ \/ v.removed = NoTime
     \/ (t < v.removed + Exit /\ Entered(v, v.removed))

Init == /\ now = 0
        /\ views = << [inserted |-> 0, removed |-> NoTime, initial |-> TRUE] >>

Tick == /\ now < Horizon /\ now' = now + 1 /\ UNCHANGED views

\* isPreparingSpeech flips: the shown view leaves, the other kind enters now.
Switch == /\ Len(views) <= MaxSwitches
           /\ views' = Append(
                [i \in 1..Len(views) |-> IF i = Len(views)
                                          THEN [views[i] EXCEPT !.removed = now]
                                          ELSE views[i]],
                [inserted |-> now, removed |-> NoTime, initial |-> FALSE])
           /\ UNCHANGED now

Next == Tick \/ Switch
Spec == Init /\ [][Next]_vars

\* The status and the text are never drawn in the same frame.
NoOverlap == \A i, j \in 1..Len(views):
               (i # j /\ Visible(views[i], now)) => ~Visible(views[j], now)
\* The handoff completes: the newest view is shown once its entrance delay has passed.
NewestShows == LET v == views[Len(views)] IN
                 (now > v.inserted + Delay \/ v.initial) => Visible(v, now)
=============================================================================
