------------------------- MODULE TeleprompterAHandle -------------------------
(* U5 follow-up: the Teleprompter A handle against the notch's hit region. The handle sits at the
   bottom of `drawn` lines; the panel passes clicks through outside `hit` lines unless a pull holds
   the pointer. The window itself always holds eight lines, so it never resizes under the pointer. *)
EXTENDS Naturals
CONSTANTS AsyncHitOnly
VARIABLES drawn, hit, dragging, held, pendingSync
vars == <<drawn, hit, dragging, held, pendingSync>>
Lines == 3..5
Init == drawn = 3 /\ hit = 3 /\ dragging = FALSE /\ held = FALSE /\ pendingSync = FALSE
Press == /\ ~dragging /\ dragging' = TRUE /\ held' = TRUE /\ UNCHANGED <<drawn, hit, pendingSync>>
\* A whole-line step: VoiceState and (fixed) the presentation model take it in the same call. The app's
\* own panel-layout refresh still follows asynchronously either way.
Step(l) == /\ dragging /\ l # drawn /\ drawn' = l /\ hit' = IF AsyncHitOnly THEN hit ELSE l
           /\ pendingSync' = TRUE /\ UNCHANGED <<dragging, held>>
\* The app's asynchronous panel-layout refresh (notifyPanelLayoutChanged → setTeleprompterLines).
Sync == /\ pendingSync /\ hit' = drawn /\ pendingSync' = FALSE /\ UNCHANGED <<drawn, dragging, held>>
\* Release lets go of the pointer at once; nothing waits for the asynchronous refresh.
Release == /\ dragging /\ dragging' = FALSE /\ held' = FALSE /\ UNCHANGED <<drawn, hit, pendingSync>>
Next == Press \/ (\E l \in Lines: Step(l)) \/ Sync \/ Release
Spec == Init /\ [][Next]_vars
\* The handle (and every line drawn) is clickable: inside the hit region, or the pull still holds the pointer.
HandleReachable == held \/ drawn <= hit
\* No dead band: the hit region never claims lines that are not drawn, once the pointer is free.
NoDeadBand == held \/ hit <= drawn
=============================================================================
