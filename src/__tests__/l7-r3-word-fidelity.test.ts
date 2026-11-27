import { describe, expect, it } from "bun:test";
import { finalizeTranscriptionResultForSurface } from "../input";
import { formatDeliveryDashes } from "../stt-delivery-format";
import { polishLongTake } from "../stt-polish-chunks";

// Codex r1 on #979: word-fidelity blockers. Every fixture is synthetic.
const words = (text: string) => text.toLowerCase().match(/[\p{L}\p{M}\p{N}'’]+/gu);
const baseEnv = () => ({ ...process.env, QA_VOICE_CORRECTOR: "identity", VOICELAYER_STT_COHERENT_PARAGRAPHS: "0", VOICELAYER_STT_PAUSE_PARAGRAPHS: "0" });
const filler = "The amber project keeps every spoken thought and every repeated word in its original order. ";

/** The user message ends with the exact text the model is asked to return. */
const subject = (prompt: string) => prompt.split("text to fix:\n").pop()!;
async function withModel<T>(reply: (text: string) => string, run: (endpoint: string) => Promise<T>): Promise<T> {
  const server = Bun.serve({ port: 0, fetch: async request => {
    if (request.method !== "POST") return Response.json({ data: [{ id: "fixture" }] });
    const body = await request.json() as { messages: Array<{ content: string }> };
    return Response.json({ choices: [{ message: { content: reply(subject(body.messages.at(-1)!.content)) } }] });
  } });
  try { return await run(`http://127.0.0.1:${server.port}/v1/chat/completions`); } finally { server.stop(true); }
}

describe("B1: an apostrophe-only substitution is a different word", () => {
  const take = filler.repeat(23) + "The well is ready. " + filler.repeat(23);
  it("is at least 4,000 characters, so it takes the long-take path", () => expect(take.length).toBeGreaterThan(4000));
  it.each(["dictation", "voice_ask"] as const)("keeps 'well' when the model returns \"we'll\" on %s", async surface => {
    const result = await withModel(text => text.replace("The well is ready.", "The we'll is ready."), endpoint =>
      finalizeTranscriptionResultForSurface(take, surface, { ...baseEnv(), QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_ENDPOINT: endpoint }));
    expect(result.text).toContain("The well is ready.");
    expect(result.text).not.toContain("we'll");
    expect(words(result.text)).toEqual(words(take));
  });
  it.each(["dictation", "voice_ask"] as const)("still allows the supported dont to don't repair on %s", async surface => {
    const raw = "I dont have the time to review " + filler.repeat(3);
    const result = await withModel(text => text.replace("I dont", "I don't"), endpoint =>
      finalizeTranscriptionResultForSurface(raw, surface, { ...baseEnv(), QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_ENDPOINT: endpoint }));
    expect(result.polishStatus).toBe("applied");
    expect(result.text).toContain("I don't have");
  });
});

describe("B2: a dash cut-off stays on its own word", () => {
  const raw = "Please read the notes before we start today. I was go— going home. We are ready now.";
  it.each(["dictation", "voice_ask"] as const)("rejects a model that moves the dash to another word on %s", async surface => {
    const moved = raw.replace("go— going", "go going").replace("ready now", "ready— now");
    const result = await withModel(() => moved, endpoint =>
      finalizeTranscriptionResultForSurface(raw, surface, { ...baseEnv(), QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_ENDPOINT: endpoint }));
    expect(result.polishStatus).not.toBe("applied");
    expect(result.text).toContain("go… going");
    expect(result.text).not.toMatch(/ready\s*[…,—]/u);
    expect(words(result.text)).toEqual(words(raw));
  });
});

describe("B3: a cut-off dash keeps its marker without a same-prefix restart", () => {
  it.each([
    ["I was fu— no wait.", "I was fu… no wait."],
    ["I was fu— no wait, I mean the other one.", "I was fu… no wait, I mean the other one."],
    ["I was saying fu—", "I was saying fu…"],
    ["I was go— going home.", "I was go… going home."],
    ["Tuesday—no, Wednesday—actually Thursday.", "Tuesday, no, Wednesday, actually Thursday."],
    ["Keep words — this clause survives.", "Keep words, this clause survives."],
  ])("formats %j as %j", (input, expected) => expect(formatDeliveryDashes(input)).toBe(expected));
  it.each([null, "dictation", "voice_ask"] as const)("delivers 'fu— no wait' and an end-of-take cut-off with polish off on %s", async surface => {
    for (const [input, expected] of [["I was fu— no wait.", "I was fu… no wait."], ["I was saying fu—", "I was saying fu…"]]) {
      const result = await finalizeTranscriptionResultForSurface(input, surface, { ...baseEnv(), QA_VOICE_STT_POLISH: "off" });
      expect(result.text).toBe(expected);
    }
  });
});

describe("S4: a code fence does not switch off prose dash formatting", () => {
  it.each([null, "dictation", "voice_ask"] as const)("formats the prose on both sides and keeps the code bytes on %s", async surface => {
    const code = "```\nconst a = b — c;\n```";
    const raw = `First I was go— going home.\n${code}\nthen we were fu— no wait.`;
    const result = await finalizeTranscriptionResultForSurface(raw, surface, { ...baseEnv(), QA_VOICE_STT_POLISH: "off" });
    expect(result.text).toContain(code);
    expect(result.text).toContain("go… going home.");
    expect(result.text).toContain("fu… no wait.");
  });
});

describe("S5: a chunk that comes back after the shared deadline is not applied", () => {
  it("keeps the source slice when an applied result arrives after the budget", async () => {
    const source = "Alpha bravo charlie delta echo foxtrot golf hotel india. Juliet kilo lima mike november oscar papa.";
    const run = async (input: { cleanedText: string }) => {
      await new Promise(resolve => setTimeout(resolve, 80));
      return { inputText: input.cleanedText, text: input.cleanedText.replace("Alpha", "ALPHA, late"), polishedText: "x", mode: "on", status: "applied",
        surface: "dictation", changed: true, polished: true, retried: false, latencyMs: 80 } as never;
    };
    const result = await polishLongTake({ rawText: source, cleanedText: source, surface: "dictation" } as never, 25, run as never);
    expect(result.status).not.toBe("applied");
    expect(result.text).not.toContain("late");
    expect(words(result.text)).toEqual(words(source));
    expect(result.chunkCounts?.applied).toBe(0);
  });
});
