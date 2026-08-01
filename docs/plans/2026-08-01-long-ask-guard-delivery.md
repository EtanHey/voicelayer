# Long-ask guard delivery restoration

## Decision

Restore the complete PR #392 changeset onto a branch based directly on `origin/main`,
tighten the blocking `voice_ask` limit from 1,200 to 600 characters, retain a
separate 1,200-character pathology limit for spoken `voice_speak` modes, and add
an ancestry-based delivery audit. The restoration deliberately preserves the
teleprompter/socket fixes and their tests that disappeared with the original
guard.

The MCP description is the first-line mechanism: it teaches callers to shorten
long questions and divide them into two or more sequential `voice_ask`
checkpoints. The runtime guard is the backstop, not the primary intervention.

## Verified root cause

This was a **stacked-squash ordering hazard**, not a stale-branch overwrite:

- PR #388 targeted `main` and was squash-merged as `15530ef` at
  `2026-07-28T19:18:59Z`.
- PR #392 targeted `fix/push-to-end-rename-gate`, not `main`, and was merged as
  `8868aba` at `2026-07-28T19:19:02Z`.
- The three-second ordering matters: #392 was stacked on #388's source branch
  and squash-merged just after #388 had moved its base into `main`. Its diff was
  therefore computed against a base that had already moved.
- All ten files changed by source commit `92ccdfa` disappeared wholesale, tests
  included. This can recur for any stacked pair merged back-to-back.
- `8868aba` is not an ancestor of `origin/main`; the only remote branch that
  contains it is `origin/fix/push-to-end-rename-gate`.

Re-run the evidence with:

```bash
gh pr view 388 --json baseRefName,mergedAt,mergeCommit
gh pr view 392 --json baseRefName,mergedAt,mergeCommit
git merge-base --is-ancestor 8868aba origin/main
printf 'ancestor_exit=%s\n' "$?" # 1 means not an ancestor
git branch -a --contains 8868aba
```

Because the production changes and their regression tests were in the same
orphaned changeset, both vanished together. `main` therefore remained internally
consistent and its test suite had nothing to fail on.

The restore was done wholesale from `92ccdfa`, then refined, rather than by
hand-writing the one constant that exposed the incident. A constant-only repair
would have left the `src/tts.ts` display-slice removals and the
`src/mcp-tools.ts` description rewrite dead on `main`.

## Complete inventory of lost PR #392 hunks

The GitHub PR file list reports these ten paths. All ten were absent from `main`
after GitHub marked #392 merged:

| Path | Lost hunk |
| --- | --- |
| `docs/plans/2026-07-28-long-voice-ask-guard-design.md` | Added the 54-line original design: blocking-ask failure, caller routing, 1,200-character backstop, and teleprompter transport policy. |
| `docs/plans/2026-07-28-long-voice-ask-guard.md` | Added the 215-line TDD implementation and verification plan. |
| `src/__tests__/mcp-handler.test.ts` | Added caller-guidance coverage for blocking playback and sequential acknowledgement checkpoints. |
| `src/__tests__/socket-protocol.test.ts` | Added serializer coverage for incident-sized and oversized speaking frames. |
| `src/__tests__/soundlayer-mcp-compatibility.test.ts` | Added handler boundary, refusal, journaling, and no-TTS/no-capture coverage. |
| `src/__tests__/state-emission.test.ts` | Replaced the producer-truncation expectation with full-text delivery when the socket frame can fit it. |
| `src/__tests__/tts-display-text.test.ts` | Added 2,300-character display-text coverage for both Edge TTS and cloned TTS. |
| `src/handlers.ts` | Added the original synchronous long-ask guard, duration estimate, journal event, and self-correcting refusal. |
| `src/mcp-tools.ts` | Added short-question/blocking semantics and sequential-checkpoint routing to the `voice_ask` schema. |
| `src/tts.ts` | Removed both producer-side `slice(0, 2000)` display caps so the byte-safe socket serializer owns fitting. |

## Restoration refinements

Restoring #392 verbatim at 1,200 characters did not prevent the 2026-08-01
incident: the synthetic public fixture has the incident's measured shape (1,081
characters / 196 words), and `1,081 < 1,200`. No real transcript text is stored
in this public repository.

The restored implementation therefore uses two named hard maxima:

- `VOICE_ASK_MESSAGE_MAX_CHARS = 600` for the blocking, response-bearing tool.
- `VOICE_SPEAK_MESSAGE_MAX_CHARS = 1_200` for non-blocking spoken modes; silent
  `think` notes are exempt.

For `voice_ask`, a caller-selected timeout can tighten the per-request limit
below 600. The guard uses the same clamped timeout as `handleConverse`, its
15-second capture allowance, the measured speech rate, and a one-second margin.
This prevents a maximum-length ask from being accepted when (for example) the
caller selects the five-second minimum timeout.

Both spoken tools share one pre-synthesis refusal helper and journal a
`<tool>.message_too_long` control-layer event. The MCP descriptions state the
split limits. `voice_speak` no longer describes `consult` as a checkpoint that
invites a response: content the user must understand or respond to belongs in
sequential `voice_ask` calls because `voice_speak` does not wait for an
acknowledgement before another utterance can be queued.

The wholesale restoration also corrects one stale statement from `92ccdfa`
forward: the old description said `voice_speak` had no rewind. Issue #393
records that replay exists plus an unresolved language-specific report, so this
changeset deliberately makes no claim about rewind behavior in either direction.

## Why the blocking limit is 600

At the measured rate of roughly 13 characters/second, 600 characters is about
46 seconds. That lands on the 45-second default playback stage budget,
`(timeout_seconds + 15)s`, armed before `speak()`. The principle is that the
spoken prompt cannot consume the recording budget it is supposed to precede.
At 1,200 characters (about 92 seconds), the prompt is already twice the default
budget—indefensible for a blocking call that keeps the microphone closed behind
it. Etan explicitly confirmed the 600-character limit on 2026-08-01.

Two mechanical checks support that decision:

1. `handleConverse` gives prompt playback its own bounded
   `(timeout_seconds + 15)`-second stage while blocking TTS waits for full
   playback. The default 30-second setting therefore gives playback 45 seconds.
   Capture is rearmed after playback so the user still receives a separate
   response window.
2. The VoiceBar socket sends prompt text and RMS waveform in one 8,191-byte
   frame. After roughly 50 seconds, the envelope reaches 1,000 samples and the
   remaining measured capacity falls to about 1,254 Latin or 712 Hebrew
   characters. A 600 cap fits both scripts.

The retained dataset contains 326 `voice_ask` prompts. Its percentile table is
supporting context, not the threshold justification; rejecting 97/326 prompts
(29.8%) is the product cost of the duration-based decision:

```text
p50=409  p75=647  p90=905  p95=1058  max=2256
speech-rate p50=13.9 chars/second
refuse@600=97/326 (29.8%)
refuse@800=15.3%  refuse@1000=5.5%  refuse@1200=2.8%
```

The measured incident was 1,081 characters, 196 words, and 87.4 seconds of
audio even though the caller supplied `timeout_seconds: 180`. Etan retains the
final product decision in one exported constant so changing it is a one-line
policy edit.

## Two independent, undroppable safeguards

1. `src/__tests__/voice-ask-length-guard.test.ts` is the behavioral guard. It
   fails loudly when the 600-character gate is absent or loosened enough to
   admit the measured incident shape.
2. `scripts/verify-merged-prs-landed.sh` is the delivery guard. It refreshes
   `origin/main`, enumerates merged GitHub PRs, runs
   `git merge-base --is-ancestor <merge-sha> origin/main` for each, lists every
   unreachable merge commit, and exits non-zero when it finds one. Its shell
   behavior is covered by
   `src/__tests__/verify-merged-prs-landed-script.test.ts`.

A behavioral test alone cannot address this incident class. If a complete
changeset never reaches `main`, its test is missing too; only an independent
delivery/ancestry check can detect that GitHub's `MERGED` state did not produce
mainline reachability.

Run the delivery audit with:

```bash
bash scripts/verify-merged-prs-landed.sh
```

The audit is intentionally ancestry-based, not content-equivalence based. A
content restoration does not rewrite history or make #392's `8868aba` merge
commit an ancestor of `main`, so the audit continues to expose that historical
orphan unless the repository later adopts an explicit acknowledged-orphan
baseline. A live run also exposes substantial older stacked/squashed history;
this restoration does not silently allowlist that debt or wire a permanently
failing all-history audit into blocking CI.
