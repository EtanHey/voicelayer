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

  it("advances always-listening turn states with subtle settling and playback barge-in", () => {
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
    expect(state.cancelPlayback).toBe(false);
    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    expect(state.phase).toBe("LISTENING");
    expect(state.cancelPlayback).toBe(true);
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
