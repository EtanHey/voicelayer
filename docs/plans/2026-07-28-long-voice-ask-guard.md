# Long `voice_ask` Guard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Teach callers to route long content through `voice_speak`, reject pathological `voice_ask` messages before synthesis, and let the socket layer safely fit full teleprompter text.

**Architecture:** Keep caller guidance in the MCP schema, add a synchronous length gate at the start of `handleVoiceAsk`, and leave transport fitting to `serializeEvent`. The gate rejects messages above 1,200 JavaScript characters, journals its decision, and returns a self-correcting routing message before session booking or TTS.

**Tech Stack:** TypeScript, Bun test runner, Zod MCP inputs, Bun SQLite journal, NDJSON socket protocol.

---

### Task 1: Establish the isolated baseline

**Files:**
- Read: `package.json`
- Read: `bun.lock`

**Step 1: Install worktree dependencies**

Run: `bun install`

**Step 2: Run the scoped baseline**

Run: `bun test src/__tests__/`
Expected: exit 0.

**Step 3: Run the compiler baseline**

Run: `npx tsc --noEmit`
Expected: exit 0.

### Task 2: Add RED schema and guard tests

**Files:**
- Modify: `src/__tests__/mcp-handler.test.ts`
- Modify: `src/__tests__/soundlayer-mcp-compatibility.test.ts`

**Step 1: Test the caller guidance**

Assert the `voice_ask` description says the question is spoken before the mic
opens, the call blocks during playback and response, long content goes through
`voice_speak` first, the subsequent `voice_ask` contains only the short
question, multiple asks are only for multiple real questions, and about 2,300
characters takes about three minutes.

**Step 2: Test the guard and journal**

Call `handleVoiceAsk` with 1,201 characters and a temporary
`VOICELAYER_CONTROL_LAYER_BASE`. Assert the error contains `1,201`, `1,200`, an
estimated duration, `voice_speak`, and the short-question instruction. Assert
TTS and capture are not called. Query `fleet-journal.db` and assert the event
contains caller `mcp.voice_ask`, message length 1,201, threshold 1,200, and an
approximate speech duration.

**Step 3: Test the accepted boundary**

Call `handleVoiceAsk` with exactly 1,200 characters using the existing mocked
successful audio/capture flow. Assert TTS and capture still run.

**Step 4: Verify RED**

Run: `bun test src/__tests__/mcp-handler.test.ts src/__tests__/soundlayer-mcp-compatibility.test.ts`
Expected: FAIL because the schema lacks the guidance and no guard exists.

### Task 3: Add RED teleprompter and socket tests

**Files:**
- Modify: `src/__tests__/tts-display-text.test.ts`
- Modify: `src/__tests__/state-emission.test.ts`
- Modify: `src/__tests__/socket-protocol.test.ts`

**Step 1: Test both TTS producer paths**

Add 2,300-character edge-TTS and cloned-voice cases. Assert each speaking event
contains the entire original display text rather than 2,000 characters.

**Step 2: Test the socket integration surface**

Broadcast a 3,000-character speaking event without producer-side slicing and
assert the mock VoiceBar receives all 3,000 characters.

**Step 3: Test socket fitting at incident and oversized lengths**

Serialize 2,300- and 10,000-character speaking events. Assert both frames stay
within `VOICEBAR_SOCKET_EVENT_MAX_BYTES`; assert 2,300 characters are preserved
in full and 10,000 characters are truncated only by the serializer to a
non-empty prefix.

**Step 4: Verify RED**

Run: `bun test src/__tests__/tts-display-text.test.ts src/__tests__/state-emission.test.ts src/__tests__/socket-protocol.test.ts`
Expected: FAIL because both TTS paths still slice display text at 2,000.

### Task 4: Implement the minimal guard and guidance

**Files:**
- Modify: `src/mcp-tools.ts`
- Modify: `src/handlers.ts`

**Step 1: Update the tool description**

Put the short-question, blocking-playback, `voice_speak` routing, genuinely
multiple-question, and 2,300-character scale instructions at the beginning of
the `voice_ask` description. Reinforce “short question” in the `message`
property.

**Step 2: Add the refusal guard**

Define a 1,200-character threshold and estimate duration from 2,300 characters
per 180 seconds. Before forwarding to `handleConverse`, reject longer messages
with an actionable error and call:

```ts
appendControlLayerEvent("voice_ask.message_too_long", {
  caller: "mcp.voice_ask",
  message_length: messageLength,
  threshold: VOICE_ASK_MESSAGE_MAX_CHARS,
  approximate_speech_seconds: approximateSpeechSeconds,
});
```

**Step 3: Verify guard GREEN**

Run: `bun test src/__tests__/mcp-handler.test.ts src/__tests__/soundlayer-mcp-compatibility.test.ts`
Expected: PASS.

### Task 5: Remove producer-side teleprompter caps

**Files:**
- Modify: `src/tts.ts`

**Step 1: Remove both slices**

Pass `displayText` unchanged to cloned and edge playback. Remove the stale
scrolling/IPC comment.

**Step 2: Verify teleprompter GREEN**

Run: `bun test src/__tests__/tts-display-text.test.ts src/__tests__/state-emission.test.ts src/__tests__/socket-protocol.test.ts`
Expected: PASS.

### Task 6: Prove the regression tests are real

**Files:**
- Temporarily revert: `src/mcp-tools.ts`
- Temporarily revert: `src/handlers.ts`
- Temporarily revert: `src/tts.ts`

**Step 1: Save the production patch**

Run: `git diff -- src/mcp-tools.ts src/handlers.ts src/tts.ts > /tmp/voicelayer-long-ask-production.patch`

**Step 2: Revert only production files**

Use `git apply -R /tmp/voicelayer-long-ask-production.patch`.

**Step 3: Re-run focused regressions**

Run: `bun test src/__tests__/mcp-handler.test.ts src/__tests__/soundlayer-mcp-compatibility.test.ts src/__tests__/tts-display-text.test.ts src/__tests__/state-emission.test.ts src/__tests__/socket-protocol.test.ts`
Expected: FAIL for missing guidance, guard, and full producer text.

**Step 4: Restore production**

Run: `git apply /tmp/voicelayer-long-ask-production.patch`

**Step 5: Re-run focused regressions**

Run the same focused command.
Expected: PASS.

### Task 7: Verify, review, commit, and open the stacked PR

**Files:**
- Create locally: `docs.local/qa/long-ask-guard/report.md`

**Step 1: Run required verification**

Run: `bun test src/__tests__/`
Expected: exit 0.

Run: `npx tsc --noEmit`
Expected: exit 0.

Run: `git diff --check`
Expected: exit 0.

**Step 2: Run bounded local review**

Run `coderabbit review --agent` with a roughly three-minute hard timeout.
Address any substantive findings, or record an unavailable/rate-limited result.

**Step 3: Commit implementation**

Stage only the plan, source, and test files. Commit without touching
`flow-bar/Sources/VoiceBarUI/VoiceState.swift`.

**Step 4: Push and create the PR**

Push `fix/long-ask-guard` and create a ready-for-review PR with base
`fix/push-to-end-rename-gate`. Explain why 1,200 is the sparse backstop and why
refusal is necessary. Do not merge.

**Step 5: Invoke required reviewers**

Comment `@codex review` and `@cursor @bugbot review`, then read available
responses. The terminal endpoint is the open, unmerged stacked PR.

**Step 6: Write and verify the local report**

Include `git log --oneline -1`, RED/GREEN/revert proof, PR URL, threshold
justification, and the final tool description quoted in full. Re-read the
complete report and ensure its final line is exactly `TASK_DONE`.
