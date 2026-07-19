# Ask/Speak Substance Residuals Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the four approved ask/speak substance residuals without changing VoiceBar visuals.

**Architecture:** Reuse the existing transcription polish and capture archive paths. Add a transport-neutral MCP event context for long-running progress and playback outcomes, and upgrade queue exits from untyped completion to structured telemetry.

**Tech Stack:** Bun, TypeScript, `@modelcontextprotocol/sdk`, Unix-socket MCP framing, Bun test.

---

### Task 1: Route ask through transcription polish

**Files:**
- Modify: `src/input.ts`
- Test: `src/__tests__/input.test.ts`

1. Change the existing surface-routing test to require both `dictation` and `voice_ask` polish requests.
2. Run `bun test src/__tests__/input.test.ts` and verify the new ask assertion fails because the surface is `null`.
3. Map `archiveSource: "voice_ask"` to the `"voice_ask"` surface.
4. Re-run the targeted test and verify it passes.

### Task 2: Emit request-scoped MCP keepalives

**Files:**
- Create: `src/mcp-notifications.ts`
- Modify: `src/handlers.ts`
- Modify: `src/mcp-server.ts`
- Modify: `src/mcp-handler.ts`
- Modify: `src/mcp-daemon.ts`
- Modify: `src/mcp-server-daemon.ts`
- Test: `src/__tests__/mcp-notifications.test.ts`
- Test: `src/__tests__/mcp-handler.test.ts`
- Test: `src/__tests__/mcp-daemon.test.ts`
- Test: `src/__tests__/soundlayer-mcp-compatibility.test.ts`

1. Write tests for monotonic recording/transcribing heartbeats during a simulated long hold, progress-token notifications, logging fallback notifications, and correct daemon framing.
2. Run those targeted tests and verify they fail because no event context exists.
3. Implement the transport-neutral event context and best-effort notification mapper.
4. Start/transition/stop the ask heartbeat around `waitForInput()`.
5. Thread the context through stdio and persistent daemon transports.
6. Re-run the targeted tests and verify they pass.

### Task 3: Return and archive no-speech promptly

**Files:**
- Modify: `src/input.ts`
- Modify: `src/handlers.ts`
- Modify: `src/format-response.ts`
- Test: `src/__tests__/input.test.ts`
- Test: `src/__tests__/format-response.test.ts`
- Test: `src/__tests__/soundlayer-mcp-compatibility.test.ts`

1. Write tests proving voice-ask retains silent PCM for a capture archive, invokes capture/no-speech callbacks, and returns a distinct status instead of the configured timeout message.
2. Run the targeted tests and verify the archive/status assertions fail.
3. Add an ask-only retain-no-speech option at the recorder boundary, archive before the no-speech gate, and report the outcome callback.
4. Add the concise no-speech formatter branch.
5. Re-run the targeted tests and verify they pass.

### Task 4: Report playback interruption position

**Files:**
- Modify: `src/socket-protocol.ts`
- Modify: `src/soundlayer/contracts.ts`
- Modify: `src/tts.ts`
- Modify: `src/handlers.ts`
- Modify: `src/format-response.ts`
- Test: `src/__tests__/playback-queue.test.ts`
- Test: `src/__tests__/socket-protocol.test.ts`
- Test: `src/__tests__/soundlayer-mcp-compatibility.test.ts`

1. Write tests that stop active playback at a controlled elapsed point and require an interrupted outcome with ID, percent, and word index; also require ask prompt interruption in the final tool response.
2. Run the targeted tests and verify they fail because queue exits are untyped.
3. Add stable playback IDs and typed outcomes, using current queue progress and word boundaries.
4. Broadcast the non-visual socket event and emit the MCP follow-up notification.
5. Include playback ID in immediate speak results and interrupted ask-prompt telemetry in blocking ask results.
6. Re-run the targeted tests and verify they pass.

### Task 5: Verify and publish the worker PR

**Files:**
- Modify: `orchestrator/collab/2026-07-17-voicelayer-notch-w1-w2.md` (`### ask-residuals SEAM`)

1. Run all touched targeted suites, `bun run typecheck`, then serialized `bun test`.
2. Run `scripts/voicelayer-verify.sh --corpus 10` on the exact head and complete any runtime step the gate requires.
3. Run the bounded pre-commit CodeRabbit review; address material findings.
4. Commit exact files, push `fix/ask-speak-residuals`, and open a ready PR against `main`.
5. Invoke `@codex review` and `@cursor @bugbot review`; read and address actionable feedback without merging.
6. Post the PR URL, exact head, test evidence, verification artifact, and review dispositions under `### ask-residuals SEAM`.
7. Store the design decisions and PR milestone in BrainLayer.
