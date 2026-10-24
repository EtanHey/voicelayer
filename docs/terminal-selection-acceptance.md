# Terminal selection and explicit Read Clipboard

Status: source authored; every test/native cell UNRUN, acceptance NOT_PROVEN.
E1 stays ITERATE6, score 6/10, D0 false. No release or acoustic receipt is claimed.

Settings → General → Advanced → Gestures exposes **Read Clipboard**. Copy text
first, then invoke it. Settings/render/hover/poll/hotkey/selection errors never
read automatically. The optional Settings callback defaults nil (disabled);
production binds VoiceState.readClipboard to the separate native read handler.

Busy recording/transcribing/hotkey admission or missing connection/transport
refuses before access. Nonprompt preflight runs before read and dispatch without
AX recovery/exemption; secure input/focus, failed or malformed subrole evidence
refuse. Legitimate absent/unsupported subroles remain allowed. Ordinary selection
policy/queries/Copy/AX recovery/restore stay unchanged; only evidence is retained.
No explicit-route Copy, snapshot, clear, write, restore or source-buffer export.
Generation checks preserve newer ownership; current UUID/session/epoch guards
reject late/duplicate results after Stop/Cancel/F5/recording/disconnection.

Empty/nontext, JS.trim-blank or >200000 UTF-16-unit text refuses before Stop or
pending registration. Valid original Swift/wire text retains Unicode, multiline
and whitespace bytes without trimming/normalizing/truncating. Existing engine
sanitization still applies; exact engine/acoustic output is NOT_PROVEN.
Existing speak_text/source:clipboard/format:plain/queue:true owns the first read;
different text queues, same normalized text stops. Invalid reads never toggle
Stop. Next stays request-scoped; Stop clears; existing F5 queue retention stays.
Option+F5 remains selection/preserved Copy, never arbitrary clipboard fallback.

Authored seam tests cover invocation, guards, decoder subrole failures in both
windows, raw valid text, JS.trim/UTF-16 limits, cancellation, races and queue/Stop.
All G assertions remain; the fd3e whitespace-only queue fixture was parser-invalid
and now uses valid text. Original adverse reports remain immutable. Future test:
`swift test --package-path flow-bar --filter 'SpeakSelectionCaptureTests|SpeakSelectionTests'`.

| Future exact-build surface | Exact selection | Explicit clipboard | Secure focus | Cancel | Race/flavors |
|---|---|---|---|---|---|
| cmux shell | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |
| cmux Claude | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |
| cmux Codex | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |
| Terminal shell | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |
| Terminal Claude | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |
| Terminal Codex | UNRUN | UNRUN | UNRUN | UNRUN | UNRUN |

Executor receipts must include source/build/installed/loaded identity, modifier
hints, exact spoken synthetic text, clipboard bytes/flavors/newer-owner survival
and queue/Next/Stop/F5 outcomes. State/History URL tests prove no native cell;
private payloads stay out of public logs. No baseline RED or execution is claimed.
