import { describe, expect, it } from "bun:test";
import { finalizeTranscriptionResultForSurface } from "../input";

// Synthetic full-take shape; no private transcript is published with this test.
const before = "The amber project keeps every spoken thought and every repeated word in its original order. ".repeat(120);
const after = "The violet project also needs complete raw speech with its original fragments and retractions. ".repeat(120);
const seam = "Let me know. If you want me to clarify anything.";
const fullTake = before + seam + " Okay, yeah. Keep keep fu… no wait keep both versions. " + after;
const words = (text: string) => text.toLowerCase().match(/[\p{L}\p{M}\p{N}'’]+/gu);
const baseEnv = () => ({ ...process.env, QA_VOICE_CORRECTOR: "identity", VOICELAYER_STT_COHERENT_PARAGRAPHS: "0", VOICELAYER_STT_PAUSE_PARAGRAPHS: "0" });

describe("L7 shared formatting boundary", () => {
  it("joins a conditional paragraph introduced by successful polish without changing any words", async () => {
    const raw = "The amber project keeps every spoken thought and every repeated word in its original order. ".repeat(5) + seam;
    const candidate = raw.replace("know. If", "know.\n\nIf");
    const server = Bun.serve({ port: 0, fetch: request => request.method !== "POST"
      ? Response.json({ data: [] }) : Response.json({ choices: [{ message: { content: candidate } }] }) });
    try {
      const result = await finalizeTranscriptionResultForSurface(raw, "dictation", {
        ...baseEnv(), QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
      });
      expect(result.polishStatus).toBe("applied");
      expect(result.text).toContain(seam);
      expect(words(result.text)).toEqual(words(raw));
    } finally { server.stop(true); }
  });
  it.each(["off", "on"])("keeps the conditional before a 600-second speech gap when polish is %s", async mode => {
    const left = "The amber project keeps every spoken thought and every repeated word in its original order. ".repeat(5) + seam;
    const right = "Okay, yeah. " + "The violet project needs complete raw speech with its original fragments and retractions. ".repeat(5);
    const raw = left + " " + right;
    const server = Bun.serve({ port: 0, fetch: request => request.method !== "POST"
      ? Response.json({ data: [] }) : new Promise<Response>(() => {}) });
    try {
      const result = await finalizeTranscriptionResultForSurface(raw, "dictation", {
        ...baseEnv(), QA_VOICE_STT_POLISH: mode, QA_VOICE_STT_POLISH_TIMEOUT_MS: "50",
        VOICELAYER_STT_PAUSE_PARAGRAPHS: "1",
        QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
      }, {
        segments: [{ startS: 0, endS: 20, text: left }, { startS: 620, endS: 650, text: right }],
        pauses: [{ startS: 20, endS: 620 }],
      });
      expect(words(result.text)).toEqual(words(raw));
      expect(result.text).toContain(seam);
      expect(result.text).toContain("anything.\n\nOkay, yeah.");
      expect(result.polishStatus).toBe(mode === "on" ? "failed" : "skipped");
    } finally { server.stop(true); }
  });
  it("does not strand a conditional at the only balanced boundary", async () => {
    const raw = "A ".repeat(45) + "Let me know. If you want me to clarify anything. " + "B ".repeat(35) + "completed. Then we move on.";
    const result = await finalizeTranscriptionResultForSurface(raw, null, baseEnv());
    expect(result.text).not.toContain("know.\n\nIf");
    expect(words(result.text)).toEqual(words(raw));
  });
  it.each([null, "dictation", "voice_ask"] as const)("keeps the conditional seam and all raw words when polish is off on %s", async surface => {
    const result = await finalizeTranscriptionResultForSurface(fullTake, surface, { ...baseEnv(), QA_VOICE_STT_POLISH: "off" });
    expect(words(result.text)).toEqual(words(fullTake));
    expect(result.text).toContain(seam);
    expect(result.text).toContain("Keep keep fu… no wait keep both versions.");
    expect(result.text).toContain("\n\n");
  });

  it.each([null, "dictation", "voice_ask"] as const)("substitutes U+2014 without removing words or ASCII code on %s", async surface => {
    const raw = "Keep keep fu…—no wait keep `src/input.ts` and /tmp/a-b unchanged.";
    const result = await finalizeTranscriptionResultForSurface(raw, surface, { ...baseEnv(), QA_VOICE_STT_POLISH: "off" });
    expect(result.text).not.toContain("\u2014");
    expect(words(result.text)).toEqual(words(raw));
    expect(result.text).toContain("fu…");
    expect(result.text).toContain("`src/input.ts` and /tmp/a-b");
  });

  it.each(["applied", "rejected", "failed"])("enforces the boundary after %s model polish", async scenario => {
    const raw = "Keep keep fu…—no wait keep both versions.";
    const server = Bun.serve({ port: 0, fetch: request => {
      if (request.method !== "POST") return Response.json({ data: [{ id: "fixture" }] });
      if (scenario === "failed") return new Response("fixture unavailable", { status: 503 });
      return Response.json({ choices: [{ message: { content: scenario === "rejected" ? raw + " Invented words." : raw } }] });
    } });
    try {
      const result = await finalizeTranscriptionResultForSurface(raw, "dictation", {
        ...baseEnv(), QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
      });
      expect(result.polishStatus).toBe(scenario);
      expect(result.text).not.toContain("\u2014");
      expect(words(result.text)).toEqual(words(raw));
    } finally { server.stop(true); }
  });

  it("chunks a full take, rejects additions and duplication, and formats the remainder on budget expiry", async () => {
    const requested: string[] = [];
    const server = Bun.serve({ port: 0, fetch: async request => {
      if (request.method !== "POST") return Response.json({ data: [{ id: "fixture" }] });
      const body = await request.json() as { messages: Array<{ content: string }> };
      const content = body.messages.at(-1)!.content;
      requested.push(content);
      // An unfinished real HTTP request exercises the actual deadline path.
      if (requested.length > 1) return new Promise<Response>(() => {});
      return Response.json({ choices: [{ message: { content: "Invented invented words." } }] });
    } });
    try {
      const result = await finalizeTranscriptionResultForSurface(fullTake, "dictation", {
        ...baseEnv(), QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_TIMEOUT_MS: "250",
        QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
      });
      expect(requested.length).toBeGreaterThan(1);
      expect(Math.max(...requested.map(text => text.length))).toBeLessThan(fullTake.length / 2);
      expect(words(result.text)).toEqual(words(fullTake));
      expect(result.text).toContain(seam);
      expect(result.text).toContain("Keep keep fu… no wait keep both versions.");
      expect(result.text.split("\n\n").length).toBeGreaterThan(10);
      expect(result.polishReason).toContain("chunks");
    } finally { server.stop(true); }
  });
});
