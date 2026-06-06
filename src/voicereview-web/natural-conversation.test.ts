import { describe, expect, it } from "bun:test";
import * as server from "./server";
import {
  buildInterpretMessages,
  createVoiceReviewApp,
  parseInterpretDecision,
  type ReviewCluster,
} from "./server";

const naturalCluster: ReviewCluster = {
  cluster_id: "diagnosis-flag:cantaloupe",
  category: "diagnosis-flag",
  stem: "cantaloupe",
  size: 3,
  members: [
    {
      id: "company",
      name: "Cantaloupe",
      type: "company",
      chunks: 13,
    },
    {
      id: "project",
      name: "Cantaloupe",
      type: "project",
      chunks: 4,
    },
    {
      id: "person",
      name: "Cantaloupe",
      type: "person",
      chunks: 2,
    },
  ],
};

describe("VoiceReview natural conversation redesign", () => {
  it("builds an update-first interpret prompt with per-member deltas", () => {
    const messages = buildInterpretMessages({
      transcript: "the person is not relevant, I still need company versus project",
      cluster: naturalCluster,
      understanding: {
        member_updates: {
          company: "undecided",
          project: "undecided",
          person: "undecided",
        },
        notes: [],
      },
    } as never);

    expect(messages[0].content).toContain(
      "Allowed action values: update|merge|keep|mixed|skip|question",
    );
    expect(messages[0].content).toContain("member_updates");
    expect(messages[0].content).toContain("remaining_question");
    expect(messages[0].content).toContain(
      "Only emit merge, keep, mixed, or skip when every member is resolved",
    );
    expect(messages[1].content).toContain("Current understanding:");
    expect(messages[1].content).toContain("person: undecided");
  });

  it("parses additive update deltas without forcing a terminal decision", () => {
    const decision = parseInterpretDecision(
      JSON.stringify({
        action: "update",
        member_updates: {
          person: "irrelevant",
          company: "undecided",
          project: "undecided",
        },
        remaining_question:
          "Should company and project merge, or stay separate?",
        note: "the person is not relevant",
      }),
      naturalCluster,
      "the person is not relevant",
    ) as any;

    expect(decision).toEqual({
      action: "update",
      member_updates: {
        person: "irrelevant",
        company: "undecided",
        project: "undecided",
      },
      remaining_question: "Should company and project merge, or stay separate?",
      note: "the person is not relevant",
      source: "voice",
    });
  });

  it("accumulates partial member resolutions into one terminal mixed decision", () => {
    expect(typeof (server as any).createUnderstandingState).toBe("function");
    expect(typeof (server as any).applyUnderstandingDelta).toBe("function");

    const state = (server as any).createUnderstandingState(naturalCluster);
    const first = (server as any).applyUnderstandingDelta(
      state,
      {
        action: "update",
        member_updates: {
          person: "irrelevant",
          company: "merge",
        },
        remaining_question: "What about the project?",
        note: "person is irrelevant and company is the real entity",
        source: "voice",
      },
      naturalCluster,
    );

    expect(first.terminalDecision).toBeNull();
    expect(first.state.member_updates).toMatchObject({
      person: "irrelevant",
      company: "merge",
      project: "undecided",
    });

    const second = (server as any).applyUnderstandingDelta(
      first.state,
      {
        action: "update",
        member_updates: {
          project: "keep",
        },
        note: "keep the project separate",
        source: "voice",
      },
      naturalCluster,
    );

    expect(second.terminalDecision).toEqual({
      action: "mixed",
      members: {
        company: "merge",
        project: "keep",
        person: "prune",
      },
      note:
        "person is irrelevant and company is the real entity\nkeep the project separate",
      source: "voice",
    });
  });

  it("advances always-listening turn states with subtle settling and paused barge-in", () => {
    expect(typeof (server as any).createTurnTakingState).toBe("function");
    expect(typeof (server as any).advanceTurnTakingFrame).toBe("function");

    let state = (server as any).createTurnTakingState({
      settleMs: 1200,
      frameMs: 100,
      playbackBargeInFrames: 3,
    });

    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    expect(state.phase).toBe("LISTENING");
    expect(state.hasSpeechInTurn).toBe(true);

    for (let index = 0; index < 5; index += 1) {
      state = (server as any).advanceTurnTakingFrame(state, { speech: false });
    }
    expect(state.phase).toBe("SETTLING");
    expect(state.settleProgress).toBeCloseTo(5 / 12, 3);
    expect(state.showSettlingRing).toBe(false);

    for (let index = 0; index < 3; index += 1) {
      state = (server as any).advanceTurnTakingFrame(state, { speech: false });
    }
    expect(state.phase).toBe("SETTLING");
    expect(state.showSettlingRing).toBe(true);

    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    expect(state.phase).toBe("LISTENING");
    expect(state.settleElapsedMs).toBe(0);

    state.phase = "SPEAKING";
    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    expect(state.pausePlayback).toBe(false);
    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    expect(state.phase).toBe("LISTENING");
    expect(state.pausePlayback).toBe(true);
  });

  it("splits interrupted agent speech into spoken and unspoken context", () => {
    expect(typeof (server as any).splitInterruptedSpeech).toBe("function");

    const split = (server as any).splitInterruptedSpeech(
      "First sentence gives context. Second sentence triggers the interruption.",
      [
        { offset_ms: 0, duration_ms: 200, text: "First" },
        { offset_ms: 250, duration_ms: 200, text: "sentence" },
        { offset_ms: 500, duration_ms: 200, text: "gives" },
        { offset_ms: 750, duration_ms: 200, text: "context." },
        { offset_ms: 1100, duration_ms: 200, text: "Second" },
      ],
      900,
    );

    expect(split).toEqual({
      agent_speech_spoken_so_far: "First sentence gives context.",
      agent_speech_unspoken_remainder:
        "Second sentence triggers the interruption.",
      interrupted_at_ms: 900,
    });
  });

  it("prepares browser Silero VAD tensors with 64 samples of context plus 512 audio samples", () => {
    expect(typeof (server as any).createSileroVadInput).toBe("function");

    const context = new Float32Array(64).fill(-0.25);
    const chunk = new Float32Array(512);
    for (let index = 0; index < chunk.length; index += 1) {
      chunk[index] = index / chunk.length;
    }

    const prepared = (server as any).createSileroVadInput(chunk, context);
    expect(prepared.dims).toEqual([1, 576]);
    expect(prepared.input).toHaveLength(576);
    expect(prepared.input[0]).toBe(-0.25);
    expect(prepared.input[64]).toBe(0);
    expect(prepared.nextContext).toEqual(chunk.slice(448));
  });

  it("serves one-button always-listening UI with Silero VAD, fallback labeling, and visible offline states", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect((html.match(/<button\b/g) || [])).toHaveLength(1);
    expect(html).toContain("Start session");
    expect(html).toContain("End session");
    expect(html).toContain("echoCancellation: true");
    expect(html).toContain("onnxruntime-web");
    expect(html).toContain("/models/silero_vad.onnx");
    expect(html).toContain("basic mode");
    expect(html).toContain("brain offline — retrying");
    expect(html).toContain("LISTENING");
    expect(html).toContain("SETTLING");
    expect(html).toContain("THINKING");
    expect(html).toContain("SPEAKING");
    expect(html).not.toContain("Tap Record");
    expect(html).not.toContain("tap Record");
  });

  it("does not suppress VAD barge-in while the previous turn is still processing", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect(html).not.toContain("if (!sessionActive || processingTurn) return;");
    expect(html).toContain("if (processingTurn && !turnState.pausePlayback)");
    expect(html).toContain("agent_speech_spoken_so_far");
    expect(html).toContain("agent_speech_unspoken_remainder");
    expect(html).toContain("interrupted_at_ms");
    expect(html).toContain("paused utterance");
    expect(html).toContain("resume");
  });

  it("clears paused interruption context before resumed audio can make the next turn stale", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    const clearPaused = html.slice(
      html.indexOf("function clearPausedUtterance()"),
      html.indexOf("async function resumePausedUtterance()"),
    );
    const resumePaused = html.slice(
      html.indexOf("async function resumePausedUtterance()"),
      html.indexOf("async function loadNext(play)"),
    );

    expect(clearPaused).toContain("pendingInterruption = null;");
    expect(resumePaused).toContain("pendingInterruption = null;");
    expect(resumePaused.indexOf("pendingInterruption = null;")).toBeLessThan(
      resumePaused.indexOf("await playAudioUrl"),
    );
  });

  it("hard-suppresses VAD while browser system speech is active", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    const handleVad = html.slice(
      html.indexOf("function handleVadFrame(speech)"),
      html.indexOf("function beginTurnCapture()"),
    );
    const speakSystem = html.slice(
      html.indexOf("function speakSystemText(text)"),
      html.indexOf("async function ensureMicOpen()"),
    );

    expect(html).toContain("let systemSpeechActive = false;");
    expect(handleVad).toContain("if (systemSpeechActive) return;");
    expect(speakSystem).toContain("systemSpeechActive = true;");
    expect(speakSystem).toContain("systemSpeechActive = false;");
    expect(speakSystem).toContain('turnState.phase = "SPEAKING";');
  });

  it("serves a simple chat column with collapsed evidence and no prior/current turn label soup", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect(html).toContain('id="turnLog"');
    expect(html).toContain('id="evidencePanel"');
    expect(html).toContain("<summary>Evidence</summary>");
    expect(html).not.toContain('id="evidencePanel" open');
    expect(html).not.toContain("Prior turn");
    expect(html).not.toContain("Current turn");
    expect(html).toContain("speakAgent(answer, { log: false })");
  });

  it("sanitizes spoken text separately from displayed structured data", () => {
    expect(typeof (server as any).humanizeSpokenText).toBe("function");

    const spoken = (server as any).humanizeSpokenText(
      "### Evidence\n- rt-a93575c2-1234 chunk 17 type=user_message: Merge into `kg_entity_chunks`.\nShown: <strong>raw</strong>",
    );

    expect(spoken).not.toContain("rt-a93575c2");
    expect(spoken).not.toContain("chunk 17");
    expect(spoken).not.toContain("type=user_message");
    expect(spoken).not.toContain("###");
    expect(spoken).not.toContain("<strong>");
    expect(spoken).toBe(
      "Evidence. Merge into kg entity chunks. Shown: raw",
    );

    const narrated = (server as any).humanizeSpokenText(
      "Members:\n- FooBar (project, 2 chunks)\n- Foo Bar (project, 1 chunks)\n- FooBar CLI (tool, 1 chunks)",
    );

    expect(narrated).toBe(
      "Three entries: two project entries with similar names, and one tool entry.",
    );
  });

  it("lets the reviewer configure edge-tts voice and cadence from the page", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect(html).toContain('id="ttsVoice"');
    expect(html).toContain("en-US-GuyNeural");
    expect(html).toContain('id="ttsRate"');
    expect(html).toContain('type="range"');
    expect(html).toContain("rate: selectedTtsRate()");
    expect(html).toContain("voice: selectedTtsVoice()");
  });

  it("serves the Silero model file to the browser", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(
      new Request("http://localhost/models/silero_vad.onnx"),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe(
      "application/octet-stream",
    );
    expect(Number(response.headers.get("content-length"))).toBeGreaterThan(
      2_000_000,
    );
  });

  it("reports LiteRT health failure visibly instead of leaving a dead placeholder", async () => {
    const app = createVoiceReviewApp({
      fetchImpl: async () => {
        throw new Error("connect ECONNREFUSED 127.0.0.1:9379");
      },
    });

    const response = await app.fetch(new Request("http://localhost/api/health"));
    const body = await response.json();

    expect(response.status).toBe(503);
    expect(body).toMatchObject({
      ok: false,
      message: "brain offline — retrying",
      legs: {
        litert: {
          ok: false,
        },
      },
    });
  });
});
