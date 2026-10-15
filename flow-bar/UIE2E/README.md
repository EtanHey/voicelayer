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
the lead arrange a human-present retry. Native capture and playback remain unverified
until that retry; lifecycle tests use stub processes only.

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
A pasteboard item that cannot be materialized must abort before any clipboard mutation.

Do not execute here while Etan is using the Mac. The lead routes execution to the M1 Pro.
A build-for-testing receipt is compilation evidence only. Contact-sheet layout and native
interaction remain unverified until that run. The machine-local Ben fixture is a catalog entry
only; it contains no real profile, reference clip, personal dictionary or recording.

The integrated-candidate flow has capability checks for UI still in open PRs. Missing S3
Speech Copy buttons produce a screenshot and `SKIP S3 not in this build`. Once the buttons
exist, both profile command copies and the multiline error Copy must preserve exact bytes.
P1b #338 feedback fixtures become available when its feedback marker is present in the
compiled source (stamped as `UIE2EPasteFeedback` in the QA bundle); otherwise the run logs
`SKIP P1b #338 not in this build`. Both skip
receipts remain in `steps.json` and the contact sheet. They are not dependency blockers.
The lead runs the visual gate on the integrated release candidate.

Known visual gap: the native rc-2.2.44 walkthrough showed P1b notes visually truncated
while AX exposed the full strings. P1b assertions are explicitly **AX content only**.
When this capability is exercised, the final ledger records this gap and the exporter
prints/displays `KNOWN VISUAL GAP` and exits nonzero even if all AX assertions pass.
Full-text readability remains NOT_PROVEN until a separate running-app visual check
and an appropriate visual regression replace this gap. This harness packet does not
change the product pill layout.

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
