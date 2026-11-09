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
(*                                                                         *)
(* Etan, QA 0510 R3: "as long as there's no teleprompter of speech or      *)
(* asking, settings and history should be pulled down", while recording,   *)
(* transcribing and on Typed too. A drawer opens during a capture and      *)
(* stays through it (its band keeps the recording wings); only the         *)
(* teleprompter (agent speech or an Ask) and a modal sheet close it.       *)
(* `captureClosedDrawer` is a ghost flag: TRUE once a capture beginning or  *)
(* ending closed an open drawer.                                           *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT Mode   \* "Fixed" or one mutant name

VARIABLES history, settings, recording, teleprompter, modal, captureClosedDrawer
vars == <<history, settings, recording, teleprompter, modal, captureClosedDrawer>>

Init == history = FALSE /\ settings = FALSE /\ recording = FALSE
        /\ teleprompter = FALSE /\ modal = FALSE /\ captureClosedDrawer = FALSE

DrawerOpen == history \/ settings

\* An open may happen only while nothing outranks a drawer. Recording does not
\* (0510 R3); the RecordingRefusesDrawer mutant keeps the 2.4 guard.
OpenAllowed ==
    /\ (Mode # "RecordingRefusesDrawer" \/ ~recording)
    /\ ~teleprompter
    /\ (Mode = "NoModalGuard" \/ ~modal)

OpenHistory ==
    /\ OpenAllowed
    /\ history' = TRUE
    /\ settings' = IF Mode = "NoExclusive" THEN settings ELSE FALSE
    /\ UNCHANGED <<recording, teleprompter, modal, captureClosedDrawer>>

OpenSettings ==
    /\ OpenAllowed
    /\ settings' = TRUE
    /\ history' = IF Mode = "NoExclusive" THEN history ELSE FALSE
    /\ UNCHANGED <<recording, teleprompter, modal, captureClosedDrawer>>

\* Outside click, Esc, drag up, toggle, row action, voice activity, menu.
\* 2.3's monitors were History-only; the mutant keeps that.
DismissEnabled ==
    IF Mode = "HistoryOnlyDismiss" THEN history ELSE DrawerOpen

Dismiss ==
    /\ DismissEnabled
    /\ history' = FALSE /\ settings' = FALSE
    /\ UNCHANGED <<recording, teleprompter, modal, captureClosedDrawer>>

\* 0510 N8: a capture keeps the drawer. The RecordingClosesDrawer mutant is the
\* 2.4 behaviour (the capture closed it).
RecordingBegins ==
    /\ recording' = TRUE
    /\ IF Mode = "RecordingClosesDrawer"
         THEN /\ history' = FALSE /\ settings' = FALSE
              /\ captureClosedDrawer' = (captureClosedDrawer \/ DrawerOpen)
         ELSE UNCHANGED <<history, settings, captureClosedDrawer>>
    /\ UNCHANGED <<teleprompter, modal>>

RecordingEnds ==
    /\ recording' = FALSE
    /\ UNCHANGED <<history, settings, teleprompter, modal, captureClosedDrawer>>

TeleprompterShown ==
    /\ teleprompter' = TRUE
    /\ IF Mode = "TeleprompterKeepsDrawer"
         THEN UNCHANGED <<history, settings>>
         ELSE history' = FALSE /\ settings' = FALSE
    /\ UNCHANGED <<recording, modal, captureClosedDrawer>>

TeleprompterGone ==
    /\ teleprompter' = FALSE
    /\ UNCHANGED <<history, settings, recording, modal, captureClosedDrawer>>

\* A Settings sheet or alert begins: it closes the drawer that would cover it.
ModalBegins ==
    /\ modal' = TRUE
    /\ IF Mode = "NoModalGuard"
         THEN UNCHANGED <<history, settings>>
         ELSE history' = FALSE /\ settings' = FALSE
    /\ UNCHANGED <<recording, teleprompter, captureClosedDrawer>>

ModalEnds ==
    /\ modal' = FALSE
    /\ UNCHANGED <<history, settings, recording, teleprompter, captureClosedDrawer>>

Next ==
    \/ OpenHistory \/ OpenSettings \/ Dismiss
    \/ RecordingBegins \/ RecordingEnds
    \/ TeleprompterShown \/ TeleprompterGone
    \/ ModalBegins \/ ModalEnds

Spec == Init /\ [][Next]_vars /\ WF_vars(Dismiss)

TypeOK == /\ history \in BOOLEAN /\ settings \in BOOLEAN /\ recording \in BOOLEAN
          /\ teleprompter \in BOOLEAN /\ modal \in BOOLEAN /\ captureClosedDrawer \in BOOLEAN

(***************************************************************************)
(* Invariants, each naming the bug it prevents.                            *)
(***************************************************************************)

\* Bug: Settings drawn over a still-open History (two flags, two owners).
AtMostOneDrawer == ~(history /\ settings)

\* Bug: a drawer with no way out (2.3's dismissal monitors only knew History;
\* NATIVE-U4's Esc reached VoiceBar and closed nothing).
DismissalReachable == DrawerOpen => DismissEnabled

\* Bug (Etan, QA 0510 N7): History and Settings could not be opened while
\* recording. With no teleprompter and no modal sheet, both drawers may open.
DrawerReachableWhileCapturing ==
    (recording /\ ~teleprompter /\ ~modal) => (ENABLED OpenHistory /\ ENABLED OpenSettings)

\* Bug (Etan, QA 0510 N8): starting a capture closed the open drawer.
CaptureKeepsDrawer == ~captureClosedDrawer

\* Bug: a drawer over a modal Settings sheet, taking its clicks.
NoDrawerOverModal == modal => ~DrawerOpen

\* Bug: a drawer over a read-aloud's teleprompter.
NoDrawerOverTeleprompter == teleprompter => ~DrawerOpen

\* Temporal: an open drawer is always closed eventually once dismissal is fair
\* (nothing can wedge it open).
DrawerAlwaysClosable == DrawerOpen ~> ~DrawerOpen
=============================================================================
