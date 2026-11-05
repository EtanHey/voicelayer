----------------------------- MODULE HistoryPull -----------------------------
(* VoiceBar 2.3 lane U4: pulling History down from the notch, and its       *)
(* reversible open/close (morph B). Abstracts BarView.animateHistory,        *)
(* historyPullGesture / endHistoryPull and NotchHistoryPull. Progress is a  *)
(* level 0..N (0 = launcher, N = open); a spring moves it one level per     *)
(* step toward its target, and a new target never moves it (the spring      *)
(* retargets from where it is, so every morph reverses from wherever it is).*)
(* "mounted" is the window holding History's size; SwiftUI's animation      *)
(* completion (criteria .removed) is a set of generations that may fire.    *)
(*                                                                          *)
(* Mode "Fixed":    unmount only on the current close's completion, never   *)
(*                  while open is wanted or a pull holds the panel.         *)
(*      "Old":      2.2.60: closing unmounts at once (window shrinks under  *)
(*                  the closing shell).                                     *)
(*      "NoGeneration": mutant, any completion unmounts once open isn't     *)
(*                  wanted (no generation or pull check).                   *)
(*      "NoSlop":   mutant, a press moves the panel before the 3 pt slop.   *)
(*      "NoCancel": mutant, a cancelled pull is dropped without a spring.   *)
(*      "NoSnap":   mutant, a released extend handle stays between rows.    *)
(*      "NoPublish": mutant, the settled rows never reach the hit region.   *)
(*      "NoPendingCancel": mutant, a press the system cancels inside the    *)
(*                  slop stays pending (Codex R1: the next gesture reuses   *)
(*                  its stale start).                                       *)
(*      "SeedFromTarget": mutant, a press that grabs a moving panel or     *)
(*                  rows starts the drag from the spring's TARGET (Codex   *)
(*                  R1: the panel jumps), not from what is drawn.           *)
(*                                                                          *)
(* V6 extend handle (BarView.dragHistoryRows / endHistoryRowsPull): rows    *)
(* are counted in half-rows 0..2R above the 7-row panel (even = a whole     *)
(* row). "presented" is the rows the presentation model (the hit region)    *)
(* holds; a handle press inside the slop is a click and changes nothing.    *)
EXTENDS Naturals, FiniteSets
CONSTANTS Mode, N, MaxEvents, MaxGen, R
VARIABLES phase, slopCrossed, level, target, intent, mounted, gen, completions,
          clickMovedPanel, events, hphase, rows, rowsTarget, presented, live, jumped
vars == <<phase, slopCrossed, level, target, intent, mounted, gen, completions,
          clickMovedPanel, events, hphase, rows, rowsTarget, presented, live, jumped>>
HVars == <<hphase, rows, rowsTarget, presented>>
G == <<live, jumped>>   \* live: the system gesture is still delivering events; jumped: a grab moved the drawn value
NoRows == R + 1   \* no snap spring running

Levels == 0..N
Init == /\ phase = "idle" /\ slopCrossed = FALSE /\ level = 0 /\ target = "none"
        /\ intent = FALSE /\ mounted = FALSE /\ gen = 0 /\ completions = {}
        /\ clickMovedPanel = FALSE /\ events = 0
        /\ hphase = "idle" /\ rows = 0 /\ rowsTarget = NoRows /\ presented = 0
        /\ live = FALSE /\ jumped = FALSE

Dist(a, b) == IF a > b THEN a - b ELSE b - a
Goal == IF target = "open" THEN N ELSE 0

Step == events < MaxEvents /\ events' = events + 1
NextGen == IF gen < MaxGen THEN gen + 1 ELSE gen

(* animateHistory(toOpen:): bump the generation, mount when opening, spring  *)
(* toward the end. Old unmounts at once on close. Level is untouched.       *)
Animate(open) ==
    /\ gen' = NextGen
    /\ target' = IF open THEN "open" ELSE "closed"
    /\ mounted' = IF open THEN TRUE ELSE (IF Mode = "Old" THEN FALSE ELSE mounted)
    /\ completions' = IF open THEN completions ELSE completions \cup {NextGen}

(* The clock button or a dismissal (outside click, Esc, recording) sets the  *)
(* intent; onChange(isHistoryPresented) springs toward it.                  *)
SetIntent(open) ==
    /\ Step /\ intent # open /\ intent' = open
    /\ ((phase = "idle" /\ hphase = "idle") \/ ~open)  \* the clock can't be clicked mid-press; a dismissal can come any time
    /\ Animate(open)
    /\ UNCHANGED <<phase, slopCrossed, level, clickMovedPanel>> /\ UNCHANGED HVars /\ UNCHANGED G

Press == /\ Step /\ phase = "idle" /\ hphase = "idle" /\ phase' = "pending" /\ slopCrossed' = FALSE
         /\ live' = TRUE /\ UNCHANGED jumped
         /\ UNCHANGED <<level, target, intent, mounted, gen, completions, clickMovedPanel>> /\ UNCHANGED HVars

(* Within the slop: still a click. The NoSlop mutant already moves the panel. *)
MoveSmall == /\ Step /\ live /\ phase = "pending"
             /\ IF Mode = "NoSlop"
                  THEN \E l \in Levels :
                         /\ l # level /\ level' = l /\ mounted' = TRUE /\ target' = "none"
                         /\ phase' = "dragging" /\ clickMovedPanel' = TRUE
                  ELSE UNCHANGED <<level, mounted, target, phase, clickMovedPanel>>
             /\ UNCHANGED <<slopCrossed, intent, gen, completions>> /\ UNCHANGED HVars /\ UNCHANGED G

(* Past the slop: a drag. The panel follows the pointer (any level); setting *)
(* the value without animation removes a running spring (target none).      *)
MoveLarge == /\ Step /\ live /\ phase \in {"pending", "dragging"}
             /\ phase' = "dragging" /\ slopCrossed' = TRUE
             /\ IF phase = "pending"
                  \* Crossing the slop: the drag continues from what is drawn (the mutant: from the target).
                  THEN LET seed == IF Mode = "SeedFromTarget" /\ target # "none" THEN Goal ELSE level
                       IN /\ \E l \in Levels : Dist(l, seed) <= 1 /\ level' = l
                          /\ jumped' = (jumped \/ Dist(level', level) > 1)
                  ELSE /\ \E l \in Levels : level' = l
                       /\ UNCHANGED jumped
             /\ UNCHANGED live
             /\ target' = "none"
             /\ mounted' = TRUE
             /\ gen' = IF mounted THEN gen ELSE NextGen
             /\ UNCHANGED <<intent, completions, clickMovedPanel>> /\ UNCHANGED HVars

Settle(open) == IF open = intent THEN /\ Animate(open) /\ intent' = intent
                                 ELSE /\ intent' = open /\ Animate(open)

Release == /\ Step /\ live /\ phase \in {"pending", "dragging"} /\ phase' = "idle"
           /\ IF phase = "pending"
                THEN UNCHANGED <<level, target, intent, mounted, gen, completions>>  \* a click
                ELSE \E open \in BOOLEAN : Settle(open) /\ UNCHANGED level
           /\ live' = FALSE /\ UNCHANGED jumped
           /\ UNCHANGED <<slopCrossed, clickMovedPanel>> /\ UNCHANGED HVars

(* The system cancels a drag (no onEnded): @GestureState resets and the pull *)
(* settles at the nearer end. The NoCancel mutant drops it.                 *)
Cancel == /\ Step /\ live /\ phase = "dragging" /\ phase' = "idle"
          /\ IF Mode = "NoCancel"
               THEN UNCHANGED <<target, intent, mounted, gen, completions>>
               ELSE Settle(level * 2 > N)
          /\ live' = FALSE /\ UNCHANGED jumped
          /\ UNCHANGED <<level, slopCrossed, clickMovedPanel>> /\ UNCHANGED HVars

(* The system cancels a press still inside the slop: it ends like a click. The *)
(* NoPendingCancel mutant leaves it pending after the gesture has gone.        *)
CancelPending == /\ Step /\ live /\ phase = "pending" /\ live' = FALSE
                 /\ phase' = (IF Mode = "NoPendingCancel" THEN "pending" ELSE "idle")
                 /\ UNCHANGED <<slopCrossed, level, target, intent, mounted, gen, completions, clickMovedPanel>>
                 /\ UNCHANGED HVars /\ UNCHANGED jumped

SpringStep == /\ target # "none"
              /\ LET goal == IF target = "open" THEN N ELSE 0
                 IN /\ level # goal
                    /\ level' = IF goal > level THEN level + 1 ELSE level - 1
              /\ UNCHANGED <<phase, slopCrossed, target, intent, mounted, gen, completions,
                             clickMovedPanel, events>> /\ UNCHANGED HVars /\ UNCHANGED G

(* A close's completion fires once its animation is removed: it settled at 0, *)
(* a newer animation superseded it, or a pull took the value over.          *)
Complete == \E g \in completions :
    /\ (g # gen \/ level = 0 \/ target # "closed")
    /\ completions' = completions \ {g}
    /\ mounted' = IF Mode = "NoGeneration"
                    THEN (IF ~intent THEN FALSE ELSE mounted)
                    ELSE (IF g = gen /\ ~intent /\ phase # "dragging" THEN FALSE ELSE mounted)
    /\ UNCHANGED <<phase, slopCrossed, level, target, intent, gen, clickMovedPanel, events>> /\ UNCHANGED HVars
    /\ UNCHANGED G

(* ---- V6 extend handle ---- *)
Other == <<phase, slopCrossed, level, target, intent, mounted, gen, completions>>

(* A press on the handle: only on the open panel, never while the band pull holds the pointer. *)
HPress == /\ Step /\ hphase = "idle" /\ phase = "idle" /\ level = N /\ intent
          /\ hphase' = "pending" /\ live' = TRUE /\ UNCHANGED jumped
          /\ UNCHANGED Other /\ UNCHANGED <<clickMovedPanel, rows, rowsTarget, presented>>

(* Within the slop nothing moves; past it the rows follow the pointer (any half-row) and *)
(* setting them without animation removes a running snap spring.                       *)
HMove == /\ Step /\ live /\ hphase \in {"pending", "dragging"}
         /\ hphase' = "dragging" /\ rowsTarget' = NoRows
         /\ IF hphase = "pending"
              THEN LET seed == IF Mode = "SeedFromTarget" /\ rowsTarget # NoRows THEN 2 * rowsTarget ELSE rows
                   IN /\ \E h \in 0..(2 * R) : Dist(h, seed) <= 1 /\ rows' = h
                      /\ jumped' = (jumped \/ Dist(rows', rows) > 1)
              ELSE /\ \E h \in 0..(2 * R) : rows' = h
                   /\ UNCHANGED jumped
         /\ UNCHANGED live
         /\ UNCHANGED Other /\ UNCHANGED <<clickMovedPanel, presented>>

(* Snap to a whole row next to where it was let go (either neighbour of a half-row). *)
Snaps(h) == IF h % 2 = 0 THEN {h \div 2} ELSE {h \div 2, h \div 2 + 1}

HEnd == /\ hphase \in {"pending", "dragging"} /\ hphase' = "idle"
        /\ IF hphase = "pending"
             THEN UNCHANGED <<rows, rowsTarget, presented>>   \* a click on the handle
             ELSE \E w \in Snaps(rows) :
                    /\ rowsTarget' = (IF Mode = "NoSnap" THEN NoRows ELSE w)
                    /\ presented' = (IF Mode = "NoPublish" THEN presented ELSE w)
                    /\ UNCHANGED rows
        /\ live' = FALSE /\ UNCHANGED jumped
        /\ UNCHANGED Other /\ UNCHANGED clickMovedPanel

HRelease == Step /\ live /\ HEnd
HCancel == Step /\ live /\ hphase = "dragging" /\ HEnd   \* @GestureState reset: settles like a release
HCancelPending == /\ Step /\ live /\ hphase = "pending" /\ live' = FALSE
                  /\ hphase' = (IF Mode = "NoPendingCancel" THEN "pending" ELSE "idle")
                  /\ UNCHANGED Other /\ UNCHANGED <<clickMovedPanel, rows, rowsTarget, presented, jumped>>

RowsSpring == /\ rowsTarget # NoRows
              /\ IF rows = 2 * rowsTarget
                   THEN rowsTarget' = NoRows /\ UNCHANGED rows
                   ELSE /\ rows' = (IF 2 * rowsTarget > rows THEN rows + 1 ELSE rows - 1)
                        /\ UNCHANGED rowsTarget
              /\ UNCHANGED Other /\ UNCHANGED <<clickMovedPanel, events, hphase, presented>> /\ UNCHANGED G

Next == SetIntent(TRUE) \/ SetIntent(FALSE) \/ Press \/ MoveSmall \/ MoveLarge \/ Release
        \/ Cancel \/ CancelPending \/ SpringStep \/ Complete
        \/ HPress \/ HMove \/ HRelease \/ HCancel \/ HCancelPending \/ RowsSpring
Spec == Init /\ [][Next]_vars

\* The panel is drawn only while the window still has History's size: a close is never cut off.
NoClippedPanel == level > 0 => mounted
\* A press that never left the slop is a click: it never moves the panel.
ClickNeverMoves == ~clickMovedPanel
\* No pull ever leaves the panel hanging part-open with nothing driving it.
NoStrandedPanel == (phase = "idle" /\ level \notin {0, N}) => target # "none"
\* A released handle never leaves the panel resting between two rows.
NoStrandedRows == (hphase = "idle" /\ rowsTarget = NoRows) => rows % 2 = 0
\* At rest the hit region is exactly the rows drawn: no drawn row ignores clicks, no clicks land on air.
HitMatchesRows == (hphase = "idle" /\ rowsTarget = NoRows) => 2 * presented = rows
\* Once the system gesture is gone, no press is left half-open for the next gesture to reuse.
NoStalePress == (phase # "idle" \/ hphase # "idle") => live
\* Grabbing a moving panel or rows never moves what is drawn by more than one step.
NoGrabJump == ~jumped
=============================================================================
