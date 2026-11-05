------------------------- MODULE TeleprompterAHandle -------------------------
(* U5 follow-up: the Teleprompter A handle against the notch's hit region and pointer holds. The handle sits
   at the bottom of `drawn` lines; the panel passes clicks through outside `hit` lines unless a pull holds the
   pointer. The window always holds eight lines, so it never resizes under the pointer. History has its own
   pull; the two holds are separate flags (the panel stays capturing while either is held). *)
EXTENDS Naturals
CONSTANTS AsyncHitOnly, LeakOnCancel, SharedHold
VARIABLES drawn, hit, dragging, held, pendingSync, historyDragging, historyHeld
vars == <<drawn, hit, dragging, held, pendingSync, historyDragging, historyHeld>>
Lines == 3..5
Init == /\ drawn = 3 /\ hit = 3 /\ dragging = FALSE /\ held = FALSE /\ pendingSync = FALSE
        /\ historyDragging = FALSE /\ historyHeld = FALSE
Press == /\ ~dragging /\ dragging' = TRUE /\ held' = TRUE
         /\ UNCHANGED <<drawn, hit, pendingSync, historyDragging, historyHeld>>
\* A whole-line step: VoiceState and (fixed) the presentation model take it in the same call. The app's
\* own panel-layout refresh still follows asynchronously either way.
Step(l) == /\ dragging /\ l # drawn /\ drawn' = l /\ hit' = IF AsyncHitOnly THEN hit ELSE l
           /\ pendingSync' = TRUE /\ UNCHANGED <<dragging, held, historyDragging, historyHeld>>
Sync == /\ pendingSync /\ hit' = drawn /\ pendingSync' = FALSE
        /\ UNCHANGED <<drawn, dragging, held, historyDragging, historyHeld>>
\* Releasing this handle's hold; a shared flag (mutant) would also drop History's.
LetGo == /\ held' = FALSE /\ historyHeld' = IF SharedHold THEN FALSE ELSE historyHeld
Release == /\ dragging /\ dragging' = FALSE /\ LetGo /\ UNCHANGED <<drawn, hit, pendingSync, historyDragging>>
\* The gesture is cancelled or the handle unmounts mid-drag: SwiftUI never delivers onEnded. The fixed view
\* releases on its GestureState reset / onDisappear; the R1 code only released in onEnded.
Cancel == /\ dragging /\ dragging' = FALSE
          /\ IF LeakOnCancel THEN UNCHANGED <<held, historyHeld>> ELSE LetGo
          /\ UNCHANGED <<drawn, hit, pendingSync, historyDragging>>
HistoryPress == /\ ~historyDragging /\ historyDragging' = TRUE /\ historyHeld' = TRUE
                /\ UNCHANGED <<drawn, hit, dragging, held, pendingSync>>
HistoryRelease == /\ historyDragging /\ historyDragging' = FALSE /\ historyHeld' = FALSE
                  /\ UNCHANGED <<drawn, hit, dragging, held, pendingSync>>
Next == Press \/ (\E l \in Lines: Step(l)) \/ Sync \/ Release \/ Cancel \/ HistoryPress \/ HistoryRelease
Spec == Init /\ [][Next]_vars
\* The handle (and every line drawn) is clickable: inside the hit region, or a pull still holds the pointer.
HandleReachable == held \/ drawn <= hit
\* No dead band: the hit region never claims lines that are not drawn, once the pointer is free.
NoDeadBand == held \/ hit <= drawn
\* No stuck hold: the handle holds the pointer only while its drag lives (else the 8-line reserve eats clicks).
NoStuckHold == held => dragging
\* The handle never releases a hold History owns.
HistoryHoldKept == historyDragging => historyHeld
=============================================================================
