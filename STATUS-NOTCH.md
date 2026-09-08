# Notch + Dictionary Planning Status

**Lane:** `voicelayerCodex-053d5b7f`

**Mode:** Planning and investigation only; no product code and no PR

**Updated:** 2026-08-20 16:11:29 IDT

**State:** COMPLETE — PLAN REVIEWED 9.8/10

## Task authority

- `BRIEF-NOTCH-DICTIONARY.md`
- Existing `PLAN.md` for PR A / PR B / PR C coordination
- Repository `AGENTS.md` hard boundaries
- cmuxlayer worker contract

## Current work

1. `PLAN-NOTCH-DICTIONARY.md` is final at SHA-1 `2fb39313009375f57e5f590c413a6cba7fd3e073`, drafted from the verified bug reproductions and post-PR-B/C architecture seams.
2. Pre-R0 audit artifacts are written under `docs.local/audits/notch-dictionary/`; verdict is R0 CLEARED with no applicable SOTA research and no unjustified divergence.
3. The first independent evaluation returned `ITERATE — 7.7/10`. Its required corrections are now incorporated: Dictionary UX and Settings presenters are separate PRs; no unruled popover default is assumed; PR C keeps exactly its original two questions; non-natural-finish archive restoration moved to PR N5; N2 explicitly forces its installed-app verifier; and durable test receipts were added.
4. Focused Dictionary re-review passed `9.5/10`; the final whole-plan independent evaluation passed `9.8/10` with no hard blocker.
5. Final citation, dependency, cycle-accounting, mailbox, baseline, worktree-scope, and artifact-integrity checks are complete. No implementation work remains in this planning lane.

## Evidence status

- Required BrainLayer search completed before repository investigation.
- Brief and worker contract read.
- Mailbox had 0 messages at both initial and final checks; no cursor advancement was required.
- Contract mailbox follow command returned exit 0; process-list verification is unavailable in this sandbox (`pgrep: Cannot get process list`).
- Current planning baseline and `origin/main` are both `e2aed94a98cf99ef11846d6b70f40ebd05874028`.
- The active PR-A worktree remains on that base with uncommitted `src/input.ts` and test/tool changes; no PR-A completion, push, or CI claim is made.
- Bug 1 focused evidence: six existing prompt/finalizer/cleanup cases passed; a direct options probe proved auto omits Dictionary vocabulary for resident one-shot and continuity while explicit language includes it. Exact command/exit summary is in `EVIDENCE-NOTCH.md`.
- Bug 2 focused evidence: 27 Bun cases, one Swift silent-no-op case, and 12 Swift preview/payload cases passed. Exact command/exit summaries are in `EVIDENCE-NOTCH.md`. These greens intentionally freeze current bad behavior; temporary-state controls proved the silent persistence/CLI/UI loss.
- Existing Dictionary and notch visual artifacts were opened and inspected. They confirm the two near-identical top fields and buried `+ add misheard variant` job; visual inspection is context, not live proof.

## Confirmed findings

### Bug 1 — real, with an intentional safety tradeoff

- Recording re-transcribe reaches `backend.transcribe(path)` and always enters dictation finalization.
- Default auto resident Whisper and auto Whisper CLI do not receive user vocabulary priming; Wispr ignores VoiceLayer STT options.
- Default/off finalization still applies exact persisted user variants through cleanup. Canonical-only terms therefore do nothing on default-auto re-transcribe, while a valid distinct variant can work.
- Global auto prompting is rejected as a fix because it can bias silence/noise into developer terms. The plan scopes any lexical bias to explicit Recording re-transcribe and blocks merge on fixed-corpus plus real-audio safety proof.

### Bug 2 — real and broader than hyphens/spaces

- TypeScript and Swift independently strip every non-ASCII alphanumeric character for alias identity.
- Canonical-equivalent separator variants, second separator spellings, and Hebrew-only identities can be silently dropped/collided.
- Store may say `changed:true`, socket may accept, CLI prints `Added`/0, and Swift clears/closes. VoiceBar vocabulary commands lack correlated ACK IDs/enum support, so even genuine rejection reasons are not shown.
- `nearDuplicateWarnings` is advisory and is not the drop gate.
- Fix must be vertical: Unicode-aware exact identity, truthful mutation result, socket correlation, CLI status, Swift pending/feedback, and raw-accuracy regressions.

### Surface/coordination findings

- Launcher History is a SwiftUI popover over an eight-item Recent cache; the live `voice_speak` teleprompter is a different physical lower-notch surface.
- PR B's future shared row does not yet exist at this head and is presentation, not a combined archive loader.
- PR C must remain sole owner of the app-wide History player/read-along; notch archive work should consume it after merge, not create another player.
- The brief's receipt-location statement is corrected: CI checks the exact-head `Verified-Runtime` line in the PR body. The verifier's `.verified/` receipt belongs to the invoking worktree by default and is supporting evidence only.

## Hard boundaries retained

- No recording/F5/capture-path changes.
- No transcript trimming or raw-accuracy policy changes.
- No product-code edits in this lane.
- Any future `flow-bar/**` implementation requires a real-app live swap, human F5 smoke, and exact-head `Verified-Runtime` PR-body marker; the local receipt stays in the invoking worktree.
- GitHub CI cannot verify Swift behavior.
- No personal Dictionary entry was read into a fixture, screenshot, log, or plan; probes used isolated synthetic state.

## Blockers

- No blocker for investigation or worktree-local plan writing.
- PR C remains product-blocked only on its existing teleprompter-surface and Question/Response-sequence rulings.
- PR N4 separately requires a dated missing/invalid Settings-preference default; without one it preserves today's window behavior.
- PR N5 separately requires presentation-only rulings for Pause, Stop, failure, preemption, scope change, presenter dismissal, and exact scope/day/scroll preservation; natural-finish restoration is already settled by the brief.
- Contract report publication is blocked exactly as the brief warned. The required `apply_patch` attempt to `/Users/etanheyman/.cmux/agents/voicelayerCodex-053d5b7f/report.md` failed with `patch rejected: writing outside of the project; rejected by user approval settings`; the file does not exist. This worktree-local status is the completed coordination record.
