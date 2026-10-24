# Terminal selection and explicit Read Clipboard

Status: source authored; tests UNRUN; exact-build native acceptance NOT_PROVEN.
E1 remains ITERATE, score 6/10, D0 false. This document is not a release receipt.

## Source contract

Settings → General → Shortcut → Gestures exposes **Read Clipboard**. Copy text
yourself before choosing it. Opening/rendering Settings, hover, polling, hotkeys,
empty selection and selection errors never invoke this action automatically.
The optional Settings callback defaults to nil (disabled); production binds it
to `VoiceState.readClipboard()`, with a separate `clipboardTextReadHandler` bound
to `SpeakSelectionCapture.readClipboard(isCurrent:completion:)`.

The explicit route reads the string representation once, without trimming,
Unicode normalization, Markdown projection or whitespace/newline rewriting.
Empty/nontext clipboard, changed ownership and secure/unknown focus produce
feedback without a speech or Stop request. It never snapshots, clears, writes,
restores, synthesizes Copy, captures a selection or exports a source buffer.
Other flavors and a newer owner's data are never replaced by this route.

Recording/transcribing, active hotkey admission and disconnected/missing transport
refuse before access. After each asynchronous check, current request/session
admission is checked again on main. Stop, Cancel, F5, recording and disconnection
invalidate pending results, including duplicate callbacks and completed sessions.
Clipboard changeCount is checked around the string read and after the focus
recheck. These are authored guards, not proof of native race/security behavior.

Secure checks reuse the existing nonprompt preflight with `recover: false` and
no Chromium exemption: secure event input, secure AX role/subrole, unavailable
trust or unreadable focus fail closed. No AX activation/manual accessibility
recovery is attempted. Secure event input is checked again on main before read
and dispatch. Ordinary selection preflight/AX/Copy/snapshot/restore are unchanged.

Dispatch reuses the existing speak_text request identity, acknowledgement and
selection queue path. Existing wire fields carry `source: clipboard`, `format:
plain`, and `queue: true`; queue submission also owns the first clipboard read.
Different text queues; the same normalized text stops, following the existing
user-read comparison rule. Invalid/empty clipboard never toggles Stop. Next stays
scoped to the current request; explicit Stop clears the queue. F5's existing
retained-queue behavior is unchanged. Normal Option+F5 still uses selection and
preserved Copy, with `source: selection`/Markdown, never arbitrary old clipboard.

## Authored behavioral coverage (all UNRUN)

SpeakSelectionCaptureTests adds synthetic string/generation/focus seam coverage
for exact UTF-8, whitespace, empty/nontext, secure input/focus, unknown focus,
cancelled admission and changes during read or recheck, with Copy/snapshot/write
spies. SpeakSelectionTests adds explicit Settings callback/no automatic read,
one dispatch, busy/disconnected refusals, failure feedback without Stop, stale
and duplicate callbacks after Stop/Cancel/F5/recording/disconnect, ordinary
selection nonfallback, and queue/Next/Stop compatibility. Existing assertions stay.

Future executor: `swift test --package-path flow-bar --filter 'SpeakSelectionCaptureTests|SpeakSelectionTests'`.
No baseline RED, compile, test, visual, native or acoustic result is claimed here.

## Future exact-build native matrix

| Surface | Exact selection | Explicit copy → Read Clipboard | Secure focus | Cancellation | Clipboard race/flavors |
|---|---|---|---|---|---|
| cmux shell | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |
| cmux Claude | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |
| cmux Codex | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |
| Terminal shell | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |
| Terminal Claude | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |
| Terminal Codex | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |

The executor must also record installed modifier hints, exact source/build/loaded
identities, exact synthetic spoken text including Unicode/multiline tails, native
clipboard flavors/bytes/newer owner survival, and queue/Next/Stop/F5 compatibility.
History URL/state tests do not establish any native cell. Native outcomes remain
NOT_PROVEN until actual receipts exist; private payloads must not enter public logs.
