------------------------------ MODULE IdleWings ------------------------------
(* R0856-12: the idle notch wings and VoiceBar's own windows. The pointer     *)
(* must leave the notch to use Settings; its debounced exit (after the 2.5 s *)
(* grace) collapses idle at once. VoiceState.setHoveringFromDebouncedPointer, *)
(* setVoiceBarWindowFocused and the idle collapse timer, abstracted; time is *)
(* only event order. Bounded by MaxEvents user/window events.                *)
(*                                                                           *)
(* Mode "Old":      the exit collapses even while Settings has focus.        *)
(*      "Fixed":    focus holds the wings; resigning re-arms the countdown.  *)
(*      "NoResume": mutant, resigning does not re-arm the countdown.         *)
EXTENDS Naturals
CONSTANTS Mode, MaxEvents
VARIABLES hovering, focused, collapsed, timerArmed, vanishedWhileFocused, events
vars == <<hovering, focused, collapsed, timerArmed, vanishedWhileFocused, events>>

Init == /\ hovering = TRUE /\ focused = FALSE /\ collapsed = FALSE
        /\ timerArmed = FALSE /\ vanishedWhileFocused = FALSE /\ events = 0

Step == events < MaxEvents /\ events' = events + 1

Collapse == /\ collapsed' = TRUE
            /\ vanishedWhileFocused' = (vanishedWhileFocused \/ (focused /\ ~collapsed))

PointerEnters == /\ Step /\ ~hovering
                 /\ hovering' = TRUE /\ collapsed' = FALSE /\ timerArmed' = FALSE
                 /\ UNCHANGED <<focused, vanishedWhileFocused>>

\* The 2.5 s exit grace has elapsed with the pointer outside the notch.
PointerExits == /\ Step /\ hovering /\ hovering' = FALSE /\ timerArmed' = FALSE
                /\ IF Mode = "Old" \/ ~focused
                     THEN Collapse
                     ELSE UNCHANGED <<collapsed, vanishedWhileFocused>>
                /\ UNCHANGED focused

Focus == /\ Step /\ ~focused /\ focused' = TRUE /\ timerArmed' = FALSE
         /\ UNCHANGED <<hovering, collapsed, vanishedWhileFocused>>

Resign == /\ Step /\ focused /\ focused' = FALSE
          /\ timerArmed' = (Mode # "NoResume" /\ ~hovering /\ ~collapsed)
          /\ UNCHANGED <<hovering, collapsed, vanishedWhileFocused>>

TimerFires == /\ timerArmed /\ ~hovering /\ (Mode = "Old" \/ ~focused)
              /\ timerArmed' = FALSE /\ Collapse
              /\ UNCHANGED <<hovering, focused, events>>

Next == PointerEnters \/ PointerExits \/ Focus \/ Resign \/ TimerFires
Spec == Init /\ [][Next]_vars /\ WF_vars(TimerFires)

\* The wings never vanish while one of VoiceBar's own windows has focus.
NoVanishWhileFocused == ~vanishedWhileFocused
\* With the pointer away and no VoiceBar window focused, idle still collapses.
StillCollapses == [](~hovering /\ ~focused => <>(collapsed \/ hovering \/ focused))
=============================================================================
