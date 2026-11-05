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
(*      "NoReopenCancel": mutant (U2 x U4 review), reopening a History that  *)
(*                     is still mounted (closing) keeps the waiting menu.    *)
(*                                                                           *)
(* U2 x U4: History is MOUNTED while its close spring runs ("closing");      *)
(* the handoff sees it closed only when the spring settles (CloseSettles).   *)
EXTENDS Naturals
CONSTANTS Mode, MaxEvents
\* U2 ships the microphone list; lane U1 adds the bare-notch menu. Both are
\* modelled so the proof already covers two menus never stacking.
Menus == {"notch", "mic"}
VARIABLES viewHistory, closing, closeAsked, shown, queued, pending, wanted, events
vars == <<viewHistory, closing, closeAsked, shown, queued, pending, wanted, events>>

Init == /\ viewHistory = FALSE /\ closing = FALSE /\ closeAsked = FALSE /\ shown = "none"
        /\ queued = "none" /\ pending = "none" /\ wanted = "none" /\ events = 0

Step == events < MaxEvents /\ events' = events + 1

\* The History button while History is settled open or settled closed. A
\* tracking menu is modal; a requested close lands before the next user
\* event; a queued (scheduled, not yet shown) menu does not block the user.
UserToggleHistory ==
    /\ Step /\ shown = "none" /\ ~closeAsked /\ ~closing
    /\ IF viewHistory
         THEN \* the user closes it: the spring starts, the panel stays mounted
              /\ closing' = TRUE
              /\ wanted' = IF wanted = "history" THEN "none" ELSE wanted
              /\ UNCHANGED <<viewHistory, queued, pending>>
         ELSE \* opened: History wins; Fixed cancels a queued menu
              /\ viewHistory' = TRUE /\ pending' = "none" /\ wanted' = "history"
              /\ queued' = IF Mode = "PresentStale" THEN queued ELSE "none"
              /\ UNCHANGED closing
    /\ UNCHANGED <<closeAsked, shown>>

\* The History button (or a pull) while its close spring runs: it reopens
\* without unmounting, so no mount change fires; Fixed cancels the waiting
\* menu through the explicit open request.
UserReopen ==
    /\ Step /\ shown = "none" /\ closing
    /\ closing' = FALSE /\ wanted' = "history"
    /\ pending' = IF Mode = "NoReopenCancel" THEN pending ELSE "none"
    /\ UNCHANGED <<viewHistory, closeAsked, shown, queued>>

\* A click on the bare notch, or on the mic's chevron.
RequestMenu(k) ==
    /\ Step /\ shown = "none" /\ queued = "none" /\ ~closeAsked
    /\ wanted' = k
    /\ IF viewHistory
         THEN CASE Mode = "Old" ->
                     shown' = k /\ closeAsked' = ~closing /\ pending' = "none" /\ UNCHANGED queued
                [] Mode = "NoClose" ->
                     shown' = k /\ pending' = "none" /\ UNCHANGED <<closeAsked, queued>>
                [] OTHER ->
                     pending' = k /\ closeAsked' = ~closing /\ UNCHANGED <<shown, queued>>
         ELSE queued' = k /\ pending' = "none" /\ UNCHANGED <<closeAsked, shown>>
    /\ UNCHANGED <<viewHistory, closing>>

\* The view applies the close request on its next update (never during menu
\* tracking): the close spring starts; the panel stays mounted.
ViewAppliesClose ==
    /\ closeAsked /\ shown = "none"
    /\ closeAsked' = FALSE /\ closing' = TRUE
    /\ wanted' = IF wanted = "history" THEN "none" ELSE wanted
    /\ UNCHANGED <<viewHistory, shown, queued, pending, events>>

\* The close spring settles: the panel unmounts and the bridge reports it,
\* which queues a waiting menu.
CloseSettles ==
    /\ closing /\ shown = "none"
    /\ closing' = FALSE /\ viewHistory' = FALSE
    /\ IF pending # "none" /\ Mode # "DropPending"
         THEN queued' = pending /\ pending' = "none"
         ELSE pending' = "none" /\ UNCHANGED queued
    /\ UNCHANGED <<closeAsked, shown, wanted, events>>

\* The scheduled presentation block runs: beginPresenting re-checks History.
PresentQueued ==
    /\ queued # "none" /\ shown = "none"
    /\ shown' = IF ~viewHistory \/ Mode = "PresentStale" THEN queued ELSE "none"
    /\ queued' = "none"
    /\ UNCHANGED <<viewHistory, closing, closeAsked, pending, wanted, events>>

\* The user picks an item or dismisses the menu; tracking ends.
MenuCloses ==
    /\ shown # "none"
    /\ shown' = "none" /\ wanted' = "none"
    /\ UNCHANGED <<viewHistory, closing, closeAsked, queued, pending, events>>

Next == UserToggleHistory \/ UserReopen \/ (\E k \in Menus : RequestMenu(k)) \/ ViewAppliesClose
        \/ CloseSettles \/ PresentQueued \/ MenuCloses
Spec == Init /\ [][Next]_vars /\ WF_vars(ViewAppliesClose) /\ WF_vars(CloseSettles)
        /\ WF_vars(PresentQueued)

\* Never a menu over a mounted History panel (open, or still springing closed).
ExclusiveSurfaces == ~(viewHistory /\ shown # "none")
\* A menu that shows is the one the user currently wants (no stale list after
\* the user went back to History).
NoStaleMenu == shown # "none" => wanted = shown
\* A menu the user asked for shows, unless they changed their mind first.
PendingMenuShows == \A k \in Menus : [](wanted = k => <>(shown = k \/ wanted # k))
=============================================================================
