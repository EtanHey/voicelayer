# VoiceBar UI E2E (no audio)

Infrastructure layer: bundle/host, Xcode UI-test target, runner and exporter.
The stacked coverage layer supplies the full flow tests, now enabled in this branch.
The infrastructure base alone is buildable with `--build-only`; an empty run cannot
pass the result exporter.

On an **unoccupied Mac** with macOS 14+, Xcode 16+, Bun, Python 3.9+ and ffprobe:

```sh
bash scripts/voicebar-ui-e2e.sh --output $PWD/.build.noindex/voicebar-ui-results-$(date +%s)
```

On an occupied Mac, compilation only:

```sh
bash scripts/voicebar-ui-e2e.sh --output $PWD/.build.noindex/voicebar-ui-build-$(date +%s) --build-only
```

The output path must be new. The runner mutes output for the run and restores the prior mute state on exit, failure or interrupt, retains the QA app and sandbox
(path in `sandbox-path.txt`), and writes `VoiceBar.xcresult`, step receipts, exported attachments,
and an ordered `screenshots/index.html`. Failed or missing actions/screenshots fail the run.
Build-only neither changes volume nor launches any app or test runner.

The signed XCTest runner remains sandboxed. It writes no receipts into the QA app's
scratch directory: each action emits a retained `UIE2E-RECEIPT-<number>` JSON attachment,
and teardown emits `UIE2E-LEDGER` after process/clipboard cleanup. The exporter reads
these from the xcresult, checks their agreement and ordering, and writes `steps.json`,
`ledger.json` and `coverage.json` beside the result bundle. Missing/duplicate receipts,
unfinished runs, failed teardown, or unexercised controls cannot pass. An aborted run
with individual receipts still gets a contact sheet marked incomplete. QA-app fixture
sinks (events/settings/dictionary) remain in its scratch directory. No entitlements change.

Every UI run records a movie before XCTest launches, of this run's QA process only (GATECAP1):
the full desktop is never recorded. The runner compiles `voicebar-ui-e2e-capture.swift`, a
standalone ScreenCaptureKit helper that requires `--include-bundle` and `--include-executable`.
Its filter includes only the applications whose bundle ID AND exact executable path match this
run's sandboxed QA app; other apps, the desktop and system dialogs are never composited (black
until the QA process appears). It prints `source=` lines; a movie that never observed the
proven QA process, or names any other source, is rejected. It registers only a `.screen` stream output,
disables system audio and microphone capture, and writes a single H.264 video track
through AVAssetWriter with one-second MOV fragments. There is no camera lookup or
AVFoundation device-name selection, so a camera named `Capture screen 0` cannot be
selected. Screen Recording preflight failure stops without requesting/granting access.
The Python supervisor waits for appended frames and a nonempty MOV before tests start.
The helper runs in its own session so interrupting the test process group cannot kill it.
On completion, failure or SIGINT/SIGTERM, the supervisor stops its owned test process,
asks the helper to stop through stdin, waits for `stopCapture` and `finishWriting`
completion/exit, then validates the MOV with ffprobe. EOF also stops the helper.
Missing/empty media, no video, any audio, a nonpositive duration, recorder death, or a
forced recorder stop fails the gate. SIGKILL/power loss cannot run cleanup; completed
fragments remain recoverable, but that is not a successful run.

SIGINT/SIGTERM stay latched during flush and ffprobe; cleanup continues, but a cancelled
run exits nonzero and records `cancelledSignals`, an interruption error and
`runPassed=false`. A playable finalized movie may still have `valid=true`; that describes
the media, not a passed run. Cancellation/test failure cannot produce `PASS recording`
or a passing contact sheet. Previous signal handlers are restored after publication.

`recording.json`, `recording.html`, progress/capture/ffprobe logs and `run-<UTC>.mov`
are retained even when tests fail. The contact sheet links the verified video with
its duration and byte size. `--build-only` compiles the helper but does not execute it,
start capture, require ffprobe, or launch tests.
If macOS blocks screen capture/UI Automation, stop without granting access and have
the lead arrange a human-present retry. Recording lifecycle unit tests use stub processes; recorded native UI receipts are
linked from `docs.local/UIE2E.2/DONE.md`. Silent fixtures never prove audio playback.

Step frames (GATECAP1): there is no desktop screenshot or crop. Before each step's UI action,
each fixture command and each still, the sandboxed runner posts a name-only distributed
notification to the owned boundary broker (`voicebar-ui-e2e-permissions --broker`), which takes
a fresh synchronous foreign-modal decision. A still is a ScreenCaptureKit desktop-independent
window capture (the equivalent of `screencapture -l<id> -o`) of each visible window owned by the
one process running this run's QA executable, composited on black; with no proven QA window
the step's frame is `NOT_PROVEN` and no image exists (`qa-report.json` `visualNotProven`).

XCTest's own automatic capture is disabled in the scheme and emitted run configuration:
`SystemAttachmentLifetime=keepNever`, with `PreferredScreenCaptureFormat=screenshots` instead
of video. Explicit user attachments remain `keepAlways`. Before exporting any payload, the
exporter inspects all test-summary attachment metadata, including failed runs, and rejects
unexpected system images/videos with `FAIL unexpected-system-capture`. Only `UIE2E-*`
attachments are exported; the separate QA-only movie remains unchanged.
Other QA JSON evidence (`GATE2246-*`, `HIDE1VIS-*`, `GATE2245-*`, `GEO0-*`) stays inside
the xcresult for inspection. A rejected report names that bundle in `resultBundle`; it is
retained for the owner's quarantine/deletion decision, with no media exported.

Every step receipt declares `visible`, `hidden-alive`, or `terminated`. Hidden-alive proof
requires the live QA PID and its kernel microsecond birth, a successful CG inventory with zero
QA windows, and successful process identity reads for every CG row. Post-exit steps instead
require the recorded lifetime to have ended (kernel ESRCH or a different birth), no CG window
owned by that PID, and every visible row's path to resolve to a non-QA executable. Any failed
read or missing declaration fails the step. A later QA launch can bind a new lifetime only
after the prior lifetime has a positive termination proof.

Foreign modals (GATECAP1): any visible system-agent window (CoreServicesUIAgent, SecurityAgent,
UserNotificationCenter, coreautha), any window at the modal-panel level, or any app's AX modal
window or sheet, on any display, refuses the run before Hide Others and STOPs it at every
boundary (exit 2: `PREFLIGHT_REFUSED` / `FOREIGN_MODAL_STOP`). An unreadable CG/AX inventory is
`NOT_PROVEN` and refused the same way. Any detection latches STOP; nothing is ever pressed or
dismissed. Fixture commands are notifications, never keystrokes; remaining injected keystrokes are
checked against enabled `com.apple.symbolichotkeys` by keycode and full modifier set.

Movie capture uses Apple's [ScreenCaptureKit application filter](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
and [AVAssetWriter movie fragments](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval).

The Xcode project contains only a UI-test target. Xcode supplies its XCTest runner;
`XCUIApplication(url:)` launches the separately built QA bundle. No Xcode project or test-host
wrapper enters SwiftPM's release product. The runner builds via `build-app.sh`, gives the
throwaway app a distinct bundle ID with no URL scheme, then signs it ad-hoc. A release certificate
is not required. Release/notarized/resident builds cannot use this signing exception.

`VOICEBAR_UIE2E=1` is compiled only under `VOICEBAR_QA`. It enters the fixture host **before**
AppDelegate initialization. Production `SettingsView`, `BarView`, `VoiceState`, dictionary editing,
and `PillContextMenuController` run in a real app. Dependencies for permissions, F5 helper,
microphone priority, paste, archive, settings and daemon commands are synthetic sinks with
receipts inside a marked scratch directory. There is no daemon process, socket binding, global
hotkey registration, audio engine, microphone request or live archive read. This proves UI
behavior and intent delivery to the fixtures; it does not prove live daemon/device behavior,
physical F5, native AX insertion, STT, TTS, or the resident AppDelegate's wiring.

Preview/Play/Speak/Replay/recording controls are excluded from the sweep. General Copy uses the
real general pasteboard, whose complete materialized contents are saved and restored by XCTest.

UIE2E.2 adds required-surface receipts independently of the discovered-control inventory:
an empty inventory or a dispatched click cannot prove a completed tab/flow. Tabs verify
the selected sidebar row and page-specific content. Mic priority clicks the actual right-side
button and requires a fresh receipt/default change; recognizer disclosure clicks its arrow
and verifies its value changes. Processing controls use their native Switch role. History's
General-page shortcut is a Link. Missing switches fail within a screenshot-backed step instead
of aborting the rest of the suite while reading a nonexistent checkbox value.

The standalone visibility helper snapshots visible regular apps by PID, bundle path and launch
date, then hides their windows without quitting/closing. The supervisor restores precisely that
snapshot after recorder flush, including failed preparation/tests and cancellation. Initially
hidden apps stay hidden; terminated apps are never relaunched and reused PIDs are never adopted.
`visibility.json` retains the before/restore result; a failed hide or restore fails the run.
Each tab sweep activates QA and verifies foreground/on-screen/hittable state. Any XCTest
interruption latches a foreign-modal STOP (logged redacted); it never reactivates QA to continue
and never clicks a foreign control.

The QA floating panel now follows the synthetic hidden flag. Its native AX role is Dialog;
queries and Hide preconditions use that role, so a missing Window cannot vacuously pass Hide. Settings' navigation footer
remains part of Settings; it is not the floating pill. Hide/Show asserts actual panel absence
and return. Production AppDelegate already orders its panel out on snooze; this fixes a QA-host
discrepancy, not production Hide behavior. A fixture-only menu opener exposes the real context
controller's Show action while the panel is hidden.

The sole audio-label exception is Replay inside a marked silent speaking fixture; all commands
terminate at the QA in-memory sink. Timed-word seek checks the exact synthetic offset. Required
idle seek and list-newline frame assertions fail if unsupported rather than claiming coverage.
The clips also use external T3 text-selection Speak, outside this isolated host;
that external-client path remains NOT_PROVEN. SEL1 separately probes the real
VoiceState selection method with synthetic selections and a silent command sink. These requirements come from the 2.2.43
notch clips; UIE2E does not implement missing product behavior or play audio to validate it.
A pasteboard item that cannot be materialized must abort before any clipboard mutation.

Do not execute while the Mac is occupied. A build-for-testing receipt is compilation
evidence only; native acceptance requires an explicitly authorized recorded run.
The machine-local Ben fixture is a catalog entry
only; it contains no real profile, reference clip, personal dictionary or recording.

An explicitly authorized free-screen run may use this Mac. Preserve the found output-mute
state, confirm mute before launch, and restore it afterward. Stop on a permission prompt;
never grant one. Keep the installed app, resident sockets and global hotkeys untouched.

The integrated-candidate flow has capability checks for UI still in open PRs. Missing S3
Speech Copy buttons produce a screenshot and `SKIP S3 not in this build`. Once the buttons
exist, both profile command copies and the multiline error Copy must preserve exact bytes.
P1b #338 feedback fixtures become available when its feedback marker is present in the
compiled source (stamped as `UIE2EPasteFeedback` in the QA bundle); otherwise the run logs
`SKIP P1b #338 not in this build`. Both skip
receipts remain in `steps.json` and the contact sheet. They are not dependency blockers.
The lead runs the visual gate on the integrated release candidate.

Known product packets use **strict** `XCTExpectFailure`, an assertion-only matcher
requiring the packet tag, and an explicit XFAIL receipt: P14b (list newline frames),
and SEL1 (selection replacement while Preparing).
Idle readback word seek (SEEK2) is a normal assertion, including the exact word offset.
An unexpected pass or unrelated assertion still fails.
Expected surfaces are recorded separately from verified coverage and must have their
matching observed packet receipt. The contact sheet labels each XFAIL and preserves
the full issue. After the P1e/P1f fixes, feedback readability is a normal assertion.
It compares the actual StaticText frame with full-text layout at the production
font; full AX text alone cannot pass readability. Missing fixture content
or unreachable unowned controls remain harness failures.

SEL1 calls the real `VoiceState.speakSelection` method with synthetic original and
replacement selections and a silent `speak_text` sink; it requires a fresh exact
replacement payload and rendered replacement. External T3-client Speak remains a
separate nonblocking NOT_PROVEN limitation, not an assertion or a fabricated action.

UIE2E bundles carry `VoiceBarUIE2EOnly=true` and a distinct bundle identifier before
signing. The QA entry resolves this persistent identity before AppDelegate/NSApplication:
missing/invalid UIE2E mode, invalid sandbox or unconfirmed mute refuses startup. Removing
the mode flag while retaining isolated socket paths cannot enable production hotkeys/daemon.

The coverage ledger keys controls by page plus History scope/selected row or Speech
profile, not just label. Each History scope is inventoried independently. Ask response
Paste must add exactly `history-paste:QA response` to the synthetic sink for that click;
a prior Dictations Paste cannot satisfy either the ledger or payload assertion.
The microphone uses its native composite row label (`QA microphone B, Connected,
Make default`) and reverses the default to A. History controls resolve freshly for
each inspection/click within the selected scope and a container holding that row's
static transcript/response; selecting rows, refreshing or clearing search cannot reuse
a saved detail element. Copy/Paste are checked again after search restoration and
scope changes. Missing or ambiguous payload containers fail rather than falling back
to a shared global button. Locator preflight is screenshot/receipt-wrapped too.

Native numeric radio values and StaticText values are normalized explicitly. History row
activation must change the actual selected trait before it receives coverage credit; the
first rendered text line avoids the plain row's inert inter-line centre. Search restoration
waits for its asynchronously recreated payload. Each exact paste-sink delta is retained as
an XCTAttachment, so a later QA relaunch cannot erase that evidence. Global navigation
does not inherit a History row/scope identity.

The real QA status item has an explicit label and identifier rather than inheriting its
SF Symbol's production accessibility description. Popover navigation checks whether it is
already open before toggling; microphone uses the native combined row identity, and setup
uses its actual identifier. QA context menus defer anchor-panel resizing during tracking.
The real controller's synthetic Recent item receives a QA row identifier without changing
its title, represented payload or action. Submenu parent activation must expose a hittable child;
dispatch alone cannot pass. Remaining owned menus are dismissed on early return, never by
clicking foreign controls. None of these changes alters the production menu controller.

UIE2E.2 opens every setup-wizard page with injected granted permissions and silent dependencies; this is UI coverage, not permission or recording acceptance. HIDE0 checks actual AX Dialog disappearance/restoration from Settings and the real context menu in idle, speaking and readback. GEO0 records the actual post-Stop idle surface (playback controls absent), then attaches exact Replay/Eye/terminal frames and their tight AX row envelope across natural completion, three readback replays, and synthetic playback finishes. These injected state/ack transitions prove layout only, not daemon replay admission. Geometry shifts and absent product states fail explicitly; product layout is untouched.

The QA pill uses PillHostingView, the production morph canvas, panel layout and hit
configuration, with the stable-core isolated capture placement. Its virtual core has
no hardware notch occlusion. FittingSize and a width-dependent right anchor cannot
supply reliable GEO0 evidence. The QA host never constructs AppDelegate or starts
its services; a pure static interaction-configuration method is reused only.

History's wide metadata row can expose an AX frame spanning a transparent Spacer.
Its QA hit point targets the leading text and still requires the actual Selected
trait before context/coverage advances. Jump to latest is a scroll command; it
must not be treated as a selection. Ask cards use fresh payload-to-next-payload
screen intervals to require one Copy/Paste action per response, with no borrowing
from the next card. Missing or ambiguous actions fail with a retained AX snapshot.

Static feedback fixtures hold a modal presentation envelope until the next fixture,
so pointer-exit collapse cannot erase the note before its readability measurement.
This tests a held visible state, not real feedback timeout/collapse behavior. Normal
idle releases the hold. The fixture model disables resident-journal writes before
any host/window exists, including unit-only construction. Preparing is checked as
a real state/shell plus reachable controls; missing word content is not invented.
Setup resolves its unique popover identifier
without assuming the link-style control has Button role.


## Focused #338 state gallery

`bash scripts/voicebar-ui-e2e.sh --output "$PWD/.build.noindex/<new-directory>" --scenario focused-338`
selects only `VoiceBarFlowTests/testFocused338StateGallery`; `--build-only` compiles
without launching. The explicit focused QA define requires the actual #338 product
APIs. Default `full` still compiles on main without them. No focused build may enter
a notarized/release path. Run the gallery on an integrated #338 tree with the
required production APIs and final P1e/P1f copy.

The gallery presents11 variants in real BarView/DictationCard panels, at most6perpage.
Each page has one aggregate screenshot and frame/readability/overlap assertions.
Pinned confirmations use synthetic presentation copies of real method outcomes;
busy admission refreshes the same real state without window/AX identity churn.
All lifetime instances restart in one MainActor batch; the test waits the longest
expiry once, then inspects every page without resetting clocks. Session-end clearing
records genuine busy admission immediately before the transition. One real Copy
control is exercised with sentinel→exact clipboard equality. Four family renders
also use actual production screen/notch geometry and measured accessibility frames.
Gallery placement itself is not evidence of real-notch placement or hardware/audio.

The focused ledger has its own explicit required surface set and scope. `gallery.json`
is mandatory, all required variants must be present, and no skips or expected-failure
waivers pass. Normal P1e/P1f frame assertions replace the earlier known-defect XFAILs.
Exported reports always distinguish focused evidence from full-release coverage.
Native receipts and their movie audits are linked from `docs.local/UIE2E.2/DONE.md`.

## Review boundary and known limits

The clean recorded full scenario at QA head `93dc8eb5` contains harness code
`1eef933c`: 738 ordinary PASS, zero FAIL/SKIP, and three strict packet XFAILs.
This is synthetic UI scenario acceptance, not installed-app or release acceptance.
The focused #338 gallery independently passed 16/0/0/0 on product `fa8c3c44`.
The final review receipt records exact commits, media and audit boundaries.

Two audit limits remain explicit: QA Change-microphone callbacks select General
but omit production's Microphone-priority scroll focus; the existing intent receipt
does not prove that destination. Dictionary delete clicks lack a dedicated immediate
inline-confirmation assertion, although the flow checks cancellation/persistence and
final deletion. Movie evidence and formal review must not silently promote these
receipts into stronger UI guarantees. Generic Open Settings correctly raises the
currently selected Settings tab and need not select General.

The shell runner restores the mute state it found (`scripts/lib/output-mute-guard.sh`, EXIT/INT/TERM
traps). Recorded gate operators must still capture the initial state and restore it in a finally/trap.
The acceptance receipts use an outer `operator-run.py` beside each result, which
also verifies the exact QA bundle/head and cleans only that run's QA executable
paths. The supervisor itself restores the recorded hide-others snapshot. No
resident app or unrelated process is killed, closed, relaunched or installed.

## Batched GATE2245 candidate

`VOICEBAR_UIE2E_GATE2245=1 bash scripts/voicebar-ui-e2e.sh --output <new-directory>`
adds HIDE1/SEL1/CLN1b probes to the full recorded flow. Integrate #366, #372,
#397 and #398 first. The explicit define requires a QA build and its product APIs;
a normal release cannot enable it. The QA bundle records `UIE2EGate2245=true`.

HIDE1 constructs an unlaunched product AppDelegate using its existing panel and
wizard test seams: no applicationDidFinishLaunching, services, socket, hotkey,
permission request or audio. A real FloatingPillPanel/BarView receives each event
while snoozed; native visibility plus AX absence and post-Show state are asserted.
The automatic wizard is a real QA wizard with silent dependencies. SEL1 uses real
selection routing and exact silent commands; its gate assertion permits no XFAIL.
Partial/untimed/legacy subtitle events exercise the real decoder and teleprompter.
Movie audits separately judge styling/highlights; AX alone does not prove pixels.
This remains isolated native UI evidence, with no clone synthesis/installed-app claim.

## Focused HIDE1 visual proof

On an explicitly authorized free-screen Mac, integrate the pinned product candidate,
then run `bash scripts/voicebar-ui-e2e.sh --scenario hide1 --build-only --output <new-directory>`.
Run `python3 scripts/voicebar-hide1-visual-run.py <new-directory>` from that same tree.
The operator monitors output mute, restores its initial value, and uses the existing
recorded Hide Others/restore supervisor. Never use an installed-app swap for this gate.

Only `testHide1VisualFlow` runs. Settings and the QA status item are hidden; app-local
Command+0–9 menu commands drive the fixture without bringing Settings into frame.
Seven independent cases capture before/hidden/Show states, each with a lossless full
screen and crop from the same sample. The panel is placed below the menu bar at screen
center; the crop covers x=center−500, y=60, width=min(1000,screen width), height=540 in
screen points from the top left, scaled to screenshot pixels. This proves isolated
visibility, not notch placement. The final wizard uses production SetupWizardView with
synthetic dependencies, triggered by the product's deferred setup presentation seam.
Empty AppKit status-item frames are excluded from the visible-window inventory.
Pixel acceptance requires inspecting every exported original PNG, independently of the
native receipts; the Python scenario result alone is not visual acceptance.

Hide Others also snapshots the installed accessory VoiceBar owner. If macOS refuses
its hide request, preparation fails closed and restores the snapshot before any QA
launch. A resident notch strip must not be mistaken for the isolated product panel.
Capture receipts include on-screen window owner/PID/bounds for this distinction.
The QA panel move/resize observer preserves capture placement after product layout
callbacks without changing panel ordering. A failed preparation is not a product failure.

HIDE1-VIS run05 authorization (RULINGS.md, 2026-10-16): the installed resident may
be hidden only through its own AX “Hide for 1 hour” control, after immediately
checking no sox/rec descendant of its daemon, no `/tmp/voicelayer-session-*.lock`
under five minutes old, and a non-recording resident state. A failed condition
requires a two-minute wait and recheck. No app/daemon stop, relaunch, replacement,
or socket access is part of this flow. Restore through AX “Show VoiceBar” and
verify the original notch window and both process identities. If its own hide
fails, stop without a workaround.

The operator records these actions in a reversible `resident-visibility.json`.
Pass its absolute path as `VOICEBAR_UIE2E_RESIDENT_SNAPSHOT` to the prepared-run
operator. `visibility.json` links that snapshot; its `restored` flag covers the
regular apps hidden by the helper, while resident restoration is confirmed in
the linked snapshot. The helper never calls application hide/unhide on the
resident and fails closed if any resident-owned screen window remains. Close
only operator-opened Settings before capture and return it to its initial state.

## GATE2246 focused harness

`--scenario gate2246 --build-only` compiles the focused HIDE1.1 / SEL1.x scenario.
Run-01 stopped on an OS microphone permission prompt; nothing was granted. GATE2246B
uses the lead-approved QA-only engine setter before installing the real mode observer.
The device-free engine has no AVAudioEngine or device node. A separate injected QA
library aborts on device access and child launches (only the exact output-mute read
is permitted). Native execution requires all tripwire probes to pass, with proof
bound to the exact app, test executable, library and fixture sources. The QA host
also refuses fixture startup unless the library is active. The runner atomically
claims the single authorized retry in its fresh output directory. Do not create a
second run without a new lead ruling. Stop on any OS permission prompt; never grant it.

### The no-device guard covers every GATE2245 build

hide1, gate2246 and any build with `VOICEBAR_UIE2E_GATE2245=1` (including the batched
full candidate) construct the real AppDelegate, so all of them get the same stack:
`voicebar-ui-e2e.sh` builds and self-tests the tripwire, `run.py` and `results.py`
verify its proof before launch, XCUI inserts it with its receipt, the QA host refuses
startup without it (and `UIE2EGate2245` checks again before constructing AppDelegate),
and the exported report requires the guard receipts. A missing guard fails the run
closed. The single-retry claim stays gate2246-only.

The tripwire appends one install marker per process start, and the full flow quits and
relaunches the QA app (Popover, Context menu). So every launch gets its own receipt:
launch 1 writes `no-device-guard.log` (the path the supervisor watches), and relaunch
`n` writes a fresh `no-device-guard-launch-<n>.log`. XCUI records `GUARD launch <n>
installed` after each launch and `GUARD launch <n> no tripwire` once that process has
stopped. Each scenario also records before/after steps around its gate fixtures (prefix
`HIDE1VIS`, `GATE2246`, or `GATE2245` for a full GATE2245 run). The export requires all
of them for every guarded run, including a full GATE2245 run. It also requires each
launch log to be exactly one install marker, with contiguous launch numbers. Any other
line is reported as a tripwire hit on that launch. The supervisor's live check still
covers launch 1 only; relaunch logs are checked by XCUI and by the export.

### Merge order and the QA compile check

`UIE2EGate2245.swift`'s gate2246 capture-failure cases call #410's APIs
(`VoiceBarDaemonController(restartScheduler:microphonePromptDisabled:)`,
`configureCaptureFailurePresentation(_:controller:)`,
`handleCaptureFailure(type:userInitiated:)`). **#410 must merge before #416.**
Those cases compile only under `VOICEBAR_UIE2E_GATE2246_CAPTURE=1`, which
`--scenario gate2246` sets and `--scenario hide1` does not, so hide1 builds on main
without #410. CI runs `scripts/check-voicebar-qa-compile.sh`, which compiles both
configurations with the flags `build-app.sh` itself derives. Until #410 is on main,
the gate2246 configuration fails there by design.

## Committed native safety supervisor

All native runner entry points use `voicebar-ui-e2e-supervisor.py`; direct native
launch refuses without the live parent supervisor's per-run authority. Build-only
compiles its AX helpers without running them. The supervisor reads process/lock
state and positive recording state through AX (the resident Settings footer when
the pill is collapsed), waits two minutes and rechecks on unknown/unsafe state,
and never accesses resident sockets or interrupts capture. Only the resident's
own Hide for 1 hour and Show VoiceBar controls change visibility. It records its
restore intent before Hide, supervises mute/disk/permissions continuously, and
restores own visibility on ordinary exits, errors and catchable signals. The shell
runner owns mute writes and restores the pre-run state through its MUTE1 guard.
The native supervisor only confirms mute; direct invocation while unmuted refuses. A user-opened Settings window aborts preparation.
Failed restoration is retained as a failed gate, never silently accepted.

### Scenario deadlines and exit status

The supervised runner has a per-scenario budget, starting immediately before
runner launch (including recorder startup and xcodebuild boot):

| Scenario | Budget | Basis |
| --- | --- | --- |
| `full` | 2400 s (40 min) | Last full PASS recorded 1488.545 s; an earlier run took 1504 s. |
| `focused-338` | 2400 s (40 min) | Conservatively shares the measured full-suite allowance. |
| `gate2246` | 600 s (10 min) | Run-01 reached 250 s of recording; allows another 350 s for startup and margin. |
| `hide1` | 300 s (5 min) | Keeps the narrow visibility gate bounded. |

Configure and export retain their separate 120 s and 300 s timeouts. The
supervisor prints a final `verdict=... exit=... mute=... receipt=...` line to
stdout and saves `verdict` and `exitCode` in `operator-state.json`:

| Exit | Meaning |
| --- | --- |
| `0` | PASS; cleanup proven and initial mute state restored, nothing retained. |
| `3` | Scenario/export passed; launch completeness is NOT_PROVEN. Shell mute restoration still runs. |
| `1` | Failure, including suite/export errors or any actual cleanup/restoration error. |
| `2` | Preflight refused before runner launch, with successful cleanup. |

The shell runner and the hide1 compatibility entry propagate these statuses.
Callers must distinguish `0` and `3`; a shell using `set -e` must capture status
explicitly to handle `3`. Exit `3` does not prove owned termination. The supervisor's
`initialMuted`, `muteRestored`, `muteRetained` and `muteRetentionReason` describe
its inner check while the shell guard is active, not the final host state. The
shell restores its original state on every exit, including `3`, per MUTE1; its
restoration readback is written to stderr. Any additional cleanup error still
produces `1`. Neither exit `3` nor shell restoration proves native acceptance.
