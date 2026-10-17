# VoiceBar UI E2E (no audio)

Infrastructure layer: bundle/host, Xcode UI-test target, runner and exporter.
The stacked coverage layer supplies the full flow tests, now enabled in this branch.
The infrastructure base alone is buildable with `--build-only`; an empty run cannot
pass the result exporter.

On an **unoccupied Mac** with macOS 14+, Xcode 16+, Bun, Python 3.9+ and ffprobe:

```sh
bash scripts/voicebar-ui-e2e.sh --output /tmp/voicebar-ui-results-$(date +%s)
```

On an occupied Mac, compilation only:

```sh
bash scripts/voicebar-ui-e2e.sh --output /tmp/voicebar-ui-build-$(date +%s) --build-only
```

The output path must be new. The runner leaves output muted, retains the QA app and sandbox
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

Every UI run records the main screen by default before XCTest launches. The runner
compiles `voicebar-ui-e2e-capture.swift`, a standalone ScreenCaptureKit helper whose
filter accepts only the main `SCDisplay`. It registers only a `.screen` stream output,
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

Capture uses Apple's [ScreenCaptureKit display filter](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
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
Each tab sweep activates QA and verifies foreground/on-screen/hittable state. The XCTest
interruption monitor only reactivates QA for known T3/Screenshot overlays; it never clicks a
foreign control. Permission or unknown/persistent interruptions produce a clear BLOCKED failure.

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
SEEK2 (idle readback word seek), and SEL1 (selection replacement while Preparing).
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

`bash scripts/voicebar-ui-e2e.sh --output <new-directory> --scenario focused-338`
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

The shell runner deliberately leaves output muted. Recorded gate operators must
capture the initial mute state and restore it in a finally/trap, including failure.
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
