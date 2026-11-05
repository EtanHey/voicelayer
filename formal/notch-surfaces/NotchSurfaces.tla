---------------------------- MODULE NotchSurfaces ----------------------------
(* 2.3 U1/U2: History (the notch's lower panel), the notch menu and the       *)
(* microphone list hang from the same spot under the notch and must never    *)
(* show together. VoiceBarNotchSurfaceCoordinator + VoiceBarApp's            *)
(* requestNotchMenu / notchHistoryPanelDidChange, abstracted.                *)
(*                                                                           *)
(* Order of events that matters: History's open state lives in the SwiftUI   *)
(* view; asking it to close (historyCloseRequest) lands one update later,    *)
(* and SwiftUI does not update at all while an AppKit menu is tracking.      *)
(* User events cannot interleave before a requested close lands (it lands in *)
(* the same main-thread pass that bumped the request).                       *)
(*                                                                           *)
(* Mode "Fixed":       a menu asked for while History is open waits until    *)
(*                     the view reports History closed, then shows.          *)
(*      "Old":         ask History to close and show the menu at once.       *)
(*      "NoClose":     mutant, show the menu over History without closing.   *)
(*      "DropPending": mutant, the History-closed report forgets the menu.   *)
EXTENDS Naturals
CONSTANTS Mode, MaxEvents
\* U2 ships the microphone list; lane U1 adds the bare-notch menu. Both are
\* modelled so the proof already covers two menus never stacking.
Menus == {"notch", "mic"}
VARIABLES viewHistory, closeAsked, shown, pending, wanted, events
vars == <<viewHistory, closeAsked, shown, pending, wanted, events>>

Init == /\ viewHistory = FALSE /\ closeAsked = FALSE /\ shown = "none"
        /\ pending = "none" /\ wanted = "none" /\ events = 0

Step == events < MaxEvents /\ events' = events + 1

\* The History button toggles the panel. Menus are modal, and a requested
\* close lands before the next user event.
UserToggleHistory ==
    /\ Step /\ shown = "none" /\ ~closeAsked
    /\ viewHistory' = ~viewHistory
    /\ IF viewHistory
         THEN \* closed by the user: the coordinator's report shows a waiting menu
              IF pending # "none" /\ Mode # "DropPending"
                THEN shown' = pending /\ pending' = "none" /\ UNCHANGED wanted
                ELSE /\ pending' = "none" /\ UNCHANGED shown
                     /\ wanted' = IF wanted = "history" THEN "none" ELSE wanted
         ELSE /\ pending' = "none" /\ wanted' = "history" /\ UNCHANGED shown
    /\ UNCHANGED closeAsked

\* A click on the bare notch, or on the mic's chevron.
RequestMenu(k) ==
    /\ Step /\ shown = "none" /\ ~closeAsked
    /\ wanted' = k
    /\ IF viewHistory
         THEN CASE Mode = "Old" ->
                     shown' = k /\ closeAsked' = TRUE /\ pending' = "none"
                [] Mode = "NoClose" ->
                     shown' = k /\ pending' = "none" /\ UNCHANGED closeAsked
                [] OTHER ->
                     pending' = k /\ closeAsked' = TRUE /\ UNCHANGED shown
         ELSE shown' = k /\ pending' = "none" /\ UNCHANGED closeAsked
    /\ UNCHANGED viewHistory

\* The view applies the close request on its next update; never during menu
\* tracking. Its onChange reports History closed to the coordinator.
ViewAppliesClose ==
    /\ closeAsked /\ shown = "none"
    /\ closeAsked' = FALSE
    /\ viewHistory' = FALSE
    /\ IF viewHistory /\ pending # "none" /\ Mode # "DropPending"
         THEN shown' = pending /\ pending' = "none"
         ELSE pending' = "none" /\ UNCHANGED shown
    /\ wanted' = IF wanted = "history" THEN "none" ELSE wanted
    /\ UNCHANGED events

\* The user picks an item or dismisses the menu; tracking ends.
MenuCloses ==
    /\ shown # "none"
    /\ shown' = "none" /\ wanted' = "none"
    /\ UNCHANGED <<viewHistory, closeAsked, pending, events>>

Next == UserToggleHistory \/ (\E k \in Menus : RequestMenu(k)) \/ ViewAppliesClose \/ MenuCloses
Spec == Init /\ [][Next]_vars /\ WF_vars(ViewAppliesClose)

\* Never a menu over an open History panel.
ExclusiveSurfaces == ~(viewHistory /\ shown # "none")
\* A menu the user asked for shows, unless they changed their mind first.
PendingMenuShows == \A k \in Menus : [](wanted = k => <>(shown = k \/ wanted # k))
=============================================================================
