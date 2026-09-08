# Notch surface consolidation + Dictionary reliability plan

> Planning/investigation only. No product code or PR was created by this lane.
>
> Baseline inspected: `e2aed94a98cf99ef11846d6b70f40ebd05874028` (`origin/main`, 2026-08-20).
>
> Authority: `BRIEF-NOTCH-DICTIONARY.md`, the ratified repository `AGENTS.md`, and the existing History/Ask `PLAN.md` plus playback addendum.

## Goal

Make Dictionary changes truthful and useful before changing its UX. Then consolidate the launcher surfaces without creating another History list, Settings implementation, audio player, or teleprompter: the History button reads the same archive/presentation as Settings, the Dictionary launcher becomes Settings, both Settings presenters remain available by preference, and PR C remains the single owner of History playback/read-along.

## Executive verdict

Both suspected Dictionary bugs are real, but the mechanisms are narrower and more important than the initial guesses.

1. **Re-transcribe is connected and does run post-decode finalization.** The failure is a prompt-policy/Dictionary-semantics mismatch. Under the shipped source defaults, Recording re-transcribe calls `backend.transcribe(path)` without options. Default `auto` language omits user vocabulary priming on resident Whisper and Whisper CLI; Wispr ignores VoiceLayer STT options. A distinct stored misheard variant still applies later through deterministic cleanup in default corrector mode, but a canonical-only term does not. The prompt omission is deliberate silence/noise protection, so globally enabling prompts would be a bad fix.
2. **Separator/non-Latin variants can be silently discarded.** TypeScript and Swift independently reduce identity to lowercase ASCII alphanumerics. `acme widget → Acme-Widget`, `voice-layer → VoiceLayer`, a second separator spelling, and Hebrew-only values can collapse even though literal cleanup would need those distinct strings. The store may report `changed:true`; the socket may accept; the CLI prints `Added` and exits 0; Swift clears/closes the editor. `nearDuplicateWarnings` is not the drop gate.

These bugs outrank every UX phase below. The implementation sequence is intentionally serial because the installed VoiceBar/daemon is a singleton verification resource and the relevant phases converge on `SettingsView.swift`, `BarView.swift`, and the active PR-A retranscription seam.

## Evidence gathered in R0

### Bug 1 — verified call and behavior

- Notch and Settings History both reach the same Swift `retranscribeHistoryEntry` path, which sends `retranscribe_recording` through the command-owning socket client.
- TypeScript `retranscribeRecordingCapture` calls `backend.transcribe(sttWavPath)` without options at `src/input.ts:3118`, then calls `finalizeTranscriptionResultForSurface(..., "dictation")` at `:3119-3122`. Latest-recording retranscription has the same shape at `:3210-3214`.
- `getLanguageModeFromEnv()` defaults to `auto` (`src/language-config.ts:105-120`).
- Resident options deliberately set no vocabulary base prompt in auto (`src/stt.ts:1415-1438`). A continuity `promptOverride` remains continuity-only.
- CLI auto also gets no prompt: `getLanguageConfig` does not add `--prompt` in auto (`src/language-config.ts:77-99`), and `WhisperCppBackend` only replaces an already-present prompt slot (`src/stt.ts:1013-1025`). It does not insert one.
- Wispr ignores `_options` (`src/stt.ts:1450-1453`) and sends no VoiceLayer Dictionary context.
- The finalizer always runs. Default `QA_VOICE_CORRECTOR=off` bypasses the experimental corrector but still calls `cleanupTranscriptionText`; that cleanup loads current user aliases. Therefore a persisted distinct variant can alter a default/off re-transcribe while a canonical-only term cannot.
- No existing test combines archived re-transcribe, a temporary Dictionary snapshot, captured backend options, and final alias cleanup.

Safe probes showed:

```json
{
  "vocabularyNonEmpty": true,
  "autoOneShotHasPrompt": false,
  "autoContinuityEqualsSentinel": true,
  "autoContinuityIncludesVocabulary": false,
  "explicitLanguageIncludesVocabulary": true
}
```

Focused existing tests exercised six relevant prompt/finalizer/cleanup cases with zero failures. The exact command, exit, and summary are preserved in `EVIDENCE-NOTCH.md`. Those greens describe current behavior; they are not a fix.

### Bug 2 — verified mutation and feedback path

- `validateAlias` only trims/rejects empty and the unsafe source `codecs`; ordinary spaces and hyphens pass (`src/stt-vocabulary-store.ts:192-212`).
- `aliasKey` removes every non-`[a-z0-9]` character (`src/stt-vocabulary-store.ts:352-354`).
- `upsertEntryVariant` silently returns when variant and canonical keys match and reuses the first spelling when two variants share a key (`:288-317`). Snapshot normalization and alias export repeat the loss (`:214-278`, `:319-345`).
- `addAlias` still writes and returns `changed:true` after the no-op (`:91-113`).
- `nearDuplicateWarnings` only warns about the target canonical and does not stop persistence (`:356-384`).
- Swift repeats the same key collapse and clears/closes without a callback in `SettingsView.swift:1644-1666`; `STTVocabularyPreview.swift:97-120` drops the value again on decode.
- `vocab_add` accepts a same-key no-op (`src/socket-handlers.ts:283-297`). VoiceBar sends vocabulary commands without IDs, while `SocketAckEvent` requires a known command plus a non-empty ID and `IntentCommand` omits `vocab_*` (`VoiceBarContract.swift:3-73`). Rejections therefore cannot reach the editor.
- `src/cli/vocab.ts:28-53` discards mutation results and unconditionally prints success. Unquoted shell spaces and leading `--` values fail explicitly; those are separate CLI parsing errors, not this silent bug.

Safe temporary-state probes:

| Request | Stored | Reported |
|---|---|---|
| `song strip → SongScript` in a fresh target | yes | success |
| then `song-strip → SongScript` | only first spelling | success |
| `acme widget → Acme-Widget` | variant absent | `changed:true`; socket accept; CLI `Added`/0 |
| `ack me widget → Acme-Widget` | variant present | success |
| Hebrew-only canonical/variant | empty/colliding ASCII key | success or unrelated collision |

The functional consequence was also reproduced: the dropped `acme widget` mapping left `Please use acme widget today` unchanged; the distinct persisted `ack me widget` mapping produced `Please use Acme-Widget today`.

Focused current suites were green—27 Bun cases, one Swift silent-no-op regression, and 12 Swift vocabulary preview/payload cases—with exact commands/exits preserved in `EVIDENCE-NOTCH.md`. Several tests explicitly freeze the wrong behavior. The first implementation step must reverse those expectations failing-first.

## Corrections to inherited claims

| Inherited claim | Verified correction | Planning consequence |
|---|---|---|
| Auto gets vocabulary when continuity is present. | Auto forwards continuity only; it never adds `getSTTVocabularyPrompt()`. | Do not “fix” re-transcribe by merely passing `promptOverride`; local backends need an explicit lexical-bias policy. |
| Whisper CLI auto includes the built prompt. | It builds a string but has no `--prompt` slot to replace. | Test actual argv and insertion, not the intermediate string. |
| `nearDuplicateWarnings` may drop variants. | The exact/ASCII `aliasKey` equality checks drop them; near-duplicate warning is advisory. | Keep warning UX separate from mutation identity. |
| Hyphenated or multi-word values are generally rejected. | They persist unless their stripped key collides with a canonical/variant. | Regress the collision pairs, plus normal multi-word/hyphen controls. |
| The runtime receipt must land in the main checkout's `.verified/`. | The workflow checks an exact `Verified-Runtime: <HEAD_SHA>` line in the PR body. `scripts/voicelayer-verify.sh` writes supporting evidence to the invoking worktree's ignored `.verified/` by default. | Never copy a receipt between worktrees; verify the exact pushed head and PR body. |
| “Notch History” and “notch teleprompter” name one surface. | History is a launcher `.popover`; live `voice_speak` text is the physical notch's lower glass. | PR C's surface ruling remains open and must explicitly reconcile the two. |
| The June Dictionary audit's optimistic write is safe. | A local optimistic row can represent a mapping the server never persisted. | Keep fields pending until correlated outcome plus authoritative snapshot; show rejection/no-op. |

## Product and architecture decisions in this plan

### Dictionary job model

The primary job is a paired correction, not term management:

```text
Correct a mishearing

Heard       [ voice layer                    ]
Should be   [ VoiceLayer                     ]  [Save correction]

             Add recognition term only…

Search saved terms and corrections
[ 🔍 Search…                                  ]
```

- `Heard → Should be` is first and atomic. It creates the canonical entry if needed and adds the exact variant in one confirmed mutation.
- “Add recognition term only” is a clearly secondary action. Its copy states that it biases supported local Whisper paths; it must not imply that Wispr consumes it.
- Search is visually and structurally inside the saved-items area, not another unlabeled field stacked under Add.
- Existing cards keep rename/delete/variant management, but direct pair entry removes the current add-term → find-term → add-variant obstacle.
- Pending/success/duplicate/collision/error states are visible. Inputs do not clear until a correlated server outcome and returned snapshot agree.
- The June three-section proposal is useful layout prior art but is not sufficient: unchanged, it still makes the user begin with a canonical term and buries the paired correction.

### Settings presentation

- Keep one Settings content/callback factory. Do not fork a “notch Settings” implementation.
- Add a persisted launcher preference: `popover` or `window`.
- **The missing/invalid-value default requires a dated Etan ruling before the Settings-presenter PR.** If implementation reaches that gate without a ruling, preserve today's retained window behavior; do not silently make existing installs switch presenters.
- The launcher gear follows that preference. Standard macOS entry points—menu-bar Settings, context-menu Settings, and Command-comma—remain a reliable window escape hatch; opening either presenter dismisses/stops the other first.
- Move fixed sizing from the `SettingsView` content root into its presenters. The window remains 520x620/resizable; the launcher uses an anchored, focusable popover with an explicitly tested bounded size.
- Preserve `captureSettingsHistoryPasteTarget()` before VoiceBar activation so History Paste still targets the user's prior app.
- Replace the two popover booleans with one selection (`none/history/settings`) so only one launcher popover can exist and launcher retention/dismissal is deterministic.

### History presentation and playback ownership

- PR B remains owner of the shared History part/card/day-header presentation. The future notch archive view consumes it unchanged.
- Recording and Ask loaders, pagination, filters, and domain types remain separate. Sharing presentation does not mean flattening Question/Response into Recording.
- PR C remains owner of the one app-owned History playback/read-along session. The notch phase waits for PR C; it does not create a second local player.
- The current eight-item `recentTranscriptionEntries` cache is removed only from the History-button popover. It remains available to its existing F5/right-click consumers unless separately planned; issue #389 is superseded and out of scope.
- “Playback replaces the list” is modeled as a browser/active-clip presentation phase, while the PR-C session retains selected identity after Stop/finish for Restart. Visibility derives from playback/presentation phase, not merely `selectedClip != nil`.

## Decisions still required before PR C

The new wording does not safely answer the two existing PR-C questions because “notch” refers to two different UI surfaces. Before PR C creates a branch, Etan's dated wording must be recorded and frozen in tests:

1. **Read-along surface:** inline in the shared History row/popover, or the physical lower-notch glass as live `voice_speak` uses? If physical, the launcher popover still replaces its list with the active shared row/transport; only the timed text moves to the lower glass.
2. **Ask sequence:** Question and Response independent, or automatically chained? If chained, define missing-audio, manual Stop, Pause, Restart, and natural-handoff behavior.

No agent should infer these answers from “in the notch.” PR C's existing two-question task body remains authoritative; this plan changes only its branch dependency and records the launcher-popover/physical-notch distinction that Etan must account for when answering the first existing question.

## Decision still required before the archive-host PR

The brief explicitly settles natural completion: it restores the list. Before PR N5 product edits, record the remaining presentation-only lifecycle semantics without changing PR C transport behavior:

- Pause is proposed to keep the active-clip presentation visible.
- Confirm whether Stop, timing failure, playback failure, daemon-speech preemption, scope change, and presenter dismissal restore the browser immediately.
- Confirm whether restoration must preserve exact scope/day/scroll position; this plan recommends yes because rebuilding the archive browser would make “restores” materially weaker.

PR N5 observes PR C's published phase/epoch and switches presentation only. It must not add or alter playback, timing, transport, arbitration, or teleprompter semantics.

## Hard boundaries and non-goals

- No F5 wiring, capture, VAD, silence timeout, recording hold, session booking, paste mechanics, or microphone permission behavior changes.
- No trimming, fuzzy cleanup, retraction removal, sentence deletion, or fragment repair. `fu…` and retractions remain in raw order.
- Exact user-authored alias correction does change transcript text. Every Dictionary phase is therefore raw-accuracy-sensitive and must prove boundaries, punctuation, retractions, ellipsis fragments, Hebrew, and mixed Hebrew-English.
- Do not apply Recording-dictation cleanup to Ask archives. PR A's raw Ask contract stays untouched.
- Do not globally enable vocabulary prompts for live/default auto capture.
- No bundled personal Dictionary entries in tests, fixtures, screenshots, logs, PR bodies, or public artifacts. Use synthetic terms and an isolated `QA_VOICE_STT_VOCABULARY_PATH`.
- No archive migration that rewrites retained audio/transcripts. Previously dropped variants were never stored and cannot be reconstructed automatically; release notes must ask the user to re-add them without echoing private values.
- No second daemon/socket owner, History player, Settings content tree, History row/card, or teleprompter implementation.
- No `site/` edits. No #389/right-click recent-menu work. No unrelated toolbar/timezone/pill/recording changes.
- A localhost render, unit test, source-string assertion, or generated PNG is not live Mac verification.

## Dependency graph

```text
R0  This investigation + plan
 |
 v
R1  Existing PR A — Ask-safe archive retranscription core (task body unchanged)
 |
 v
R2  PR N1 — Dictionary mutation integrity and truthful feedback (Bug 2)
 |
 v
R3  PR N2 — Recording re-transcribe vocabulary policy (Bug 1)
 |
 v
R4  Existing PR B — shared Swift History row/day presentation (task body unchanged)
 |
 v
R5  PR N3 — job-first Dictionary UX
 |
 v
R6  PR N4 — shared Settings presenters + gear/preference
 |
 v
R7  Existing PR C — app-owned playback/read-along (after its original two rulings)
 |
 v
R8  PR N5 — archive History launcher host + presentation restoration
 |
 v
R9  Independent evaluator + final evidence review (no additional app swap)
```

### Why execution is sequential

PR N1 and PR N2 have mostly separate code paths, but parallel implementation would not produce independent completion: PR A currently has uncommitted `src/input.ts` work, PR N1 changes `SettingsView.swift` before PR B, and every Swift/runtime phase needs exclusive access to the one installed VoiceBar/daemon. Serial merge/rebase/live-restore cycles are cheaper than reconciling stale parallel branches or allowing two workers to swap the daily driver. No implementation `collab.md` is needed.

## Progress and estimates

Estimates are planning ranges based on touched layers and mandatory live/review gates, not calendar promises. Executors record clock-in, PR creation, clock-out, actual engineering time, and review/live wait separately. After three completed phases, remaining estimates are recalibrated from the last three actuals.

| Round | Deliverable | Depends on | Engineering estimate | Review/live estimate | Status |
|---|---|---|---:|---:|---|
| R0 | Investigation, conformance audit, plan | none | complete | independent review passed 9.8/10 | complete |
| R1 | Existing PR A | existing plan | 5-7 h (inherited) | 2-3.5 h + CI | active worktree; uncommitted |
| R2 | PR N1: mutation integrity | merged PR A | 4-6 h | 2-3 h + CI/live swap | pending |
| R3 | PR N2: re-transcribe vocabulary | merged N1 | 3-5 h | 2-3 h + real-audio swap | pending |
| R4 | Existing PR B | merged N2 | 4-5.5 h (inherited) | 2-3 h + CI/live swap | pending |
| R5 | PR N3: job-first Dictionary UX | merged PR B | 3-4.5 h | 2-3 h + mock/live swap | pending |
| R6 | PR N4: Settings presenters/gear | merged N3 + default ruling | 3-5 h | 2-3 h + visual/live swap | blocked on default ruling |
| R7 | Existing PR C | merged N4 + original two product rulings | 8-12 h (inherited) | 3-5 h + CI/live audio | blocked on rulings |
| R8 | PR N5: notch archive History host | merged PR C + non-natural-finish lifecycle ruling | 4-6 h | 2-3 h + visual/live swap, including combined program acceptance | blocked on lifecycle ruling |
| R9 | Independent convergence | all merged | 1.5-2 h | 0.5-1 h evidence audit; no new swap | pending |

## Gate-cost matrix

| PR | Why independently mergeable | `daemon-verification-gate` | Semantic installed-app proof |
|---|---|---|---|
| Existing A | Ask-safe core | Required by its planned MCP/tool paths | Existing PR-A runbook; exact Ask ID/action and F5 isolation |
| N1 | Store/protocol/UI truth without decoder policy | **Required**: `flow-bar/**` and likely `src/socket-protocol.ts`/`socket-handlers.ts` | Real add/duplicate/collision/remove in window and launcher sheet; persistence after restart; F5 smoke |
| N2 | Request-scoped decoder policy without UI redesign | Not required if diff remains `src/input.ts`, `src/stt.ts`, shared STT contract, and tests; becomes required if any workflow-matched path enters the diff | Same real retained clips on baseline/candidate; speech target improves; silence/noise does not hallucinate; F5 unchanged |
| Existing B | Shared History presentation/capability parity | **Required**: `flow-bar/**` | Existing PR-B runbook |
| N3 | Dictionary workflow only; no presenter/launcher changes | **Required**: `flow-bar/**` | Real paired correction, term-only/search distinction, pending/outcomes, keyboard/VoiceOver, light/dark, F5 smoke |
| N4 | One Settings content tree with window/popover presenters and launcher gear | **Required**: `flow-bar/**` | Real focus, preference/default, window/popover exclusivity, paste-target preservation, geometry, F5 smoke |
| Existing C | One playback/read-along session | **Required**: `flow-bar/**` + protocol | Existing PR-C real three-clip seek/read-along runbook after rulings |
| N5 | Reuses merged B/C seams; changes only launcher archive/browser presentation | **Required**: `flow-bar/**` | Real archive, sticky days, all three clip roles, list replacement/restoration, window/popover, physical-notch behavior, F5 smoke |

For every required gate, the exact full pushed head must appear as a standalone `Verified-Runtime: <40-char-sha>` line in the PR body. The invoking worktree's ignored `.verified/` receipt is supporting evidence only. Any code commit invalidates runtime evidence. Every swap begins only after Etan is idle and no recording/transcription/speech/session owns the app, and ends by restoring the canonical brew-managed app, one VoiceBar-owned daemon, healthy sockets, real-agent reconnection, and human F5 dictation.

This split program has **eight installed-app cycles**: seven workflow-triggered marker gates (existing A, N1, existing B, N3, N4, existing C, N5) plus one forced semantic N2 cycle. The combined program acceptance runs at the end of N5's exact-head installed-app session, after every dependency has merged and before N5 merges; R9 audits that evidence and does not perform a ninth swap. A later implementation diff that changes workflow matching must recalculate this count rather than copying it.

## Global execution protocol

1. Start each PR from the merged dependency shown above; record base SHA and require a clean scoped worktree.
2. Re-read `AGENTS.md`, this plan, the existing PR A/B/C plan, full touched production files, and named tests.
3. Confirm no active voice operation before audio/socket baselines or app swaps. Do not infer idleness from a missing process listing.
4. Run focused baselines. Unexpected red is reported verbatim and separated from the planned change.
5. TDD failing-first: prove each new test fails for the intended missing behavior before production edits.
6. Keep one production-file owner. Do not edit another active PR's files or “help” by rewriting its task body.
7. Run focused suites, full Bun/Swift suites as applicable, a safe throwaway build, and inspect every generated artifact rather than checking file existence.
8. Run Claude pair-review inside the local loop, then push/open one scoped PR and request `@codex review` plus `@cursor @bugbot review`. Fix only actionable findings in scope.
9. Verify remote CI/reviews against the current pushed `headSha`, never a badge or previous commit.
10. Perform the phase's installed-app semantics at that exact head, add the marker only when required, restore canonical VoiceBar, and prove single ownership/reconnection/F5.
11. Merge when implementation and reviewers are happy under repository law. Rebase the next phase on merged main; no runtime marker or local receipt carries forward.

---

# R1 — Existing PR A dependency

Do not modify PR A's task body. Its current worktree is based at `e2aed94` with uncommitted changes including `src/input.ts` and `src/__tests__/input-durability.test.ts`. PR N1 is branched only after PR A merges; PR N2 specifically consumes PR A's source-aware Recording/Ask retranscription seam and must never edit those files in parallel.

Before R2 begins, record the PR-A merge SHA and rerun the existing plan's merge gate. No claim in this plan replaces PR A's raw Ask requirements.

---

# R2 / PR N1 — Dictionary mutation integrity and truthful feedback

## Outcome

Every mutation receives a typed business result, and a claimed state change is present in the complete authoritative returned snapshot. Spaces, hyphens, dots, Hebrew, and mixed-script values are not collapsed merely because ASCII punctuation stripping makes them look alike. Swift and CLI never claim `Added` for absent data or for an operational failure.

## Intended production seams

| File/seam | Intended change |
|---|---|
| `src/stt-vocabulary-store.ts` | Separate Unicode exact identity from near-duplicate warnings; make add/remove/rename/batch outcomes truthful and atomic; retain/display legacy conflicts without exporting an ambiguous correction. |
| `src/stt-cleanup.ts` / alias export | Consume persisted NFC variants without separator-key filtering and use the exact scalar-aware simple-fold/boundary matcher below. Do not introduce fuzzy transcript matching. |
| `src/socket-protocol.ts`, `src/socket-handlers.ts` | Carry request IDs and a distinct vocabulary business result plus a durable monotonic Dictionary revision. Return the authoritative list through revision-pinned pages; keep every response within the existing byte contract. |
| `src/socket-client.ts`, `flow-bar/Sources/VoiceBar/SocketServer.swift` | Route vocabulary results/pages without logging user terms, variants, raw commands, or snapshots; diagnostics contain only command kind, ID, status, revision, and byte/count metadata. |
| `src/cli/vocab.ts` | Print truthful added/already-present/rejected results; make `add --term ... --variant ...` one atomic batch; use nonzero exit for invalid/collision, not for an idempotent duplicate. |
| `flow-bar/Sources/VoiceBarUI/VoiceBarContract.swift` | Model vocabulary commands/outcomes and correlated IDs. |
| `flow-bar/Sources/VoiceBarUI/VoiceState.swift` and vocabulary payload helpers | Send one correlated mutation, reconcile from its returned/next authoritative snapshot, and expose pending/result state. Remove blind mutation-then-list success semantics. |
| `flow-bar/Sources/VoiceBarUI/SettingsView.swift`, `STTVocabularyPreview.swift`, `DictionaryAddSheetView.swift`, `VoiceBarApp.swift` | Remove the second ASCII key gate; keep inputs pending; show duplicate/collision/error; close/clear only after confirmed persistence. |

Re-read paths after PR A merge and stop if the final protocol seam differs. Do not add a new service, file format, or parallel Swift source of truth.

## Identity contract

- Apply operations in this order: ECMAScript outer `TrimString`, NFC, then Unicode 15.1 **Simple Case Folding** using only the `C` and `S` mappings from `CaseFolding-15.1.0.txt`. Exclude full (`F`) and Turkic (`T`) mappings. Preserve every internal scalar, including repeated whitespace and punctuation; do not use NFKC. Check in the generated TypeScript table with source/version provenance and fail a golden test if the runtime/data version changes without an explicit identity review.
- That folded value is the authoritative server comparison key. `VoiceLayer`, `voice layer`, and `voice-layer` remain distinct; composed/decomposed accents collide after NFC; sigma/final-sigma and Kelvin-sign/`k` collide under simple fold; `ß` and `SS` remain distinct because full folding is excluded. Bank every case as a TypeScript golden.
- Swift does **not** reimplement, normalize, or pre-reject on that key. It submits the raw draft and renders the server-returned trimmed/NFC display value plus outcome/snapshot; local empty-field affordance may disable submit, but the server remains authoritative. Remove all Swift-side ASCII/Foundation identity keys.
- Replace the current lowercased prefilter plus escaped `/giu` matcher with one scalar-aware literal matcher using the same NFC + Unicode-15.1 simple-fold semantics. Preserve source offsets for replacement. A match boundary must reject adjacent Unicode letters (`L`), combining marks (`M`), numbers (`N`), or connector punctuation (`Pc`), so aliases do not rewrite prefixes in `acme2`, `acme_`, a base-plus-combining-mark sequence, or Hebrew plus niqqud. Do not apply separator removal, edit distance, transliteration, compatibility folding, or internal-whitespace folding.
- Keep near-duplicate/fuzzy comparison as advisory UI warning only. It cannot decide persistence or transcript replacement.
- Reject a variant whose authoritative simple-fold key equals another canonical's key because it would create an ambiguous mapping; return that canonical in a typed collision.
- An exact duplicate for the same target is idempotent and visible as “Already saved,” with `changed:false`.
- Freeze the whole collision matrix: same canonical is idempotent; variant equal to its own canonical is a visible duplicate; variant already on its own target is a duplicate; variant owned by another target is a collision and is never silently moved; new canonical equal to another entry's variant is a collision; variant equal to another canonical is a collision; near-duplicate canonical is warning-only.
- Rename is transactional, never an implicit merge. Renaming to a different existing canonical is `collision`. Renaming to the same identity and same server-normalized display is `duplicate`; a case-only/simple-fold-equivalent request with a different NFC display is a `renamed` display update with one revision increment. Validate every carried variant against the full post-rename collision matrix before writing. A future explicit merge is out of scope.
- Do not auto-rewrite existing snapshots. Read legacy values losslessly; if a legacy source is ambiguous across targets under the new exact key, retain/display it as a visible conflict but do not export it as an active correction until the user resolves it. Previously discarded values are unrecoverable and must be re-added.
- Before runtime matching, collapse aliases from all sources into one simple-fold-key map. Precedence is user Dictionary > installed/prompt-derived slash command > built-in alias. Same-key/same-target values coalesce; same-layer/same-key/different-target values are disabled as ambiguous instead of depending on object insertion or regex length order. Bank cross-layer and same-layer collisions so exactly one target—or no target for an ambiguous same layer—can match a key.

## Mutation and snapshot protocol

- Do not overload the generic transport ACK's `accept/noop/reject` vocabulary. Return a correlated `vocab_result` with `id`, command kind, `status`, optional stable reason code, warnings, and optional revision. Status is one of `added`, `removed`, `renamed`, `duplicate`, `not_found`, `collision`, `invalid`, or `error`; I/O, lock, corrupt-file, and serialization failures are `error` and never masquerade as `invalid` or success. Revision is mandatory when the store was read or committed, but may be absent when validation/lock/read failed before an authoritative revision was available. Delete of an absent target is `not_found`; idempotent add is `duplicate`.
- Persist `revision` as a nonnegative safe integer in the private snapshot (`legacy missing → 0`). Under the existing store lock, a successful state change writes content plus exactly `revision + 1`; duplicate/reject/error does not write or advance. The mutation result carries the committed revision and server-returned trimmed/NFC affected values.
- Add a correlated `vocab_page` command/response for new clients, serialized through the shared 8,191-byte cap. A request names an optional opaque cursor; every page includes request ID, one revision, total entry count, and `next_cursor`. Each ordered chunk contains a revision-local opaque `entry_id`, canonical display, variant start/total, variant slice, and legacy-conflict flags; repeated chunks for one entry must agree, cover contiguous offsets exactly once, and end explicitly. If revision changes before the cursor completes, return `revision_changed`; the client discards all partial pages and restarts from page one. Never truncate silently and never use the current raw `SocketResponse` bypass. Keep the legacy uncorrelated `vocab_list` response only when it fits the cap; otherwise return a metadata-only `upgrade_required/list_too_large` error. The bundled Swift client moves to pages in the same PR, so mixed-version rollout fails visibly rather than corrupting state.
- After `added/removed/renamed`, assemble a complete same-or-later authoritative revision and verify the requested postcondition before clearing. A later snapshot that no longer contains an added mapping is current truth, not success. Keep authoritative snapshot state separate from editor drafts; remove the current 512-term/alias data cap (render/search may virtualize, but reconciliation sees every record), and accept snapshot updates even while a draft exists.
- Allow at most one in-flight mutation per editor surface, but allow Settings and the selection sheet to overlap. Track each request by ID, connection epoch, surface, submitted raw values, and draft generation—never one global `pendingIntent`. Reversed results update only their matching request; editing after submit preserves the newer draft; timeout/disconnect marks that request “Not confirmed”; reconnect reconciles before success; late results from an old epoch are ignored.
- Server validation is exact and shared by socket/CLI: after TrimString+NFC, each canonical/variant is 1–256 Unicode scalar values and at most 1,024 UTF-8 bytes, single-line, with no Unicode `Cc`, lone surrogate, CR/LF, U+2028, or U+2029. Combining marks, Hebrew, RTL text, mixed script, spaces, and punctuation remain valid. The page format must fit one maximum-sized value plus envelope beneath 8,191 bytes.

## Failing-first tasks

1. Replace current “React.js disappears”/canonical-key no-op expectations with red store tests for:
   - `acme widget → Acme-Widget` persists and exports;
   - `voice-layer → VoiceLayer` persists;
   - `song strip` and `song-strip` both persist for one target;
   - Hebrew-only and mixed Hebrew-English entries have nonempty, noncolliding identity;
   - exact duplicate is `changed:false/duplicate`;
   - source equal to a different canonical is a typed collision;
   - an ordinary multi-word and ordinary hyphenated control remain green.
2. Bank a red cleanup integration: the persisted `acme widget` mapping changes only the exact bounded phrase in a synthetic transcript. Add negative substring, punctuation, retraction, repeated-word, `fu…`, Hebrew/mixed, unrelated-term, adjacent `\p{M}`, `\p{N}`, and `\p{Pc}` cases. Reuse the identity goldens against the matcher so a stored alias cannot be accepted under one equivalence relation and matched under another.
3. Add the backward-compatible durable revision and exact size/syntax validation above. Assert disk bytes/`updated_at`/revision do not change for duplicate/reject/error and change atomically once for add/remove. Add one atomic canonical rename that carries its variants, and one all-or-nothing term-plus-variants batch for the CLI; a rejected member cannot leave a half-created entry.
4. Add legacy fixtures for decomposed/composed Unicode, duplicate sources under one target, and one source under two targets. Prove load is lossless, ambiguous aliases are inactive/visible, and no unrelated entry is rewritten until an explicit mutation. Bank user/slash/builtin precedence plus same-layer ambiguity against the runtime matcher.
5. Bank red socket tests for stable request IDs, every `vocab_result` status, optional-versus-required revision, warning delivery, and revision receipts. Prove a fitting no-ID legacy list remains capped/parseable and an oversized one returns `upgrade_required/list_too_large`; new Swift mutations and lists always correlate. Reject malformed/oversized/control-bearing payloads without mutation. Exercise deterministic chunk assembly, incomplete/overlapping offsets, conflicting repeated metadata, multi-page reconstruction, a canonical split across pages, exact 8,191-byte serialization, mid-page `revision_changed` restart, and a maximum-sized value; no response may use the current uncapped raw path.
6. Bank red CLI tests for exact stdout/stderr and exit codes, including multi-variant atomic success/reject. Always quote multi-word examples in docs/tests; retain explicit parser failures for unquoted/leading-option values.
7. Reverse the Swift silent-no-op regression. Submit through the real mutation model, keep focus/text while pending, and assert complete untruncated snapshot membership before clear/close. Duplicate displays “Already saved”; collision/invalid/error keeps fields open with accessible text; accepted near-duplicate warnings remain visible and non-blocking.
8. Replace the current remove/add/re-add-variants rename sequence with the one correlated atomic rename. Bank rename-to-existing collision, same-display duplicate, case-only display update, carried-variant collision rollback, and successful carry. Make variant removal target both canonical and source so a legacy ambiguity cannot remove another target's mapping. Cover term delete, variant delete, and rename with the same pending/result discipline.
9. Exercise overlapping Settings/sheet mutations, reversed results, edit-after-submit, timeout/disconnect/reconnect, and late old-epoch results. Each draft follows its own ID/generation; reconnect requires complete authoritative reconciliation before claiming saved.
10. Cover the context-menu Add-to-Dictionary sheet: it must not close immediately on send. Add log-capture regressions on both socket sides proving raw commands, selected text, terms, variants, and snapshots never enter normal, malformed-frame, or dropped-command diagnostics; only metadata is allowed.
11. Prove snapshots larger than today's 512-term/alias cap remain complete in the authoritative model while the UI stays responsive, and prove an incoming snapshot reconciles while an unrelated draft is nonempty.
12. Run focused suites, then `bun test` and `swift test --package-path flow-bar`. Generate and inspect light/dark empty/pending/success/duplicate/collision/error/timeout/disconnect/legacy-conflict/Hebrew artifacts.

## Real-app acceptance

- Use a disposable vocabulary path/profile or synthetic entries only; record the pre/post private store hash, never its content.
- In the installed branch app, add each collision/control pair from Settings and the selection sheet. Confirm pending feedback, exact persisted list after refresh/restart, and no silently vanished chip.
- Run quoted CLI equivalents against isolated state and compare exit/output to the resulting snapshot.
- Re-transcribe a disposable clip whose decoded text contains the distinct variant; confirm only the authored phrase changes and raw surrounding text remains.
- Confirm live F5 still records/pastes normally, no additional owner exists, and canonical app/state is restored.

## Merge gate

- No accepted mutation lacks the requested mapping in the complete authoritative snapshot; pagination, concurrent drafts, and revision churn cannot create a false success.
- No duplicate/collision/invalid/error request clears silently or prints `Added`.
- Rename and multi-variant CLI operations cannot leave a partial entry; timeout/disconnect/late responses cannot clear the wrong draft.
- Raw-accuracy negative cases pass; no fuzzy matching or bundled personal data appears.
- Flow-bar runtime gate, exact remote head, reviews/CI, live evidence, restore, and human F5 are complete.

---

# R3 / PR N2 — Recording re-transcribe vocabulary policy

## Outcome

An explicit **Recording** re-transcribe can opt into bounded user vocabulary bias on supported local Whisper backends even in auto language, while live capture and Ask raw retranscription keep their existing safety policies. Distinct authored aliases continue to apply post-decode. The UI/documentation no longer promises canonical priming on Wispr.

## Intended production seams

- `src/soundlayer/contracts.ts` / `src/stt.ts`: add the narrowest typed purpose or `vocabularyPromptPolicy` needed to distinguish default/live behavior from explicit Recording re-transcribe.
- `src/input.ts`: only the Recording-dictation archive wrapper opts in after PR A's source classification. Ask/raw paths do not.
- `src/stt.ts`: resident auto combines bounded vocabulary with continuity for that policy; CLI inserts `--prompt` when the policy requires it rather than only replacing an existing slot; explicit language remains unchanged; Wispr reports/retains unsupported semantics without pretending to consume the prompt.
- Focused tests in `src/__tests__/stt.test.ts`, `input-durability.test.ts`, `stt-cleanup.test.ts`, and a disposable real-model corpus harness.

## Failing-first tasks

1. Extend the archived Recording retranscribe test with a recording/spied `STTBackend`, isolated Dictionary snapshot, captured caller policy, and identity polish. Test the real resident/CLI option builders directly in `stt.test.ts`; reserve the actual resident backend for installed-app acceptance. Red expectations:
   - explicit Recording re-transcribe in auto includes the bounded synthetic canonical term;
   - live/default `backend.transcribe(path)` still omits it;
   - decoded distinct variant is corrected by the finalizer;
   - Ask/raw retranscription does not enter dictation cleanup or the new prompt policy.
2. Add table tests for resident auto one-shot, resident auto continuity, resident explicit language, CLI auto argv, CLI explicit language, long-recording chunks, tail/head verification, empty Dictionary, and Wispr. Merely passing `promptOverride` is not an implementation.
3. Preserve the existing prompt-size budget and priority order. Assert no duplicate vocabulary/continuity text and no unbounded prompt.
4. Bank silence/noise safety before changing code: run the same checked-in/disposable empty, room-noise, breath, and borderline clips on baseline and candidate. Candidate must not turn a baseline empty/no-speech result into a Dictionary phrase.
5. Bank real-speech targets containing synthetic hard terms plus control clips without them. Candidate must improve/retain target recognition without inserting a term into controls, dropping words, repeating a sentence, trimming tails, resolving retractions, or damaging `fu…`.
6. Keep `QA_VOICE_CORRECTOR=off/rules/identity` behavior explicit in unit tests. Do not expand an experimental corrector mode as an accidental side effect.

## Stop condition

If request-scoped auto prompting creates a new lexical hallucination on the fixed silence/noise/control corpus, do not weaken raw/silence gates and do not ship fuzzy post-correction. Stop the PR, attach baseline/candidate transcripts and backend/model provenance, and return the product tradeoff to Etan. The safe already-working path is a confirmed explicit `Heard → Should be` variant from PR N1.

## Real-app acceptance

- Run `bash scripts/voicelayer-verify.sh --force` at the exact final head. Without `--force`, an N2-only `src/input.ts`/`src/stt.ts` diff is outside the workflow matcher and the verifier can exit without exercising the app.
- Confirm actual installed backend/model/language/corrector without printing secrets.
- On the same immutable disposable archives, compare baseline versus exact-head candidate: one canonical-only target, one paired variant, controls without the term, silence/noise, long recording, Hebrew, and mixed Hebrew-English.
- Verify archive audio is unchanged, only the intended Recording transcript/metadata update occurs, no automatic paste/Recent leak occurs, and Ask/raw behavior is unchanged.
- Human F5 dictation remains normal after the branch swap and after canonical restore.

## Merge gate

- Local Whisper auto Recording re-transcribe demonstrates useful canonical bias and zero new fixed-corpus silence/control hallucinations.
- Default/live capture, Ask raw, variant correction, and explicit-language behavior are regression-green.
- If the final diff enters a workflow-matched path, complete the formal marker gate; regardless, attach exact-head installed-app evidence and restore proof.

---

# R4 — Existing PR B dependency

Do not rework PR B's task body. Branch it from merged PR N2 so its `SettingsView.swift` work consumes the corrected Dictionary transport rather than rebasing over it later. PR B still owns:

- `SettingsHistoryRow.swift` shared part/capability/card/day-header presentation;
- separate Recording/Ask archive adaptation and pagination;
- Recording Play, Ask Response Re-transcribe/duration/Finder parity;
- its own live swap, marker, reviews, and restore.

PR B does **not** add notch hosting, Settings presentation preference, Dictionary redesign, or PR-C transport. Its merge SHA becomes R5's base.

---

# R5 / PR N3 — Job-first Dictionary UX

## Outcome

Dictionary leads with the direct paired job `Heard → Should be`, clearly separates search and recognition-only terms, and consumes PR N1's truthful pending/outcome state. This PR changes Dictionary interaction and visuals only; it does not add a Settings presenter, launcher gear, preference, History behavior, or playback.

## Mock/approval gate before production edits

Create and inspect/approve light and dark 520x620 mocks for:

- Dictionary empty state and populated long list;
- paired form idle/focused/pending/success/duplicate/collision;
- a visibly secondary recognition-term-only action;
- search clearly grouped with saved items;
- long English, Hebrew RTL, and mixed-script values;
- keyboard focus ring and accessible error text;
- the selection-sheet equivalent where shared interaction is practical.

The current visual fixture confirms why this is needed: “Add a term…” and “Search terms and variants” are two nearly identical stacked fields, while the actual misheard action lives inside a card. Do not resurrect the June term-first mock unchanged.

## Intended production seams

| Seam | Intended change |
|---|---|
| `flow-bar/Sources/VoiceBarUI/SettingsView.swift` | Render the paired form first, separate recognition-only terms and search, retain accessible edit/delete/card behavior, and consume acknowledged mutation state. |
| `flow-bar/Sources/VoiceBarUI/DictionaryAddSheetView.swift` | Reuse the same field order, labels, validation, pending, and outcome copy where its selection-driven context permits. |
| `flow-bar/Sources/VoiceBarUI/STTVocabularyPreview.swift` or a new small shared form model | Share raw draft state and presentation only; do not reintroduce normalization, storage identity, or optimistic persistence in Swift. |
| Dictionary tests/artifacts | Add real behavioral/focus/outcome coverage and approved light/dark evidence. |

## Failing-first tasks

1. Build the paired correction form on PR N1's correlated mutation model. Red tests require `Heard` then `Should be`, Tab order, Return submit, Escape cancel, disabled re-submit while pending, editable newer draft generations, authoritative clear, and visible duplicate/collision/error.
2. Prove one paired submission creates a missing canonical plus exact variant atomically; an existing canonical gets only the new variant; a reject leaves both fields intact.
3. Make recognition-only term secondary and capability-truthful. Copy distinguishes supported local Whisper bias from exact post-decode corrections and never claims Wispr consumes the prompt.
4. Put Search under a saved-items heading with magnifier/full-width hit target. Typing in it never submits a mutation.
5. Keep rename/delete/add-variant cards accessible. Long/mixed values wrap without hiding feedback or moving destructive actions into the primary path.
6. Align the context selection sheet's labels/outcomes without making it a second validation policy. It stays open while pending and on reject.
7. Generate and inspect every approved artifact, then run focused Dictionary suites, the full Swift suite, and a safe dev build.

## Real-app acceptance

- In the current retained Settings window, keyboard-navigate the paired form, recognition-only action, search, cards, and pending/error states.
- Add synthetic paired corrections and terms; trigger duplicate/collision; confirm exact outcomes survive refresh/restart and match the private store hash without exposing contents.
- Exercise the selection sheet with the same success/reject rules.
- Verify light/dark, VoiceOver labels/order, long English, Hebrew, mixed script, human F5, and canonical restore.

## Merge gate

- The paired correction job is visually/keyboard primary and no mutation lies or closes early.
- Add-only, search, and saved-item management remain distinct and backend-truthful.
- No Settings presenter, launcher, History, playback, recording, or paste-target file entered the diff unless a failing shared-form test proves it essential and the plan/status is amended first.
- Flow-bar exact-head marker, reviews/CI, visual inspection, live Dictionary interaction, F5, and restore are complete.

---

# R6 / PR N4 — Shared Settings presenters + launcher gear

## Outcome

The launcher Dictionary button becomes a Settings gear. The gear opens the same complete Settings content in an anchored popover or the retained window according to a persisted preference; both modes work and are mutually exclusive. This PR hosts the already-merged Dictionary and History content without redesigning either.

## Product and mock gate before production edits

Record Etan's dated missing/invalid-preference default. If no ruling is available, retain today's window behavior rather than silently migrating users. Then create and inspect/approve light/dark mocks for:

- window and launcher popover at their real dimensions;
- General-tab preference control and both selected states;
- every Settings tab in the popover, including long History/Dictionary content;
- launcher gear at real notch and flat-display/follow-mouse placements;
- keyboard focus, error/sheet presentation, and small-screen bounds.

## Intended production seams

| Seam | Intended change |
|---|---|
| `SettingsView.swift` | Move fixed presenter size/chrome out of the one four-tab content root; do not change merged Dictionary/History behavior. |
| New small presentation-preference type/store | Persist only `popover/window` in app `UserDefaults`; invalid/missing handling follows the dated ruling. |
| `VoiceBarApp.swift` | Keep `makeSettingsView` as the sole callback factory; coordinate one retained window and one launcher presenter; preserve paste target and standard window entry points. |
| `BarView.swift` | Replace Dictionary with Settings gear; replace independent booleans with one launcher-popover selection; inject a Settings factory/action without archive/player duplication. |
| Notch contract/tests | Rename the semantic trailing role from Dictionary to Settings while preserving the exact two-control geometry/hit regions. |

## Failing-first tasks

1. Add preference tests for both values, the dated default, invalid persisted values, and exact-once gear routing.
2. Add coordinator tests: opening popover dismisses/stops window content first; any standard window entry dismisses popover first; rapid toggles create neither duplicate window nor simultaneous popovers.
3. Prove `makeSettingsView` remains the one dependency factory and both presenters receive every tab/callback. Test presenter-owned sizing.
4. Preserve `captureSettingsHistoryPasteTarget()` before activation. Test a History Paste from both presenters into a disposable external editor target.
5. Exercise keyboard focus, Tab/Escape, permission links, sheets, long scrolling, close/reopen, and accessibility in the nonactivating-panel/popover environment.
6. Preserve two trailing launcher controls and existing notch geometry. Update semantic role/accessibility tests, not recording or panel mechanics.
7. Generate/inspect every approved artifact, run the full Swift suite, and build the dev app.

## Real-app acceptance

- Toggle the preference repeatedly; use gear, menu-bar Settings, context menu, and Command-comma. Confirm exactly one Settings presenter and no lost/crashed task.
- Type and keyboard-navigate every tab in the anchored popover. Exercise permission links, sheets, History/Dictionary scrolling, and focus without unintended dismissal.
- From both presenters, paste a History transcript to the app active before VoiceBar activation.
- Verify actual notch and non-notch/follow-mouse placement in light/dark, plus human F5 and canonical restore.

## Merge gate

- One Settings content/callback implementation serves both presenters.
- Both preference values and the dated default work; window remains an always-available escape hatch.
- Merged Dictionary/History behavior is regression-green and no second player/task owner appears.
- No recording/paste mechanism changed beyond preserving the existing target handoff.
- Flow-bar exact-head marker, reviews/CI, visual inspection, live interaction, F5, and restore are complete.

---

# R7 — Existing PR C dependency and product gate

PR C keeps its existing task body and remains the sole owner of:

- one app-owned playback session for Recording, Ask Question, and Ask Response;
- real Pause/Resume/Stop/Restart/scrub;
- exact word-timing extraction/alignment/cache and truthful unavailable state;
- the chosen read-along surface and Ask sequence;
- local History/daemon/F5 arbitration.

Only its branch base changes: PR C starts from merged PR N4, not directly from PR B. Before any production edit, record answers to the **original two** questions in “Decisions still required before PR C” and freeze them in tests. If answers conflict with the existing acceptance contract, update the coordination status and ask voiceClaude/Etan; do not silently edit PR C from this plan.

PR C regression-tests its one app-owned session from both merged Settings presenters, then completes its existing full tests, real three-clip audio/timing/seek checks, marker, reviews, and restore. Its merged app-owned session is R8's required dependency.

---

# R8 / PR N5 — Archive History launcher host + presentation restoration

## Outcome

The existing History button opens the actual retained archive using the same PR-B presentation as Settings. It no longer renders `recentTranscriptionEntries`. Selecting Play replaces the browser list with the active shared clip presentation according to the recorded PR-C surface ruling; natural finish restores the same list/scope/day/scroll position. All playback, timing, transport, arbitration, and teleprompter behavior remain owned by PR C's single session; N5 only observes phase/epoch and switches presentation.

## Intended production seams

- Extract or expose one `HistoryArchiveSurface` after PR B/C, containing the scope toolbar, separate loader state, empty/loading/pagination behavior, shared day header/row, and an injected app-owned playback session.
- Settings History and launcher History instantiate the same surface implementation. Do not merge their Recording/Ask loaders or domain models.
- `BarView` receives the factory/model through app wiring; it does not load archives into `VoiceState`.
- The launcher uses one browser/active-clip phase. Keep the browser view alive behind the switch so restoration preserves scope and scroll.
- Center the Recording/Ask segmented control with a bounded intrinsic/max width in this PR. No broader toolbar restyle.
- Remove only `historyPopover`'s dependency on `recentTranscriptionEntries` and its empty-count auto-dismiss rule. Preserve right-click recents and F5 cache behavior.

## Failing-first tasks

1. Structural/presentation tests prove Settings and launcher call the same archive surface/shared row; fail if BarView iterates `recentTranscriptionEntries` or declares a fourth row/card body.
2. Empty archive still opens and shows its true empty state. Recording/Ask scope, reload, load older, sticky day headers, missing transcript/audio, and capability matrix match Settings.
3. One-popover tests cover `none/history/settings`, keyboard retention, non-idle dismissal, active History retranscription, and rapid open/close without duplicate panels.
4. Presentation-adapter tests freeze the dated N5 ruling for Pause/Stop/failure/preemption/scope/presenter dismissal. A separate non-negotiable assertion from the brief proves natural finish restores the browser while PR C's retained selected identity remains valid for explicit Restart.
5. Integration assertions prove stale PR-C phase/epoch callbacks from clip A cannot restore/alter clip B and a second presenter cannot start a second player. Do not add transport/timing logic in N5.
6. Preserve exact browser scope/day/scroll across active playback and natural finish. If SwiftUI identity recreation loses it, fix ownership rather than adding a second cache/list.
7. Test centered segmented-control width at 520x620 and popover size, long localized labels, keyboard focus, and accessibility order.
8. Generate/inspect light/dark artifacts for Recording and Ask browser, active Recording/Question/Response, finish restoration, empty/error, long English, and mixed Hebrew-English in both Settings and launcher presentations.

## Real-app acceptance

- Populate disposable retained archives across at least two days: Recording, Ask Question/Response, missing transcript, missing audio, and paths with spaces.
- Open launcher History with no `recentTranscriptionEntries` dependency and compare it directly with Settings: order, sticky headers, capabilities, pagination, Finder targets, and retranscription.
- Play all three roles. Verify one player, exact ruled read-along surface, list replacement, the brief-fixed natural-finish restoration, the ruled Pause/Stop/failure/preemption behavior, and exact restoration of scope/scroll.
- Open/switch Settings presenter during playback according to the coordinator/session contract; no overlapping audio or second player/window/panel.
- Confirm no mic/capture/session events, paste/Recent leak, archive mutation beyond PR-C derived timing, or daemon `.speaking` counterfeit.
- Verify actual physical notch and flat-display/follow-mouse geometry, human F5, exact marker, canonical restore, single owner, sockets, and agent reconnect.

## Merge gate

- There is one archive presentation implementation, one PR-B row/day implementation, and one PR-C playback/read-along session.
- The launcher uses the archive, not the eight-item cache; Settings behavior remains parity-green.
- Natural finish restores exactly as the brief requires; every other list-restoration transition matches Etan's recorded N5 ruling and survives stale PR-C events without modifying their source semantics.
- Low-priority picker centering is the only toolbar change.
- Flow-bar exact-head marker, reviewers/CI, installed-app semantics, visual inspection, F5, and restore are complete.

---

# R9 — Independent evaluator and combined-acceptance evidence

Dispatch an evaluator that did not implement R2-R8. It must re-read this plan, the original brief, the PR A/B/C plan, every final diff, and every cited runtime record. Self-audit is not evaluation.

## Scoring rubric

Score each 0/1 and require at least 8/10 **with no hard-boundary failure**:

1. Both original bugs have failing-first regressions and exact-head real reproductions.
2. Every accepted Dictionary mutation is persisted; duplicates/collisions/errors are visible in Swift and CLI.
3. Canonical-only re-transcribe behavior is backend-truthful and silence/noise-safe; paired variants work.
4. Raw accuracy, Ask raw, retractions, `fu…`, Hebrew/mixed text, and no-trim rules remain green.
5. One shared Settings content tree serves popover/window with reliable focus/paste target and preference.
6. One shared PR-B History presentation serves Settings/launcher; loaders/domain types remain distinct.
7. One PR-C playback/read-along session serves all clip roles; product rulings are dated and exact.
8. Real launcher list replacement/restoration and center picker are visually/interactively verified.
9. Every PR's remote head, required marker, reviews/CI, live swap, canonical restore, and single-owner evidence match.
10. No capture/F5/site/#389/private-data/unplanned file entered any diff.

Any hard-boundary failure or score below 8 is `ITERATE` with specific PR/file/evidence gaps. As the final portion of N5's exact-head installed-app gate—after A/N1/N2/B/N3/N4/C have merged and before N5 merges—run one combined acceptance covering Dictionary add/correct/re-transcribe, Settings preference/presenters, archive History/action parity, three-role playback/read-along/seek, list restoration, real agent reconnect, one daemon owner, and final human F5. R9 reviews that receipt against the exact final N5 PR head and confirms the merge introduced no source change; if it did, open a corrective PR with fresh evidence. It does not reuse evidence across a code change or schedule a routine ninth swap.

## Bad ideas and explicit judgement

| Bad idea | Why it is wrong | Use instead |
|---|---|---|
| Globally enable the Dictionary prompt in auto. | Reopens the documented silence/noise prompt-hallucination risk for every capture. | Explicit Recording-retranscribe policy with fixed-corpus and live proof. |
| Claim `promptOverride` fixes CLI/resident auto. | Resident uses it only as continuity; CLI auto has no prompt slot to replace. | A typed lexical-bias policy implemented/tested per backend. |
| Fuzzy-correct transcript text using near-duplicate scoring. | Can rewrite words Etan actually said and violates raw accurate. | Persist exact authored variants; keep near-duplicate only as warning. |
| Strip punctuation/spaces to “deduplicate” aliases. | Literal correction needs those spellings; it also destroys Hebrew identity. | Unicode-aware exact identity that preserves internal separators. |
| Optimistically show a Dictionary chip then reconcile later. | Current transport can reject/drop it, reproducing the “decorative” feature. | Pending state until correlated outcome + authoritative snapshot. |
| Merge bug fixes into the Dictionary redesign. | Hides semantic/raw changes inside visual review and forces one large live gate. | N1/N2 merge before any UX phase. |
| Copy PR B's row into BarView. | Creates the fourth History implementation. | Reuse one `HistoryArchiveSurface`/PR-B row after B/C merge. |
| Point the notch popover at `recentTranscriptionEntries` and restyle it. | Still shows only a small F5-oriented cache, not retained Recording/Ask archives. | Use the archive loaders/presentation. |
| Put the whole 520x620 Settings tree inside the physical black notch. | Confuses launcher popover with constrained lower-notch geometry and focus/hit testing. | Anchored popover; physical lower glass remains PR-C read-along territory only if ruled. |
| Mount window and popover Settings simultaneously. | Creates independent `@State`/players/tasks and ambiguous Paste/focus ownership. | One presenter coordinator; close/stop before transfer. |
| Implement notch playback before PR C. | Creates a second local player/teleprompter and conflicts with PR C ownership. | N5 waits for merged C's app-owned session. |
| Restore the list whenever `playingURL == nil`. | Collapses paused/preparing/failed/stopped/selected states and races stale callbacks. | Derive presentation from PR-C phase + epoch under the recorded ruling. |
| Fold notch archive work into PR B or playback replacement into PR C. | Reopens reviewed task bodies and erases independently accepted gate costs. | Keep B/C bodies unchanged; add dependent N3/N4/N5 PRs. |
| Treat PNG generation or unit green as Mac proof. | Cannot prove anchoring, keyboard focus, sticky headers, sound, seek, F5 isolation, or owner lifecycle. | Inspect artifacts plus exact-head installed-app interactions and restore. |

## Plan-validation diff

Claims were classified before finalizing this plan:

- **Verified:** current SHA; active PR-A overlapping files; auto prompt behavior for resident/CLI/Wispr; finalizer/alias behavior; ASCII identity collapse; false-success paths; archive/popover/physical-notch separation; PR B/C ownership; workflow marker behavior.
- **Estimated:** engineering/review durations. They remain ranges and must be recalibrated from actual phase clocks.
- **Product-blocked, not guessed:** PR C's read-along surface and Ask chaining; separately, PR N4's missing/invalid preference default and PR N5's non-natural-finish restoration semantics.
- **Removed phantom:** “main checkout `.verified/` receipt is the gate.” The PR-body exact-head marker is authoritative.
- **Removed phantom:** “all multi-word/hyphen values fail.” Only separator-insensitive collisions fail.
- **Removed phantom:** “continuity turns vocabulary on in auto” and “CLI auto already sends the built prompt.” Neither is true.
- **Downgraded:** canonical-only Dictionary support is promised only for supported local Whisper Recording re-transcribe after safety proof, never for Wispr.

## Non-code deliverables

- This plan, `STATUS-NOTCH.md`, and `EVIDENCE-NOTCH.md` are the current worktree-local non-code deliverables.
- The pre-R0 audit artifacts live under `docs.local/audits/notch-dictionary/`.
- Each UI PR produces ignored local light/dark visual evidence for human inspection and attaches selected artifacts to its PR without adding private data.
- Each semantic PR adds a release-note/handoff entry describing user-visible behavior and any need to re-add previously dropped variants; it never lists the user's entries.

## Definition of done for the program

- Bugs N1/N2 merged before PR B or any new UX.
- Existing PR A/B/C task bodies remain intact and each passes its own merge gate.
- Dictionary paired correction is direct, truthful, persisted, backend-aware, and raw-accuracy-safe.
- Settings gear/preferences provide one full Settings implementation in a popover or window, with the window always recoverable.
- Launcher History is the retained archive and shares PR-B presentation plus PR-C playback/read-along; no third/fourth list or second player exists.
- Playback/list restoration and Ask sequence match dated Etan rulings.
- Every implementation PR has focused/full tests, inspected artifacts where applicable, exact remote-head reviews/CI, proportional installed-app proof, required marker, canonical restore, single-owner health, real-agent reconnect, and human F5.
- Independent evaluator scores at least 8/10 with zero hard-boundary failure.
- No recording mechanics, Ask raw semantics, private dictionary data, `site/`, #389, or unplanned cleanup changed.
