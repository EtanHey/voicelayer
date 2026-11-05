# P1 validation and owner handoff

Status: local verification complete; unmerged. Normal-hook push result is quoted in the PR body.

## Behavior and proof boundary

Keyed live finals (the 2.2.61 daemon protocol) capture the focused input at final
arrival. No recording-start cursor is needed, including after a bridge reconnect.
The operation is registered before History/observer callbacks or target inspection,
preventing reentrant finals
from dispatching twice. The keyed pipeline uses only admission IDs from record
start, never the old cursor identity. A same-instance bridge reconnect keeps its admitted IDs. A new
VoiceBar instance cannot know whether a recovered final was written before a
lost acknowledgment, so unknown recovered IDs stay in History for manual
recovery (`Unverified` / `In History`), preserving one-shot delivery. The receipt
reports unverified because an earlier instance may already have inserted text. History-only results and remote Ask ownership remain
separate from automatic dictation delivery.

The legacy unkeyed compatibility route freezes the ready-time app and captures
its insertion closure/identity at final arrival. It preserves its existing
activation scheduler and refuses a focus change before dispatch rather than
selecting a later app/field. It never resurrects the recording-start app when
focus is absent. The keyed production route has no such scheduling gap.

Automatic rich-host and terminal events post to the captured PID. Native AX and
VoiceBar's local field editor retain the captured element. Once writing starts,
the attempt finishes without fallback/retry; uncertain AX readback stays
unverified. The synthesized CGEvent route does not pin an input element inside
an external process. Same-process focus changes during OS consumption
remain a native acceptance limitation, explicitly outside the formal abstraction.

Global Secure Event Input is checked at selection and at the posting boundary;
secure/protected field metadata is rejected. Missing/unreadable/nontext focus
keeps the transcript and shows `Nothing to paste into; copied/kept`. It is kept,
not automatically copied: dictation never overwrites the user's clipboard.

VoiceBar's active AppKit field editor is eligible through `LocalDictationTarget`:
selection-local insertText, no AX call back into the main thread, secure field
editors rejected, possible writes consumed even when the delegate changes text.

## Producer coverage and scope (lead ruling)

All current **automatic bar dictation** producers are keyed: F5/tap/mouse route
through `VoiceBarCommandRouter.handleHotkeyHoldStart/handleHotkeySingleTap` to
`VoiceState.record` and `sendBarRecordingStart` (take_id). `socket-handlers.ts:531`
wraps waitForInput in runBarCaptureWithPausedRead; `f5-capture.ts:56` enters
runBarCapture; `recording-jobs.ts:150` stamps take_id/job_kind/delivery_id on
each final. The existing recording-jobs FIFO/reconnect runtime test now asserts
all three fields as well as complete raw words.

`voice_ask` calls waitForInput directly (`handlers.ts:956`); its unkeyed finals
are answers for the agent and must NEVER auto-paste. The remote ownership guard
in handleFinalTranscription remains unchanged. History re-transcription uses
runHistoryTranscription (`socket-handlers.ts:458,475`); its job_kind=history
finals update History without auto-paste. Shift+F5 is a local re-paste, not a
daemon producer; `testShiftF5TypesLastTranscriptIntoCurrentInput` checks it types
into the input selected when invoked. The old-daemon unkeyed compatibility
scheduler remains unchanged by design; its ready app/identity is frozen rather
than redirected by a later focus change. The dictation lead approved this
narrow scope on 2026-11-04 at 23:30:39Z after the producer audit.

## Local evidence

- RED commit `802f5dbe`: 8 tests, 8 assertion failures across 6 cases.
- New P1 guard set: 19 tests, zero failures. Includes in-memory NSTextView
  insertion, secure field-editor refusal, same-instance reconnect, fresh-instance
  replay refusal, and reentrant delivery/History callback protection.
- Combined paste/ownership/conformance guard run: 193 XCTest cases, zero failures.
- Full unfiltered Swift: 2,568 tests, 73 skipped, zero failures (heavy.sh exit 0).
  Existing permission/native/glass/benchmark opt-in skips remain explicit.
- TLC: see `formal/ready-time-paste/README.md` for exact expected-failure table.
- Full Bun: 6,957 passed, 54 skipped, 2 todo, 0 failures; 208,697 assertions
  across 347 files (`bun test`, preload enabled, real mic/archive opt-ins absent).
- Focused Bun recording-jobs contract: 7 passed, 0 failures, 48 assertions.
- TypeScript: `bun run typecheck` (`tsc --noEmit`) exited 0.
- Normal-hook push: result will be quoted in the PR body; no bypass is permitted.
- Earlier adverse receipts remain under `.build.noindex/p1`: RED, initial guard
  migrations, a first full run with 2 old-fixture assertion failures, and corrected
  compile errors. The final unfiltered run is a separate receipt, not a regrade.

## Surface sweep

- Entry points — Checked: VoiceState.handleOwnedRecordingEvent,
  handleFinalTranscription, repasteTranscript and duplicate/reconnect finals —
  keyed auto delivery selects ready focus; manual routes preserve their strategy.
- Clients — Checked: TerminalPasteTargets, ChromiumFamilyApps, CommandModeAXHelper,
  LocalDictationTarget — native AX, terminal/rich typing and own field-editor
  adapters covered locally. Per-app installed acceptance NOT RUN.
- Providers — N/A — no recognizer, microphone, TTS or processing provider changed.
- Contracts — Checked: recording-jobs delivery IDs/acks, History retention,
  no clipboard writes and uncertain AX write consumption — guards preserved.
- Reverse states — Checked: secure input/fields, absent/noneditable focus,
  same-instance reconnect, fresh-instance replay, AX completion/watchdog and
  duplicate finals — guard coverage.
- Connection modes — Checked: keyed jobs and legacy compatibility — no daemon,
  bridge, socket or launchd contract changed. Live MCP/native acceptance NOT RUN.
- Docs — Checked: CURRENT-BEHAVIOUR.md, formal README and this receipt — current
  behavior, bounded model assumptions and native limitations recorded.

## Lead acceptance

No real-app GUI e2e was performed. The dictation lead explicitly owns native
acceptance with an isolated QA build and kit-owned targets. That check needs
separate sockets, prefs and archive, kit-owned TextEdit/T3 scratch inputs, plus
the QA app's own Dictionary search; verify one insertion at ready time and
retained text on refusals without interacting with resident input.
No install, resident-app restart, live microphone or speaker playback was used.
