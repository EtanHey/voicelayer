# Changelog

All notable changes to VoiceLayer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [2.2.57] - 2026-10-26

### Added
- Add Speech history in Settings with durable speech records and live playback updates (#553, #555, #556).

### Fixed
- Improve speech pacing, pronunciation rules and list readout in the teleprompter (#557, #558, #559, #562, #565).
- Keep Speech history refresh and cancellation responsive, and preserve completed playback status (#556, #560, #564).
- Clarify the Speech threshold label, stabilize pill tooltips and support spoken styles in voice_ask (#554).

### Developer / QA
- Isolate wrapper discovery tests from Bun reporter state and install Bun before running VoiceBar Swift tests in CI (#561, #563).

## [2.2.56] - 2026-10-25

### Fixed
- Preserve selected list and paragraph boundaries in T3 Option+F5 through the existing protected Copy transaction (#549).
- Leave clipboard contents and ownership unchanged when focus moves before Copy (#550).

## [2.2.55] - 2026-10-24

### Fixed
- Show readback seek delivery failures and clear stale pending seek state when delivery is unavailable (#519).
- Correct Homebrew version checks when multiple kegs are retained, keeping absent formulas skippable and invalid installations visible (#520, #521).

## [2.2.54] - 2026-10-24

### Fixed
- Preserve the frozen `bun.lock` in the npm package for package-root VoiceBar builds. Pin the OIDC publisher to npm 11.19.1 and refuse publication if its packed lock or package identity fails the source contract.

## [2.2.53] - 2026-10-24

### Fixed
- Show selectable, copyable VoiceBar error details, including timeout guidance (#514).

### Developer / QA
- Prune only positively dead intermediate hook fixtures; retain supervisor custody when cleanup is refused and recheck process identity.

## [2.2.52] - 2026-10-23

### Developer / QA
- Harden QA runner identity and mutation authorization, and redact private receipt details (#416). These harness changes improve QA safety; they do not establish new live audio, visual, or native acceptance.
- Verify VoiceBar bundle identity during discovery, refuse incomplete bundle inventories and occupied destinations, and avoid duplicate bundle handling (#512).

## [2.2.51] - 2026-10-22

### Fixed
- Keep tooltip hosts mounted for the paused pill's Play, Next and Stop controls across pause/resume (#495).
- Fold a near-identical sentence repeated at a roughly 30-second chunk seam in long recordings when timestamp coverage supports the full shared-audio interval. Disputed words use distance from the chunk edge to choose a variant; ambiguous coverage retains the previous merge. Seam disagreements are logged as hashes only to `~/.local/state/voicelayer/seam-audit.jsonl`. This stride policy is an orc ruling pending ratification (#507).

### Developer / build
- Put generated build, QA and release artifacts in Spotlight-excluded `.noindex` directories. Release cleanup uses pinned directory handles so replaced ancestors cannot redirect it into `/Applications`; release path handoff supports relative paths, symlinked parents and direct `.noindex` layouts (#494, #498, #504).

### Internal
- Harden barge-in plumbing against stale onset events, isolate each monitor's VAD state and await owned teardown. Barge-in is still not wired into `voice_ask` (#496, #497, #499).
- Reap verified hook fixtures after launcher abort, preserving recovery evidence for unknown process identities (#493).
- Make Bun deadline/PID fixtures and host measurements more deterministic, require explicit network-test opt-in, publish PID receipts atomically and exclude Python caches from the private-corpus source guard (#500, #503, #505).
- Add deterministic synthetic VoiceBar snapshot baselines and causal readiness controls for Swift timing fixtures (#501, #502).
- Wait for hook supervisor readiness before timing fixture startup (#506).

## [2.2.50] - 2026-10-21

### Added
- Click telemetry for the pill and teleprompter controls: one timestamped log line per command receipt, outcome, dispatch, playback-state apply or drop, control ack and teleprompter hide. The lines carry command names, IDs, phase, generation and app/panel state only, never text, selections, payloads, window titles or error messages (#490).

### Changed
- While an Option+F5 read is playing out, the first chunk of the next queued read can be prepared in the background. Preparation starts only after every chunk of the current read is synthesized and covers only the next read's first chunk. When that chunk is ready and still matches the read, the next read can start with a shorter gap; otherwise it is synthesized as before. Stop, Hide, agent speech, an Ask, an idle Cancel or a replacement read discards it; a Cancel during a recording keeps the waiting reads as before (#488).
- Next shows on the pill only while a read is waiting in the queue (#489).

### Fixed
- The pill takes a first click on its background between controls while VoiceBar is not the active app, and the controls' tooltips are allowed while VoiceBar is inactive (#489).
- Pause while a read is still preparing now pauses it: the read starts paused, not a frame plays, and Play carries on from the start (#490).
- Replay while a read is paused restarts the whole read from 0:00 and plays it, instead of being refused. Replay is still refused while a recording is active (#490).

### Internal
- Tests: the pronunciation tests no longer split the shared module registry, which had made later text-to-speech tests see a stale module depending on file order (#491).

## [2.2.49] - 2026-10-20

### Added
- A pause/play button on the left of the pill while VoiceBar is speaking. Pause stops the read on the current word and folds the teleprompter away; Play reopens it and carries on from that word. F5 over a paused read still records, and the read waits for Play afterwards (#476, #480).
- Option+F5 on a different selection while a read is playing, preparing or paused queues it instead of replacing the read. The pill shows +N with a Next button, a read that finishes starts the next one, Stop clears the queue, and more than 10 shows "Queue full". Option+F5 on the same selection or with no selection stops the read and clears the queue (#482). Waiting reads survive an F5 dictation and are cleared when an agent speaks, an Ask starts or VoiceBar is hidden (#484).

### Changed
- A long Option+F5 read is one continuous teleprompter document: the page no longer swaps at each ~400-character chunk, and the highlight, seeks and replay carry across chunks (#477).
- Teleprompter formatting: bullets and numbered items start their own lines with a hanging indent, line and paragraph breaks are kept, a missing space after a full stop is shown (`unmuted. What`), and closing punctuation stays with its word. Long reads render lazily, and a scroll into a part of the document that is not built yet is checked and repeated until the word is on screen (#481, #483).
- Normal F5 dictation types into Chromium and Electron apps (such as ChatGPT and Claude) and into Gemini, the way Shift+F5 already did. A successful typed delivery says "Typed"; "Unverified / In History" now appears only for an accessibility write that could not be confirmed (#478).
- The busy note no longer clips while the notch animates, "Preparing speech…" is centred, and the seek bar is solid with "so far" while the total is still growing (#475).

### Fixed
- VoiceLayer no longer kills an unrelated app that reused the PID in a stale lock: the lock records the owner's exact start time and only a matching process is signalled (#479).
- Cancelling a recording made over a paused read no longer brings Play back early, and stopping that recording no longer waits for the paused read (#480).
- A Cancel while nothing is recording (`voicebar://cancel` or socket control) now ends the waiting Option+F5 reads in both VoiceBar and the daemon, so the +N count and the queue no longer disagree (#485).
- Replacing the teleprompter text with a same-length text and matching timings no longer leaves the current word off screen (#486).

## [2.2.48] - 2026-10-20

### Changed
- Tail verification on long transcripts is log-only: it no longer appends words, which stops the last sentence repeating at the end of long transcripts. The hallucinated-closer and caption gates still run when the skipped merge would not have changed the text (#469, #470).
- Transient notes such as "Busy recording. Selection not read" now show inside the notch, which grows briefly to fit them, instead of below it (#471).

### Fixed
- A microphone lost mid-recording no longer cuts the recording short: every byte is kept, and History and the pill say when the mic was lost. Only the recorder actually stopping ends a capture; a CoreAudio device report alone is recorded as evidence (#467).
- Replay keeps every word's timing, and a later chunk of a long read never wipes an earlier chunk's timeline (#472).
- Soft speech after a pause is no longer cut from a push-to-talk transcript: the tail trimmer only removes tails that are truly silent (#474).

The UI end-to-end runner restores the output mute state it found instead of leaving the Mac muted (#468).

## [2.2.47] - 2026-10-19

### Added
- Click a word in finished teleprompter readback to replay the same utterance from that word, using its retained audio; missing audio or timing reports a clear failure (#453).
- Pause and resume speech from the same word. This release adds the backend and protocol only; the pill pause/play control comes later (#455).
- Opt-in coherent paragraphs: long dictations break at completed sentences, preferably where the topic turns, never after abbreviations, initials or fragments. Default off (#461, #465).

### Changed
- The bundled dictionary now carries only common developer terms; personal terms live in each user's own dictionary and are imported once, without overwriting existing entries or restoring deleted ones (#456).
- Settings uses one shared expandable drawer for General, Transcription and Dictionary sections; Recognizer details no longer repeat values, and the speech-rate caption sits under the slider knob (#458).

### Removed
- The Smart boundaries transcription option. Smart chunks stays available as an experimental option, off by default (#463).

### Fixed
- Speech history keeps each long read once and whole after replays and seeks, so idle Replay no longer plays repeated or cut-off audio (#457).
- The teleprompter scrubber shows the real duration, stays available in finished readback and seeks there; readback and replay use the same layout as live speech (#460).
- Drop hallucinated caption tails such as "Transcription by CastingWords" or a stray trailing "you" only when the audio under them is silent or the microphone was dead (#459).
- History explains why a kept recording has no transcript (silent microphone, no speech, too short, too quiet, no words recognized or a transcription failure) and updates the reason after Re-transcribe (#462, #464).

Test children now inherit the isolated test environment and refuse to fall back to live VoiceLayer state (#448).

### Not in this release
- TAILDUP2: a fix for a sentence repeated back-to-back in long transcripts (in progress).
- MICDROP2: handling for a microphone that disconnects mid-recording (in progress).
- Pause/play buttons on the pill (P16).

## [2.2.46] - 2026-10-18

### Fixed
- Keep rapid Option+F5 selection changes tied to the correct request, including delayed Preparing responses (#408, #409, #411).
- Keep Option+F5 presses made as playback finishes: read a different selection in full, or stop for the same selection (#441).
- Defer background microphone alerts while VoiceBar is hidden and recheck them when it returns; user-initiated and unknown-origin failures still appear immediately (#410).
- Read selections in freshly launched Electron/Chromium apps such as T3 Code, and retain diagnostics when selection capture fails (#447, #450).
- Align the Speech rate labels with the slider, with Normal at the zero tick (#424).

Test-process cleanup, synthetic privacy fixtures, hidden-panel timing tests and the installed T3 release-proof gate also improved (#412–#415, #429, #431, #434, #445, #451).

### Not in this release
- SEEK2: seek after playback has ended.
- Pause/play controls.
- TESTISO1: further test-isolation hardening.

## [2.2.45] - 2026-10-17

### Changed
- Show word timings for cloned-voice speech in the teleprompter, and display words without timings plainly (#366, #372).
- Read a new selection when Option+F5 is pressed during speech (#398).

### Fixed
- Keep every VoiceBar panel hidden during “Hide for 1 hour” and defer setup until Show (#397).
- Keep the recordings-backup path stable across Homebrew upgrades (#378).

Command-log privacy, test-process cleanup, private-corpus isolation and UI test coverage also improved (#400, #402, #395, #396, #403–#406, #379–#394, #401).

## [2.2.44] - 2026-10-16

### Added
- Copy dictionary terms, complete errors, recording metadata and daemon diagnostics from Settings, including Speech diagnostics (#333, #342).
- Opt-in nightly iCloud recordings backups keep existing files and preserve changed recordings as separate versions (#340, #343).

### Changed
- Simplify Transcription settings and group Fast and locally available Cloned voices in one list per speech profile (#327, #328, #334).
- Read developer text, paths and inline JSON more clearly while preserving the original displayed text and measured word alignment (#336, #337, #344, #359).

### Fixed
- Verify transcript delivery at the caret, guard delayed terminal typing against focus changes, and keep the complete transcript available when insertion cannot be confirmed (#338, #345, #355).
- Keep insertion recovery and selection errors readable; show brief feedback when selection capture is busy (#348, #352, #354, #367, #371).
- Restart an owned long read from the beginning when Replay is pressed during playback, and let Stop cancel speech preparation before audio starts (#363, #370).
- Keep Ask admission, timeout cleanup and playback cancellation scoped to the owning operation; reap stuck players before releasing playback ownership (#332, #339, #349, #353, #357, #358, #362).
- Limit physical-stop click detection to the recording tail while preserving the full archived recording and keeping the full transcription input when no clear click is found (#341).
- Preserve the TTS daemon during VoiceBar hotkey-health checks and recognize cancellation reliably on Bun 1.3.9 (#326, #360).

Developer groundwork includes structured display projections, stable speech sections and an offline clone-alignment adapter; clone timing integration and section navigation are not enabled by this release (#329, #335, #364, #365). Test infrastructure isolates sockets and offscreen windows, bounds temporary data, and adds synthetic UI coverage (#331, #346, #350, #351, #356, #361, #373, #376).

## [2.2.43] - 2026-10-14

### Fixed
- Scrub through cloned-voice playback without losing the selected position (#318).
- Keep the Qwen3 TTS daemon running when `voicelayer update` removes duplicate VoiceBar launch agents (#319, #320).
- Record first-sound latency for long reads, including truthful voice fallback reporting (#321).
- Select working ffmpeg and ffprobe binaries when an incompatible copy appears on PATH, fixing clone previews, audio history and `voicelayer speak --wait` failures (#322).
- Give audio downloads both validated media tools, even when they are installed in different directories (#323).
- Keep binary-resolution caches separate for different candidate paths while reusing equivalent lookups (#324).

## [2.2.42] - 2026-10-14

### Added
- Speech settings with separate short-reply and long-read voice profiles, preview controls, and a first-sound latency readout.
- `voicelayer speak` for text, piped input, Markdown and files, with profile selection, optional waiting, and `--stop`.
- Option+F5 reads the selected text aloud; press it again to stop. Secure fields are excluded.
- Click a teleprompter word or drag the scrub bar to revisit a spoken passage.

### Changed
- Long reads synthesize and play in chunks, with shared cancellation and playback controls across VoiceBar, MCP and CLI.
- Settings now appear in this order: General, Transcription, Dictionary, Speech, History. Models is renamed Transcription; clicking sidebar status opens General.

### Fixed
- Preserve seek position and interruption handling across playback controls.
- Reconcile Speech profile selection, preview status and first-sound reporting.
- Package long-read audio helpers and provide audio tooling in CI.

Includes mission PRs #302–#315.

## [2.2.7] - 2026-08-20

### Fixed
- **Homebrew-managed VoiceBar updates now recover safely from version drift.**
  The updater refreshes the tap explicitly, compares the tapped, registered,
  and installed app versions, and adopts the current cask when they disagree
  instead of running an old destructive uninstall recipe. It resolves Homebrew
  by absolute path for non-interactive SSH, refuses root-only repair paths, and
  prevents ordinary builds from overwriting a brew-managed app (#435).

### Changed
- **The npm package page now has a focused 130-line README** with the correct
  tagline and essential install instructions; detailed architecture,
  configuration, and update material moved into dedicated docs (#436).
- Documentation now reflects the current daemon owner, automated OIDC npm
  publishing, VoiceBar 2.2.6 baseline, and the safe M1 Homebrew runbook (#434).

## [2.2.6] - 2026-08-19

### Fixed
- **Late-stop push-to-talk no longer hallucinates "All right / Thank you" outros.**
  Isolated ~250ms clicks were pinning the last-active marker, so a long quiet
  tail never trimmed and whisper invented a sign-off over the silence. Ignore
  isolated clicks and silent tails so the trim reaches the real end of speech
  (#430).
- **Menu-bar re-transcribe now targets the Settings History entry it came from**,
  and cancelled captures stay linked to their archived audio (#429).
- **Archived recordings record the audio that was actually transcribed.**
  Re-transcribing recomputed the trimmed duration, logged it, then discarded it,
  so `transcribed_duration_ms` kept reporting the original capture forever.
  Mic-on time (`duration_ms` / `raw_duration_ms`) is unchanged (#429).
- **A replaced archive can no longer take another recording's transcript.**
  The retained-capture link verified the retained WAV but never that the archive
  still held that capture, so a re-transcription could overwrite a different
  recording's transcript. The archived file's own checksum is now recorded at
  link time and verified on use (#429).
- **Archived WAVs with extra RIFF chunks are rejected before STT** instead of
  having non-PCM bytes sliced in as audio (#429).

### Added
- **Settings → History: the date header stays pinned while scrolling**, so a long
  history no longer loses track of which day you are looking at (#429).
- **Settings → History shows audio length and transcribed length separately**,
  the second only when trailing-silence trimming made them differ (#429).
- **Settings → History gained an Ask tab** (#431).

## [2.2.5] - 2026-08-15

### Fixed
- **F5/Dictation → F18 `hidutil` relay survives reboot.** Fresh-boot
  `hidutil` prints OpenStep `(null)`; `plutil` turns that into JSON
  `["null"]`, which the prior reboot fix treated as a valid mapping array.
  Merge then emitted null Src/Dst and silently wiped UserKeyMapping while the
  LaunchAgent still exited 0. Reject `["null"]` / non-object arrays, coerce
  HID fields before `Number()` (so null/false/"" cannot become synthetic
  `0→0`), and lock it with a real-`plutil` regression (#427).

## [2.2.3] - 2026-07-22

### Fixed
- **Shift+F5 re-paste works again while recording.** Since v2.1.15 the chord was
  silently swallowed whenever a recording gesture was active, so re-pasting your
  last transcript mid-recording did nothing. Restored.

  Introduced by `374fa29` ("paste transcript once and restore clipboard
  atomically"), which added a `guard !gestureIsActive` that consumed the keyDown.
  The guard was unnecessary: re-paste targets the last **completed** transcript
  (`latestReusableTranscript`), never the in-flight one, and clipboard restore is
  already protected by an `expectedChangeCount` check that skips a restore whose
  pasteboard changed underneath it. The atomic-restore guarantee is unaffected.

  Two regression tests now pin the behavior with a gesture active, and an
  `AIDEV-NOTE` marks the guard as not-to-be-reintroduced — if a paste race ever
  appears, it gets fixed in the paste path rather than by swallowing a hotkey.

### Note on 2.2.1 / 2.2.2

Those releases shipped a hover regression and are **superseded**. The hover-exit
debounce was cut from 2.5s to 300ms, which unmasked a latent bug: the hover
region excludes the topmost 1–2px row of the display, so flinging the pointer to
the top registers as hover-*exit* while the cursor is visually inside the notch.
Measured at 16 expand/collapse cycles in 34s with fail-to-summon dwells of
650–700ms. Both the debounce and the zero-pixel virtual-notch idle were reverted
to 2.2.0 behavior; evidence is archived on Brain Drive under
`06_ARCHIVE/voicelayer-notch-2026-07/hover-flake-2026-07-22/`.

## [2.2.2] - 2026-07-22

Supersedes 2.2.1, which was tagged but never published to npm.

### Fixed
- Sync the MCP registry metadata in `server.json` with `package.json`. The 2.2.1
  bump missed it, and the build-app release-contract test correctly failed the
  publish on the tag. `server.json` does not ship inside the app bundle, so the
  2.2.1 and 2.2.2 VoiceBar artifacts are functionally identical — this release
  exists so the npm package, Homebrew formula, tag, and app all agree again.

Everything in 2.2.1 below is included.

## [2.2.1] - 2026-07-22

### Fixed
- **Virtual notch no longer paints a permanent black block on external displays.**
  On a screen with no hardware notch, the collapsed idle state now draws **zero**
  pixels — matching the built-in-display contract, where the physical camera
  housing is the hover target and VoiceBar renders nothing. Previously an opaque
  185×30 core was drawn in ~99.8% of frames regardless of pointer position; with
  the menu bar auto-hidden or an app fullscreen (measured at 72.7% of a real
  session) that read as a black rectangle floating over the app's own title bar.
  A clear hover target plus a 16pt catch band keeps it summonable, hover exit now
  collapses in 300ms instead of 2.5s, and expanded states track the measured
  menu-bar height instead of a fixed 32pt (#377).

### Removed
- **The three notch morph prototypes** (`p1-matched`, `p2-native-glass`,
  `p3-spring-delight`), their selection menu, the `VOICEBAR_NOTCH_MORPH_VARIANT`
  override, and the persisted choice. They shipped unevaluated and served no one.
  The single shipped morph behavior is unchanged — this is a pure consolidation,
  net −759 lines (#379).

## [2.2.0] - 2026-07-22

### Removed — BREAKING

- **The nine `qa_voice_*` MCP aliases are gone.** The server now advertises exactly
  two tools: `voice_speak` and `voice_ask`. Removed: `qa_voice_announce`,
  `qa_voice_brief`, `qa_voice_consult`, `qa_voice_converse`, `qa_voice_think`,
  `qa_voice_say`, `qa_voice_ask`, `qa_voice_replay`, `qa_voice_toggle`.

  **No capability is lost** — every alias was surface over the two canonical tools:

  | Removed alias | Call instead |
  |---|---|
  | `qa_voice_announce` / `qa_voice_say` | `voice_speak({ mode: 'announce' })` |
  | `qa_voice_brief` | `voice_speak({ mode: 'brief' })` |
  | `qa_voice_consult` | `voice_speak({ mode: 'consult' })` |
  | `qa_voice_think` | `voice_speak({ mode: 'think' })` |
  | `qa_voice_replay` | `voice_speak({ replay_index: N })` |
  | `qa_voice_toggle` | `voice_speak({ enabled: bool })` |
  | `qa_voice_converse` / `qa_voice_ask` | `voice_ask({ ... })` |

  `voice_speak` still auto-detects the mode from message content, so most callers
  need only the tool name change. A regression test now pins the served tool list
  to exactly `["voice_speak", "voice_ask"]` so an alias cannot silently return.

## [2.1.17] - 2026-07-22 — notch convergence

The VoiceBar **notch** becomes the finished canonical surface: readable glass,
centered morphs, a truthful waveform, working system-control pass-through, and a
restored right-click menu.

### Added
- **Readable Liquid Glass + notch morph prototypes** — glass material with a legible
  content layer over the wings, and three morph prototypes evaluated against the
  camera-housing core (#362).
- **Recording hold control** contained inside the morph canvas, so VAD controls no
  longer escape the notch shape (#366).

### Changed
- **Morph originates from the notch center** and the hit area tracks the animating
  surface; wings size responsively to their content instead of being forced equal
  widths (#365).
- **Window height tracks state** rather than being pinned to the tallest state (#365).

### Fixed
- **Notch pointer coordinates vertically aligned** — `NSEvent.locationInWindow` is
  already an unflipped panel-window coordinate, but the pill hosting view converted
  it a second time through its flipped `NSHostingView`, pushing the whole hit region
  ~15–18pt DOWN (the top ~75% of every control glyph was dead). Forwarded unchanged
  (#373).
- **Right-click context menu restored** — hit-testing now claims the full *rendered*
  notch shape (`containsVisibleSurface`) for window admission and right-click, while
  the mounted control glyphs (`containsInteractiveContent`) own active controls and
  drag. Transparent margins still return `nil` (#372).
- **Notch event handling hardened** — the notch no longer intercepts clicks meant for
  adjacent macOS menu-bar controls (screen-recording stop, mic indicator, third-party
  icons), and never steals focus from the frontmost app (`.nonactivatingPanel`,
  no-key/no-main) (#370).
- **Hover stabilized** — hover authority is the global mouse monitor →
  `handlePointerMovement` → hysteresis; native glass hosts no longer own their own
  tracking areas, removing the first-hover color flicker. Empty teleprompter wing
  fixed (#371).
- **Waveform** centered and smoothed with a 200ms decay (#364), padding made
  consistent across recording/processing/speaking states (#367).
- **F5 "pill dance" fixed**, hit-region width corrected, caption ellipsis restored
  (#369).
- **Replay made atomic** — replay restarts the existing audio instead of stacking a
  second playback; the mic is released on `SIGTERM` so terminated QA instances stop
  leaving ghost menu entries (#368).
- **Teleprompter replay controls serialized**; dictionary access relocated (#363).
- Notch live-truth polish gaps closed (#359).

## [2.1.16] - 2026-07-19

### Changed
- **The notch surface is now canonical** — VoiceBar renders as a menu-bar notch
  surface around the camera housing instead of a floating draggable pill (#357, #358).

### Fixed
- Suppress stale ask prompts after a `voice_ask` timeout (#355).
- Close `voice_ask` / `voice_speak` runtime residuals (#354).

## [2.1.15] - 2026-07-19

### Added
- **Truthful waveform** — VoiceBar renders real captured/played amplitude instead of
  a decorative animation, for both recording and playback; decoding is kept off the
  speak path and bounded (#348).
- **Teleprompter persistence + VAD recording hold** — readback content is retained and
  recording can be held open through silence (#347, #349).
- Corpus-replay verification harness (isolated runtime, deterministic verifier).
- Phase-0 mined STT aliases (#343); VoiceBar dev-expanded state (#346).

### Fixed
- **Paste transcript once, restore the clipboard atomically** — removes duplicate
  pastes and clipboard clobbering; repaste key-release ordering corrected (#344).
- Restore F5 finish-paste into cmux panes (#350).
- Harden `voice_ask` waveform, timeout, and capture archive (#351).
- Stream large terminal AX insertions off the main thread (#329).
- Self-contained app bundle — bundle and sign the daemon's dependencies (#328).
- Archive paired `voice_ask` artifacts and disclose the TTS receipt (#345).

## [2.1.14] - 2026-07-14

### Added
- Voice convergence batch — corpus-replay runtime verification, teleprompter
  transition receipts, and second-wave teleprompter UX specimens (#330, #338, #339).

### Fixed
- STT polish punctuation floor: question-boundary fallback hardened; declarative
  auxiliaries and embedded named clauses no longer misread as questions.
- Corpus verifier determinism, journal isolation, and process-group reaping.

## [2.1.13] - 2026-07-13

### Added
- **Socket isolation env aliases** — `VOICELAYER_SOCKET_PATH` /
  `VOICELAYER_MCP_SOCKET_PATH` (legacy `QA_VOICE_*` still honored), so a dev VoiceBar
  never collides with the resident one (#333).
- Voice UX specimens 3b + 5 — Esc stops audio; display text is decoupled from TTS
  text (#336).
- Surface STT polish degradation to the user instead of failing silently (#335).

### Fixed
- Persist the retranscription polish surface (#337).
- Route playback interrupts to the real owner (#336).

## [2.1.12] - 2026-07-12

### Fixed
- edge-tts argparse exit-2 crash and the misleading "not installed" diagnosis (#332).
- Retry truncated STT polish candidates (#331).

## [2.1.11] - 2026-07-02

### Added
- Warm the STT polish endpoint at recording start (#326).

### Fixed
- **Restore the F5 → F18 `hidutil` remap so VoiceBar dictation survives reboots**, and
  treat a missing remap as required rather than stale in relay status (#324, #325).
- Retry no-op STT polish run-ons once (#327).
- Protect VoiceBar version integrity (#323).

## [2.1.10] - 2026-06-27

### Fixed
- VoiceBar M1 waveform and timing readiness (#322).
- VoiceBar version lock and release guards; documented the M1 Homebrew transfer.

## [2.1.9] - 2026-06-26

### Fixed
- Guard VoiceBar signing against an Apple Development identity (Developer ID only, so
  TCC grants persist across upgrades) (#318).
- Fix the STT polish timeout split (#319).

## [2.1.8] - 2026-06-26

### Changed
- VoiceBar release bump only.

## [2.1.7] - 2026-06-26

### Added
- **Developer ID notarization for VoiceBar builds** — hardened runtime signed with the
  microphone entitlement, so the shipped app keeps its TCC grants (#313).
- **Voice profile SSOT** — cloned-voice profiles resolve through one authority with
  alias/identity caches invalidated on inventory changes (#314).
- **Dictation-finalizer STT polish layer** — self-correction collapse, spoken-list
  formatting, `.at`/quote fixes.
- **Settings history browser** with pagination and retranscribe feedback (#315).
- Post-merge deploy freshness checklist (`scripts/voicelayer-deploy-check.sh` + `src/deploy-check-cli.ts`, verdict logic in `src/deploy-check.ts`). Verifies that code merged to main has actually been DELIVERED to and is live on the machine: the installed `/Applications/VoiceBar.app` was rebuilt from the current `package.json` version (build provenance via the bundle's copied `Contents/Resources/package.json`), its `Info.plist` version matches, and both VoiceBar and its MCP daemon child are running from processes that are not older than the installed bundle. Fail-closed (exit 1 + per-check remedy) on any version drift / missing bundle / stale or dead process; inconclusive (exit 0) on CI / non-macOS / off-target boxes. Closes the "build-green ≠ deployed" gap (stale-app regression; "the stack didn't transfer to the M1"). CI-safe RED→GREEN gate in `src/__tests__/deploy-check.test.ts` proves the checklist catches every flavor of "not actually deployed". Docs: `docs/deploy-checklist.md`.
- Voice-profile fail-closed gate: when a cloned voice is MANDATED (`requireClonedVoice: true` option, or the `QA_VOICE_TTS_REQUIRE_CLONE=1` global switch for a render/narration wrapper), `speak()` now raises `VoiceProfileUnavailableError` instead of silently downgrading to a preset/system TTS voice — both when the requested profile is not registered and when every cloned synthesis tier fails. The short-announcement edge-tts shortcut is also skipped under a mandate. Default behavior (no mandate) keeps the resilient fallback unchanged. Exposes `assertRegisteredClone(name)` for callers. Covers the "cloned voice not used / silent system-TTS fallback" regression.
- Golden-WAV STT regression eval suite (`src/stt-golden-eval.ts` + `src/__tests__/stt-golden-eval*.test.ts`). Deterministic detectors (fabricated/non-overlapping append, dropped content, punctuation drop) with a CI-safe RED→GREEN unit gate, plus a live golden-WAV harness that builds known spoken scripts (`say` + `sox`) and runs them through the real whisper CLI backend + finalize pipeline across the single-shot and chunked paths, asserting punctuation present, no fabricated append, no large drop, and bounded decode time. Fixtures: sub-90s short-tail, >60s medium single-shot, 108s chunked (multi-chunk merge), and an opt-in 20-minute long recording (`QA_VOICE_GOLDEN_LONG=1`). Skips cleanly when whisper/`say`/`sox` are absent.

### Fixed
- VoiceBar STT: restore punctuation-rich default transcriptions. A deterministic sentence-terminal punctuation stage (`restoreSentencePunctuation`) now runs in the default finalize path, so transcripts always end with `.`/`?` even when the optional LLM polish server is unavailable (regression: "back to zero punctuation, no commas, no periods"). Conservative and protected-token-safe — never touches slash-commands, @mentions, paths, or code identifiers; yes/no aux-pronoun openers ("do you …", "should I …") are detected as questions while imperatives ("do not …") stay statements. Covered by a deterministic unit RED→GREEN plus a golden-WAV live-outcome gate (#308).
- UX convergence pass (#317): dictionary editor presented standalone without collapsing
  the pill, settings paste target preserved across self-focus, menu-bar show action
  added, pill layout reset after unhide, context-menu actions grouped, collapsed pill
  shrunk and lowered, fallback transcribing label shown.
- History retranscribe hardened (#315) — survives record races, debounced, late pastes
  suppressed, archived audio checksum and metadata kept current.
- Bound the STT polish fallback timeout; allow correction-cue rewrites.

## [2.1.6] - 2026-06-21

### Fixed
- `voicelayer update` installs the full TTS-daemon dependency set into the venv (#307).

## [2.1.5] - 2026-06-21

### Added
- **Self-completing `build-app` update** — stop, swap, relaunch with no manual hand-off
  (#304).
- **VoiceBar autostart LaunchAgent** installed by `voicelayer setup`, for reproducible
  reboot persistence (#301).

### Fixed
- The daemon refuses an orphan startup, so VoiceBar stays its sole owner (#303).
- `bar-record` claims the cross-process voice-session lock (single-recorder) (#300).
- Handle the Homebrew cask fresh-install path in `setup` (#302).

## [2.1.4] - 2026-06-20

### Added
- **Push-to-talk speech gate** — suppresses empty transcripts when no speech was
  captured (#296).
- Context-aware whisper vocabulary aliases with a capped prompt (#295).

### Fixed
- Pass the edge-tts rate as a single `--rate=` argv token (#294).

## [2.1.3] - 2026-06-19

### Fixed

- VoiceBar STT polish: allow punctuation repair for long timestamped transcripts when the polish model writes equivalent standalone number words such as `three` for `3`, while still rejecting real numeric changes.

## [2.1.2] - 2026-06-18

### Fixed

- VoiceBar STT: stop launching resident whisper-server in no-timestamps mode, which could hallucinate fluent trailing sentences on medium-length recordings; normalize timestamped segment output into a single transcript.

## [2.1.1] - 2026-06-18

### Fixed
- VoiceBar STT: reject prompt-driven hallucinations from very short final chunks while preserving real terminal speech when an unprompted decode confirms it.

## [2.1.0] - 2026-06-17

### Added
- CLI voice coaching loop (Phase 1) — 16-chunk transcription, structured coaching workflow via `voicelayer` CLI (#53)

### Changed
- **VoiceBar renamed from FlowBar** — app name, Swift source files, TypeScript references, build scripts, and docs all updated to VoiceBar (#52)
- **Architecture inversion** — VoiceBar is now the persistent server (Unix socket IPC). MCP server acts as a thin client. Removes the facade layer between Swift and TS. (#50, #51)

### Fixed
- VoiceBar: 6 Swift bug fixes + symlink safety for `/Applications/VoiceBar.app` install (#48)
- MCP server: error recovery, session booking hardening, handler tests added (#47)

## [2.0.0] - 2026-02-28

### Changed
- **Tool consolidation** — Replaced 7 individual `qa_voice_*` tools (`qa_voice_announce`, `qa_voice_brief`, `qa_voice_consult`, `qa_voice_converse`, `qa_voice_think`, `qa_voice_say`, `qa_voice_ask`) with 2 unified tools: `voice_speak` (non-blocking TTS) and `voice_ask` (blocking record + transcribe). Old `qa_voice_*` names remain as backward-compat aliases.
- **Auto-mode detection** — `voice_speak` selects announce/brief/consult/think automatically from message content (ends with `?` → consult, length > 280 → brief, starts with `"insight:"` → think, default → announce). Override with `mode` param.
- **voice_ask auto-waits** — `voice_ask` automatically awaits any in-progress `voice_speak` playback before speaking its question, eliminating audio overlap without manual coordination.
- **MCP server name** changed from `qa-voice` to `voicelayer`.
- **npm package** renamed to `voicelayer-mcp`.

### Added
- `replay_index` param on `voice_speak` — plays a cached audio entry from the ring buffer (20-entry history at `/tmp/voicelayer-history-{0-19}.mp3`).
- `enabled` toggle on `voice_speak` — enable/disable TTS and/or mic at runtime.
- Voice Bar (macOS): floating SwiftUI widget communicating via Unix socket IPC.
- Qwen3-TTS daemon for cloned voices (three-tier routing: Qwen3-TTS → edge-tts → text-only).
- CLI commands: `voicelayer extract`, `voicelayer clone`, `voicelayer daemon`, `voicelayer bar`.

## [1.0.3] - 2026-02-25

### Fixed
- **Audio overlap between voice_speak and voice_ask** — `voice_ask` now auto-waits for any playing `voice_speak` audio to finish before speaking its question. Previously, non-blocking `voice_speak` (brief/announce/consult) could overlap with the next `voice_ask` TTS, creating unnatural double-audio.
- **Recording fails with AirPods and other non-16kHz devices** — Recording now detects the device's native sample rate and records at that rate, then resamples to 16kHz in code. Previously, sox tried to force 16kHz on devices that only support other rates (e.g., AirPods at 24kHz), causing buffer overruns and silent audio data loss when piping to stdout. Silero VAD never detected speech because the audio chunks were mostly empty.

### Added
- `awaitCurrentPlayback()` in `tts.ts` — awaits completion of any currently playing audio
- `detectNativeSampleRate()` in `audio-utils.ts` — probes default audio device via `rec -n stat`
- `resamplePCM16()` in `audio-utils.ts` — linear interpolation resampler for 16-bit PCM between arbitrary sample rates

## [1.0.2] - 2026-02-22

### Fixed
- **whisper.cpp not detected on macOS** — Homebrew v1.8.3+ renamed binary from `whisper-cpp` to `whisper-cli`. Now checks both names, preferring `whisper-cli`. This was the root cause of STT failures — local backend was never activating, forcing fallback to Wispr cloud.
- **Wispr Flow cloud fallback** — Fixed `audio_encoding` from deprecated `"pcm"` to `"wav"`. Restored 1-second PCM chunking (prevents timeout on long recordings). Wispr is now a reliable cloud fallback when whisper.cpp is unavailable.

## [1.0.1] - 2026-02-22

### Fixed
- **Wispr STT broken** — Wispr API dropped raw PCM support. Switched to `audio_encoding: "wav"` ([#9](https://github.com/EtanHey/voicelayer/pull/9))

## [1.0.0] - 2026-02-21

### Added
- Initial release — extracted from `golems/packages/qa-voice`
- 5 voice modes: announce, brief, consult, converse, think
- Local TTS via edge-tts (neural quality, free)
- Local STT via whisper.cpp (~300ms latency) or Wispr Flow (cloud)
- Session booking with lockfile mutex ("line busy" for concurrent sessions)
- User-controlled stop (touch `/tmp/voicelayer-stop`)
- MCP server with 7 tools (`qa_voice_announce`, `qa_voice_brief`, `qa_voice_consult`, `qa_voice_converse`, `qa_voice_think`, `qa_voice_say`, `qa_voice_ask`)
- Note: These tools were later consolidated into `voice_speak` and `voice_ask` (aliases still supported).
- Published to npm as `voicelayer-mcp`
- MkDocs Material documentation site (16 pages)
- GitHub Actions CI (lint, typecheck, test)
- JSON.parse validators for STT responses
- MCP Registry `server.json`

### Infrastructure
- Dark navy docs theme matching etanheyman.com
- GitHub Pages deployment workflow
- 75 unit tests across 9 test files
