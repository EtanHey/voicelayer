import { describe, expect, it } from "bun:test";
import { finalizeTranscriptionResultForSurface } from "../input";

const raw = "Keep um— uh— er— fu— pub— pub— sorry published.";
const expected = "Keep um… uh… er… fu… pub… pub… sorry published.";
const words = (text: string) => text.match(/[\p{L}\p{M}\p{N}'’]+/gu);
const env = () => ({ ...process.env, QA_VOICE_CORRECTOR: "identity", QA_VOICE_STT_POLISH: "off" });

describe("L7 cut-off meaning at the shared delivery boundary", () => {
  it.each([null, "dictation", "voice_ask"] as const)("retains every fragment and retraction with ellipses on %s", async surface => {
    const result = await finalizeTranscriptionResultForSurface(raw, surface, env());
    expect(result.text).toBe(expected);
    expect(words(result.text)).toEqual(words(raw));
    expect(result.text.match(/pub…/gu)).toHaveLength(2);
  });

  it.each(["um", "uh", "er"])("keeps marked %s through default filler cleanup and delivery", async fragment => {
    const input = `Please keep the ${fragment}— fragment beside the complete recording details.`;
    const result = await finalizeTranscriptionResultForSurface(input, "dictation", { ...env(), QA_VOICE_CORRECTOR: undefined });
    expect(result.text).toBe(`Please keep the ${fragment}… fragment beside the complete recording details.`);
    expect(words(result.text)).toEqual(words(input));
  });

  it("keeps complete-word retraction order and treats free-standing prose dashes separately", async () => {
    const input = "Tuesday—no, Wednesday—actually Thursday. Keep all words — this clause must survive.";
    const result = await finalizeTranscriptionResultForSurface(input, null, env());
    expect(result.text).toBe("Tuesday…no, Wednesday…actually Thursday. Keep all words - this clause must survive.");
    expect(words(result.text)).toEqual(words(input));
    expect(result.text).not.toContain("\u2014");
  });

  for (const surface of ["dictation", "voice_ask"] as const) {
    it("normalizes a model-proposed prose em dash at final delivery on " + surface, async () => {
      const input = "Keep all words here - this clause must survive.";
      const candidate = "Keep all words here — this clause must survive.";
      const server = Bun.serve({ port: 0, fetch: request => request.method !== "POST"
        ? Response.json({ data: [] }) : Response.json({ choices: [{ message: { content: candidate } }] }) });
      try {
        const result = await finalizeTranscriptionResultForSurface(input, surface, {
          ...env(), QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
        });
        expect(result.polishStatus).toBe("applied");
        expect(result.text).toBe(input);
        expect(words(result.text)).toEqual(words(input));
      } finally { server.stop(true); }
    });
    it.each(["applied", "shadowed", "rejected", "failed", "timeout"])("preserves cut-off meaning after %s polish on " + surface, async status => {
      const server = Bun.serve({ port: 0, fetch: request => {
        if (request.method !== "POST") return Response.json({ data: [] });
        if (status === "timeout") return new Promise<Response>(() => {});
        if (status === "failed") return new Response("fixture unavailable", { status: 503 });
        return Response.json({ choices: [{ message: { content: status === "rejected" ? "Keep published." : raw } }] });
      } });
      try {
        const result = await finalizeTranscriptionResultForSurface(raw, surface, {
          ...env(), QA_VOICE_STT_POLISH: status === "shadowed" ? "shadow" : "on",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "50", QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
        });
        expect(result.polishStatus).toBe(status === "timeout" ? "failed" : status);
        expect(result.text).toBe(expected);
        expect(words(result.text)).toEqual(words(raw));
        expect(result.text.match(/pub…/gu)).toHaveLength(2);
      } finally { server.stop(true); }
    });
  }
});
