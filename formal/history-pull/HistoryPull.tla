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
EXTENDS Naturals, FiniteSets
CONSTANTS Mode, N, MaxEvents, MaxGen
VARIABLES phase, slopCrossed, level, target, intent, mounted, gen, completions,
          clickMovedPanel, events
vars == <<phase, slopCrossed, level, target, intent, mounted, gen, completions,
          clickMovedPanel, events>>

Levels == 0..N
Init == /\ phase = "idle" /\ slopCrossed = FALSE /\ level = 0 /\ target = "none"
        /\ intent = FALSE /\ mounted = FALSE /\ gen = 0 /\ completions = {}
        /\ clickMovedPanel = FALSE /\ events = 0

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
    /\ (phase = "idle" \/ ~open)  \* the clock can't be clicked mid-press; a dismissal can come any time
    /\ Animate(open)
    /\ UNCHANGED <<phase, slopCrossed, level, clickMovedPanel>>

Press == /\ Step /\ phase = "idle" /\ phase' = "pending" /\ slopCrossed' = FALSE
         /\ UNCHANGED <<level, target, intent, mounted, gen, completions, clickMovedPanel>>

(* Within the slop: still a click. The NoSlop mutant already moves the panel. *)
MoveSmall == /\ Step /\ phase = "pending"
             /\ IF Mode = "NoSlop"
                  THEN \E l \in Levels :
                         /\ l # level /\ level' = l /\ mounted' = TRUE /\ target' = "none"
                         /\ phase' = "dragging" /\ clickMovedPanel' = TRUE
                  ELSE UNCHANGED <<level, mounted, target, phase, clickMovedPanel>>
             /\ UNCHANGED <<slopCrossed, intent, gen, completions>>

(* Past the slop: a drag. The panel follows the pointer (any level); setting *)
(* the value without animation removes a running spring (target none).      *)
MoveLarge == /\ Step /\ phase \in {"pending", "dragging"}
             /\ phase' = "dragging" /\ slopCrossed' = TRUE
             /\ \E l \in Levels : level' = l
             /\ target' = "none"
             /\ mounted' = TRUE
             /\ gen' = IF mounted THEN gen ELSE NextGen
             /\ UNCHANGED <<intent, completions, clickMovedPanel>>

Settle(open) == IF open = intent THEN /\ Animate(open) /\ intent' = intent
                                 ELSE /\ intent' = open /\ Animate(open)

Release == /\ Step /\ phase \in {"pending", "dragging"} /\ phase' = "idle"
           /\ IF phase = "pending"
                THEN UNCHANGED <<level, target, intent, mounted, gen, completions>>  \* a click
                ELSE \E open \in BOOLEAN : Settle(open) /\ UNCHANGED level
           /\ UNCHANGED <<slopCrossed, clickMovedPanel>>

(* The system cancels a drag (no onEnded): @GestureState resets and the pull *)
(* settles at the nearer end. The NoCancel mutant drops it.                 *)
Cancel == /\ Step /\ phase = "dragging" /\ phase' = "idle"
          /\ IF Mode = "NoCancel"
               THEN UNCHANGED <<target, intent, mounted, gen, completions>>
               ELSE Settle(level * 2 > N)
          /\ UNCHANGED <<level, slopCrossed, clickMovedPanel>>

SpringStep == /\ target # "none"
              /\ LET goal == IF target = "open" THEN N ELSE 0
                 IN /\ level # goal
                    /\ level' = IF goal > level THEN level + 1 ELSE level - 1
              /\ UNCHANGED <<phase, slopCrossed, target, intent, mounted, gen, completions,
                             clickMovedPanel, events>>

(* A close's completion fires once its animation is removed: it settled at 0, *)
(* a newer animation superseded it, or a pull took the value over.          *)
Complete == \E g \in completions :
    /\ (g # gen \/ level = 0 \/ target # "closed")
    /\ completions' = completions \ {g}
    /\ mounted' = IF Mode = "NoGeneration"
                    THEN (IF ~intent THEN FALSE ELSE mounted)
                    ELSE (IF g = gen /\ ~intent /\ phase # "dragging" THEN FALSE ELSE mounted)
    /\ UNCHANGED <<phase, slopCrossed, level, target, intent, gen, clickMovedPanel, events>>

Next == SetIntent(TRUE) \/ SetIntent(FALSE) \/ Press \/ MoveSmall \/ MoveLarge \/ Release
        \/ Cancel \/ SpringStep \/ Complete
Spec == Init /\ [][Next]_vars

\* The panel is drawn only while the window still has History's size: a close is never cut off.
NoClippedPanel == level > 0 => mounted
\* A press that never left the slop is a click: it never moves the panel.
ClickNeverMoves == ~clickMovedPanel
\* No pull ever leaves the panel hanging part-open with nothing driving it.
NoStrandedPanel == (phase = "idle" /\ level \notin {0, N}) => target # "none"
=============================================================================
