------------------------------ MODULE WingEntry ------------------------------
(* R0856-05: recording starts with History open. The leading wing must grow  *)
(* (mic width to Stop + Cancel, or + hold: two slots) while the History body *)
(* shrinks. Controls drawn before the growing glass covers them are clipped  *)
(* by the old wing. Ticks of 1/120 s. The shell starts moving at ShellDelay  *)
(* and covers the entering controls Cover ticks later (the worst case, two   *)
(* slots, from VoiceBarNotchWingContentEntry.delay(forGrowth:): 0.175 s = 21 *)
(* ticks). Controls are drawn from EntryDelay. The spring's shape is checked *)
(* frame by frame in NotchRecordingFromHistoryTests; this checks the order.  *)
EXTENDS Naturals
CONSTANTS ShellDelay, EntryDelay, Cover, Horizon
VARIABLES now
vars == <<now>>

Covered == now >= ShellDelay + Cover
Drawn == now > EntryDelay

Init == now = 0
Tick == now < Horizon /\ now' = now + 1
Spec == Init /\ [][Tick]_vars /\ WF_vars(Tick)

\* No frame draws an entering control the glass does not yet cover.
NoClippedControl == Drawn => Covered
\* The controls do appear.
ControlsAppear == <>Drawn
=============================================================================
