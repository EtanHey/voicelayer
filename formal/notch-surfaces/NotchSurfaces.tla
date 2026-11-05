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
(* Presentation is scheduled: a requested menu is "queued" until the        *)
(* scheduled block runs (PresentQueued), and the user can open History in    *)
(* that gap (U2 review R1).                                                  *)
(*                                                                           *)
(* Mode "Fixed":       a menu asked for while History is open waits until    *)
(*                     the view reports History closed, then is queued;      *)
(*                     History opening cancels a queued menu and the         *)
(*                     scheduled block re-checks before showing.             *)
(*      "Old":         ask History to close and show the menu at once.       *)
(*      "NoClose":     mutant, show the menu over History without closing.   *)
(*      "DropPending": mutant, the History-closed report forgets the menu.   *)
(*      "PresentStale": mutant (the reviewed R1 code), a queued menu is      *)
(*                     neither cancelled by History nor re-checked.          *)
EXTENDS Naturals
CONSTANTS Mode, MaxEvents
\* U2 ships the microphone list; lane U1 adds the bare-notch menu. Both are
\* modelled so the proof already covers two menus never stacking.
Menus == {"notch", "mic"}
VARIABLES viewHistory, closeAsked, shown, queued, pending, wanted, events
vars == <<viewHistory, closeAsked, shown, queued, pending, wanted, events>>

Init == /\ viewHistory = FALSE /\ closeAsked = FALSE /\ shown = "none" /\ queued = "none"
        /\ pending = "none" /\ wanted = "none" /\ events = 0

Step == events < MaxEvents /\ events' = events + 1

\* The History button toggles the panel. A tracking menu is modal, and a
\* requested close lands before the next user event; a queued (scheduled, not
\* yet shown) menu does not block the user.
UserToggleHistory ==
    /\ Step /\ shown = "none" /\ ~closeAsked
    /\ viewHistory' = ~viewHistory
    /\ IF viewHistory
         THEN \* closed by the user: the coordinator's report queues a waiting menu
              IF pending # "none" /\ Mode # "DropPending"
                THEN queued' = pending /\ pending' = "none" /\ UNCHANGED wanted
                ELSE /\ pending' = "none" /\ UNCHANGED queued
                     /\ wanted' = IF wanted = "history" THEN "none" ELSE wanted
         ELSE \* opened: History wins; Fixed cancels a queued menu
              /\ pending' = "none" /\ wanted' = "history"
              /\ queued' = IF Mode = "PresentStale" THEN queued ELSE "none"
    /\ UNCHANGED <<closeAsked, shown>>

\* A click on the bare notch, or on the mic's chevron.
RequestMenu(k) ==
    /\ Step /\ shown = "none" /\ queued = "none" /\ ~closeAsked
    /\ wanted' = k
    /\ IF viewHistory
         THEN CASE Mode = "Old" ->
                     shown' = k /\ closeAsked' = TRUE /\ pending' = "none" /\ UNCHANGED queued
                [] Mode = "NoClose" ->
                     shown' = k /\ pending' = "none" /\ UNCHANGED <<closeAsked, queued>>
                [] OTHER ->
                     pending' = k /\ closeAsked' = TRUE /\ UNCHANGED <<shown, queued>>
         ELSE queued' = k /\ pending' = "none" /\ UNCHANGED <<closeAsked, shown>>
    /\ UNCHANGED viewHistory

\* The view applies the close request on its next update; never during menu
\* tracking. Its onChange reports History closed, which queues a waiting menu.
ViewAppliesClose ==
    /\ closeAsked /\ shown = "none"
    /\ closeAsked' = FALSE
    /\ viewHistory' = FALSE
    /\ IF viewHistory /\ pending # "none" /\ Mode # "DropPending"
         THEN queued' = pending /\ pending' = "none"
         ELSE pending' = "none" /\ UNCHANGED queued
    /\ wanted' = IF wanted = "history" THEN "none" ELSE wanted
    /\ UNCHANGED <<shown, events>>

\* The scheduled presentation block runs: beginPresenting re-checks History.
PresentQueued ==
    /\ queued # "none" /\ shown = "none"
    /\ shown' = IF ~viewHistory \/ Mode = "PresentStale" THEN queued ELSE "none"
    /\ queued' = "none"
    /\ UNCHANGED <<viewHistory, closeAsked, pending, wanted, events>>

\* The user picks an item or dismisses the menu; tracking ends.
MenuCloses ==
    /\ shown # "none"
    /\ shown' = "none" /\ wanted' = "none"
    /\ UNCHANGED <<viewHistory, closeAsked, queued, pending, events>>

Next == UserToggleHistory \/ (\E k \in Menus : RequestMenu(k)) \/ ViewAppliesClose
        \/ PresentQueued \/ MenuCloses
Spec == Init /\ [][Next]_vars /\ WF_vars(ViewAppliesClose) /\ WF_vars(PresentQueued)

\* Never a menu over an open History panel.
ExclusiveSurfaces == ~(viewHistory /\ shown # "none")
\* A menu the user asked for shows, unless they changed their mind first.
PendingMenuShows == \A k \in Menus : [](wanted = k => <>(shown = k \/ wanted # k))
=============================================================================
