---------------------------- MODULE NotchSurface ----------------------------
(***************************************************************************)
(* 2.4 Lane A: ONE notch surface owns every drawer (History, Settings).    *)
(* Swift: flow-bar/Sources/VoiceBarUI/NotchSurface.swift                   *)
(*   (NotchSurfaceMachine.send).                                           *)
(*                                                                         *)
(* The drawers are modelled as two flags on purpose: that is the shape the *)
(* 2.3 code had (BarView's isHistoryPresented plus the Settings window's   *)
(* own state), and the invariants say what the one machine must guarantee  *)
(* that loose flags did not. History's detent and Settings' tab refine     *)
(* `history` and `settings`; they never change which drawer is open, so    *)
(* they are abstracted here (the Swift exhaustive walk covers them).       *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT Mode   \* "Fixed" or one mutant name

VARIABLES history, settings, recording, teleprompter, modal
vars == <<history, settings, recording, teleprompter, modal>>

Init == history = FALSE /\ settings = FALSE /\ recording = FALSE
        /\ teleprompter = FALSE /\ modal = FALSE

DrawerOpen == history \/ settings

\* An open may happen only while nothing outranks a drawer.
OpenAllowed ==
    /\ ~recording
    /\ ~teleprompter
    /\ (Mode = "NoModalGuard" \/ ~modal)

OpenHistory ==
    /\ OpenAllowed
    /\ history' = TRUE
    /\ settings' = IF Mode = "NoExclusive" THEN settings ELSE FALSE
    /\ UNCHANGED <<recording, teleprompter, modal>>

OpenSettings ==
    /\ OpenAllowed
    /\ settings' = TRUE
    /\ history' = IF Mode = "NoExclusive" THEN history ELSE FALSE
    /\ UNCHANGED <<recording, teleprompter, modal>>

\* Outside click, Esc, drag up, toggle, row action, voice activity, menu.
\* 2.3's monitors were History-only; the mutant keeps that.
DismissEnabled ==
    IF Mode = "HistoryOnlyDismiss" THEN history ELSE DrawerOpen

Dismiss ==
    /\ DismissEnabled
    /\ history' = FALSE /\ settings' = FALSE
    /\ UNCHANGED <<recording, teleprompter, modal>>

RecordingBegins ==
    /\ recording' = TRUE
    /\ IF Mode = "RecordingKeepsDrawer"
         THEN UNCHANGED <<history, settings>>
         ELSE history' = FALSE /\ settings' = FALSE
    /\ UNCHANGED <<teleprompter, modal>>

RecordingEnds ==
    /\ recording' = FALSE
    /\ UNCHANGED <<history, settings, teleprompter, modal>>

TeleprompterShown ==
    /\ teleprompter' = TRUE
    /\ IF Mode = "TeleprompterKeepsDrawer"
         THEN UNCHANGED <<history, settings>>
         ELSE history' = FALSE /\ settings' = FALSE
    /\ UNCHANGED <<recording, modal>>

TeleprompterGone ==
    /\ teleprompter' = FALSE
    /\ UNCHANGED <<history, settings, recording, modal>>

\* A Settings sheet or alert begins: it closes the drawer that would cover it.
ModalBegins ==
    /\ modal' = TRUE
    /\ IF Mode = "NoModalGuard"
         THEN UNCHANGED <<history, settings>>
         ELSE history' = FALSE /\ settings' = FALSE
    /\ UNCHANGED <<recording, teleprompter>>

ModalEnds ==
    /\ modal' = FALSE
    /\ UNCHANGED <<history, settings, recording, teleprompter>>

Next ==
    \/ OpenHistory \/ OpenSettings \/ Dismiss
    \/ RecordingBegins \/ RecordingEnds
    \/ TeleprompterShown \/ TeleprompterGone
    \/ ModalBegins \/ ModalEnds

Spec == Init /\ [][Next]_vars /\ WF_vars(Dismiss)

TypeOK == /\ history \in BOOLEAN /\ settings \in BOOLEAN /\ recording \in BOOLEAN
          /\ teleprompter \in BOOLEAN /\ modal \in BOOLEAN

(***************************************************************************)
(* Invariants, each naming the bug it prevents.                            *)
(***************************************************************************)

\* Bug: Settings drawn over a still-open History (two flags, two owners).
AtMostOneDrawer == ~(history /\ settings)

\* Bug: a drawer with no way out (2.3's dismissal monitors only knew History;
\* NATIVE-U4's Esc reached VoiceBar and closed nothing).
DismissalReachable == DrawerOpen => DismissEnabled

\* Bug: a drawer covering the recording wings (mic name, time, Stop).
WingsNeverHidden == recording => ~DrawerOpen

\* Bug: a drawer over a modal Settings sheet, taking its clicks.
NoDrawerOverModal == modal => ~DrawerOpen

\* Bug: a drawer over a read-aloud's teleprompter.
NoDrawerOverTeleprompter == teleprompter => ~DrawerOpen

\* Temporal: an open drawer is always closed eventually once dismissal is fair
\* (nothing can wedge it open).
DrawerAlwaysClosable == DrawerOpen ~> ~DrawerOpen
=============================================================================
