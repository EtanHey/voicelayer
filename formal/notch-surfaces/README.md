# Notch surfaces: History, the microphone list and the notch menu (2.3 U2, U1)

History (the notch's lower panel), the notch menu (a click on the bare notch) and the
microphone list (the chevron beside the mic) hang from the same spot under the notch, so
they must never show together. History's open state lives in the SwiftUI view: asking it to
close lands one update later, and SwiftUI does not update at all while an AppKit menu is
tracking. A menu shown straight after asking History to close therefore hangs over a
still-open History panel for as long as the menu stays open.

Lane U2 ships History + the microphone list; lane U1 adds the bare-notch menu as a second
`VoiceBarNotchMenuKind`. The model already carries both menus.

Presentation is scheduled (the next main-queue turn), so a requested menu is only queued until that block
runs; History opening in that gap cancels it and `beginPresenting` re-checks (U2 review R1).
History counts as open while MOUNTED, including its close spring (U2×U4); a reopen during that spring
cancels a waiting menu through the bridge's explicit `historyOpenRequested` (no mount change fires).

`VoiceBarNotchSurfaceCoordinator` (VoiceBarUI) holds a menu asked for while History is open
until the view reports History closed (`VoiceBarNotchHistoryBridge.onHistoryPanelChanged`),
then queues it; `VoiceBarNotchSurfaceHandoff` (shared by `AppDelegate` and the UIE2E host) drives it through
`VoiceBarNotchHistoryBridge`.
Run: `bash formal/notch-surfaces/check.sh`.

| Config | Expected | Meaning |
| --- | --- | --- |
| Fixed | PASS | wait for the History-closed report, queue, re-check when the scheduled block runs |
| Old | `ExclusiveSurfaces` fails | ask History to close and show the menu at once |
| MutantNoClose | `ExclusiveSurfaces` fails | show the menu over History without closing it |
| MutantDropPending | `PendingMenuShows` fails (temporal) | the History-closed report forgets the waiting menu |
| MutantNoReopenCancel | `NoStaleMenu` fails | reopening a History that is still mounted (its close spring running after a menu request) keeps the waiting menu, so a later close opens a stale list (the U2×U4 review defect) |
| MutantPresentStale | `ExclusiveSurfaces` fails | a scheduled (queued) menu is neither cancelled by History opening nor re-checked when it runs (the U2 review R1 defect) |

Swift guards: `WingsU2Tests.testAMenuAskedForOverHistoryWaitsForHistoryToClose`,
`testHistoryOpeningAgainDropsAWaitingMenu`, `testHistoryOpeningBeforeTheScheduledPresentationCancelsIt`,
`testTheHandoffNeverPresentsOverAHistoryThatOpenedFirst`, `testTheBridgeReportsHistoryOnceAndCountsCloseRequests`.
The view side (`BarView` closing History on the bridge's `closeRequest`) and the menu placement need
the installed-app check.
