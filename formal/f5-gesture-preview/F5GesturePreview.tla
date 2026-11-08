------------------------ MODULE F5GesturePreview ------------------------
EXTENDS Integers
CONSTANTS Window, AwaitGrace, PressGrace, MinimumVisible, Immediate, EnforceMinimum
VARIABLES now, phase, preview, releasedAt, awaitSeen, pressSeen, quickLock,
          shortRelease, briefHint
vars == <<now, phase, preview, releasedAt, awaitSeen, pressSeen, quickLock,
          shortRelease, briefHint>>

Hold == 160
Eligible(grace, window) == ~EnforceMinimum \/ grace + 1 + MinimumVisible <= window

Init == /\ now = 0 /\ phase = "pressing" /\ releasedAt = -1
        /\ preview = IF Immediate THEN "pressing" ELSE "idle"
        /\ pressSeen = Immediate /\ awaitSeen = FALSE
        /\ quickLock = FALSE /\ shortRelease = FALSE /\ briefHint = FALSE

\* One-ms ticks; input and preview jobs can run in either order at each tick.
Tick == /\ phase \in {"pressing", "waiting"}
        /\ IF phase = "pressing" THEN now < Hold ELSE now < releasedAt + Window
        /\ now' = now + 1
        /\ UNCHANGED <<phase, preview, releasedAt, awaitSeen, pressSeen,
                       quickLock, shortRelease, briefHint>>

\* Representative short presses; every release-to-second-press ms is explored.
Release == /\ phase = "pressing" /\ now \in {0, 80, 120, 159}
           /\ phase' = "waiting" /\ releasedAt' = now
           /\ preview' = IF Immediate THEN "awaitingSecondTap" ELSE "idle"
           /\ awaitSeen' = Immediate
           /\ shortRelease' = (now <= PressGrace)
           /\ briefHint' = briefHint \/ (Immediate /\ Window < MinimumVisible)
           /\ UNCHANGED <<now, pressSeen, quickLock>>

HoldTimer == /\ phase = "pressing" /\ now = Hold
             /\ phase' = "holding" /\ preview' = "holding"
             /\ UNCHANGED <<now, releasedAt, awaitSeen, pressSeen, quickLock,
                            shortRelease, briefHint>>

SecondPress == /\ phase = "waiting" /\ now <= releasedAt + Window
               /\ phase' = "locked" /\ preview' = "holding"
               /\ quickLock' = (now - releasedAt <= AwaitGrace)
               /\ UNCHANGED <<now, releasedAt, awaitSeen, pressSeen, shortRelease, briefHint>>

WindowTimer == /\ phase = "waiting" /\ now = releasedAt + Window
               /\ phase' = "idle" /\ preview' = "idle"
               /\ UNCHANGED <<now, releasedAt, awaitSeen, pressSeen, quickLock,
                              shortRelease, briefHint>>

\* Cancelled jobs are inert: production checks the generation and phase.
Cancel == /\ phase \in {"pressing", "waiting"}
          /\ phase' = "idle" /\ preview' = "idle"
          /\ UNCHANGED <<now, releasedAt, awaitSeen, pressSeen, quickLock,
                         shortRelease, briefHint>>

ShowPress == /\ phase = "pressing" /\ preview = "idle"
             /\ Eligible(PressGrace, Hold) /\ now > PressGrace
             /\ ~EnforceMinimum \/ now + MinimumVisible <= Hold
             /\ preview' = "pressing" /\ pressSeen' = TRUE
             /\ briefHint' = (briefHint \/ now + MinimumVisible > Hold)
             /\ UNCHANGED <<now, phase, releasedAt, awaitSeen, quickLock, shortRelease>>

ShowAwait == /\ phase = "waiting" /\ preview = "idle"
             /\ Eligible(AwaitGrace, Window) /\ now > releasedAt + AwaitGrace
             /\ ~EnforceMinimum \/ now + MinimumVisible <= releasedAt + Window
             /\ preview' = "awaitingSecondTap" /\ awaitSeen' = TRUE
             /\ briefHint' = (briefHint \/ now + MinimumVisible > releasedAt + Window)
             /\ UNCHANGED <<now, phase, releasedAt, pressSeen, quickLock, shortRelease>>

Next == Tick \/ Release \/ HoldTimer \/ SecondPress \/ WindowTimer \/ Cancel \/ ShowPress \/ ShowAwait
Spec == Init /\ [][Next]_vars
NoQuickDoubleTapHint == quickLock => ~awaitSeen
NoShortTapHoldHint == shortRelease => ~pressSeen
NoBriefHint == ~briefHint
\* Negative assertion: its violation witnesses non-vacuous future hint display.
FutureHintUnreachable == ~awaitSeen
=============================================================================
