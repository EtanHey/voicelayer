import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { finalizeTranscriptionResultForSurface } from "../input";
import { applyCoherentParagraphFallback, applyCoherentParagraphs } from "../stt-coherent-paragraphs";

const text = [
  "We moved the deploy script into the release folder last week.",
  "The script now builds the bundle and signs it with the team key.",
  "Signing takes about two minutes on the older laptop.",
  "The bundle is uploaded to the storage bucket after that.",
  "Anyway, for dinner tonight I want to try the new noodle place.",
  "They have a vegetarian menu and the reviews look really good.",
  "We should book a table for seven people around eight.",
  "My sister says the parking there is terrible on weekends.",
].join(" ");
const env = () => ({
  ...process.env,
  QA_VOICE_CORRECTOR: "identity",
  QA_VOICE_STT_POLISH: "on",
  QA_VOICE_STT_POLISH_ENDPOINT: "http://formatting.invalid/v1/chat/completions",
  VOICELAYER_STT_COHERENT_PARAGRAPHS: undefined,
  VOICELAYER_STT_PAUSE_PARAGRAPHS: undefined,
});
let fetchMock: ReturnType<typeof spyOn> | undefined;
afterEach(() => fetchMock?.mockRestore());

function reply(behavior: string, content = text): void {
  fetchMock = spyOn(globalThis, "fetch").mockImplementation(Object.assign(async (_url: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    if (init?.method !== "POST") {
      return behavior === "health-error"
        ? new Response("Unavailable", { status: 503 })
        : Response.json({ data: [] });
    }
    if (behavior === "timeout") throw new DOMException("Timed out", "AbortError");
    if (behavior === "http-error") return new Response("Unavailable", { status: 503 });
    return Response.json({ choices: [{ message: {
      content: behavior === "rejected" ? "Raw Whisper text: " + content
        : behavior === "paragraphs" ? content.replace(". Anyway", ".\n\nAnyway") : content,
    } }] });
  }, { preconnect: () => {} }));
}

function expectOnlyWhitespaceChanges(input: string, output: string): void {
  expect(output.replace(/\s/gu, "")).toBe(input.replace(/\s/gu, ""));
  expect(Buffer.from(output.replace(/\s/gu, ""), "utf8")
    .equals(Buffer.from(input.replace(/\s/gu, ""), "utf8"))).toBe(true);
  expect(output.split(/\s+/u)).toEqual(input.split(/\s+/u));
}

describe("eligible compact paragraph floor", () => {
  // Five complete sentence units; no cut satisfies the primary stage's stricter
  // paragraph-size preferences, despite meeting both initial text floors.
  const compact = [25, 13, 12, 19, 16]
    .map(count => ["We", ...Array<string>(count - 1).fill("detail")].join(" ") + ".").join(" ");

  it("uses a safe balanced boundary when primary grouping leaves eligible prose unformatted", () => {
    expect(applyCoherentParagraphs(compact)).toBe(compact);
    const output = applyCoherentParagraphFallback(compact);
    expect(output.split("\n\n")).toHaveLength(2);
    expectOnlyWhitespaceChanges(compact, output);
  });

  for (const surface of ["dictation", "voice_ask"] as const) {
    it(`${surface} formats an eligible five-sentence final with polish off`, async () => {
      const result = await finalizeTranscriptionResultForSurface(compact, surface, { ...env(), QA_VOICE_STT_POLISH: "off" });
      expect(result.text.split("\n\n")).toHaveLength(2);
      expectOnlyWhitespaceChanges(compact, result.text);
      expect(result.polishStatus).toBe("skipped");
    });
  }

  it("vetoes compact literal code before balanced fallback", () => {
    const raw = "`" + compact + "`";
    expect(applyCoherentParagraphFallback(raw)).toBe(raw);
  });

  it("keeps an eligible oversized single item inside its original list marker", () => {
    const raw = "1. " + compact, output = applyCoherentParagraphFallback(raw);
    expect(output.startsWith("1. ")).toBe(true);
    expect(output).toContain("\n\n   We");
    expectOnlyWhitespaceChanges(raw, output);
  });

  it("keeps text below the initial word floor unchanged", () => {
    const short = [19, 19, 20, 20]
      .map(count => ["We", ...Array<string>(count - 1).fill("detail")].join(" ") + ".").join(" ");
    expect(applyCoherentParagraphFallback(short)).toBe(short);
  });
});

describe("production finalizer paragraph floor", () => {
  const states = [
    { name: "off and skipped", mode: "off", behavior: "noop", status: "skipped" },
    { name: "shadowed", mode: "shadow", behavior: "noop", status: "shadowed" },
    { name: "applied without paragraphs", mode: "on", behavior: "noop", status: "applied" },
    { name: "rejected", mode: "on", behavior: "rejected", status: "rejected" },
    { name: "HTTP unavailable", mode: "on", behavior: "http-error", status: "failed" },
    { name: "timed out", mode: "on", behavior: "timeout", status: "failed" },
    { name: "health unavailable", mode: "on", behavior: "health-error", status: "failed" },
    { name: "applied with paragraphs", mode: "on", behavior: "paragraphs", status: "applied" },
  ] as const;
  for (const surface of ["dictation", "voice_ask"] as const) {
    for (const state of states) {
      it(`${surface} keeps paragraphs when polish is ${state.name}`, async () => {
        reply(state.behavior);
        const result = await finalizeTranscriptionResultForSurface(text, surface, { ...env(), QA_VOICE_STT_POLISH: state.mode });
        expect(result.text).toContain("\n\nAnyway");
        expectOnlyWhitespaceChanges(text, result.text);
        expect(result.polishStatus).toBe(state.status);
        if (state.mode === "off") expect(fetchMock!.mock.calls).toHaveLength(0);
        if (state.behavior === "paragraphs") expect(result.text).toBe(text.replace(". Anyway", ".\n\nAnyway"));
      });
    }
  }

  for (const policy of ["1", "0", ""]) {
    for (const mode of ["off", "on"]) {
      it(`keeps the final floor with coherent setting ${JSON.stringify(policy)} and polish ${mode}`, async () => {
        reply("noop");
        const result = await finalizeTranscriptionResultForSurface(text, "dictation", {
          ...env(), QA_VOICE_STT_POLISH: mode, VOICELAYER_STT_COHERENT_PARAGRAPHS: policy,
        });
        expect(result.text).toContain("\n\nAnyway");
        expectOnlyWhitespaceChanges(text, result.text);
      });
    }
  }

  for (const pauseSetting of ["0", "1"]) {
    it(`keeps the final paragraph floor with pause paragraphs ${pauseSetting}`, async () => {
      reply("noop");
      const result = await finalizeTranscriptionResultForSurface(text, "dictation", { ...env(), VOICELAYER_STT_PAUSE_PARAGRAPHS: pauseSetting });
      expect(result.text).toContain("\n\nAnyway");
      expectOnlyWhitespaceChanges(text, result.text);
    });
  }

  it("keeps usable acoustic boundaries ahead of the text fallback", async () => {
    const a = "First we describe the original problem and keep every single detail. ".repeat(5).trim();
    const b = "Next we explain the proposed solution and preserve all the spoken words. ".repeat(5).trim();
    const c = "Finally we check the outcome and report what the evidence actually proves. ".repeat(5).trim();
    const raw = `${a} ${b} ${c}`;
    reply("noop", raw);
    const result = await finalizeTranscriptionResultForSurface(raw, "dictation", env(), {
      segments: [{ text: a, startS: 0, endS: 20 }, { text: b, startS: 23, endS: 43 }, { text: c, startS: 43.5, endS: 64 }],
      pauses: [{ startS: 20.1, endS: 23 }, { startS: 43, endS: 43.5 }],
    });
    expect(result.text).toBe(`${a}\n\n${b} ${c}`);
    expectOnlyWhitespaceChanges(raw, result.text);
  });

  it("keeps paragraphs when polish is not called for a null surface", async () => {
    reply("noop");
    const result = await finalizeTranscriptionResultForSurface(text, null, env());
    expect(result.text).toContain("\n\nAnyway");
    expectOnlyWhitespaceChanges(text, result.text);
    expect(result.polishStatus).toBeUndefined();
    expect(fetchMock!.mock.calls).toHaveLength(0);
  });

  it("keeps an empty skipped final empty without a model request", async () => {
    reply("noop");
    const result = await finalizeTranscriptionResultForSurface("", "dictation", env());
    expect(result.text).toBe("");
    expect(result.polishStatus).toBe("skipped");
    expect(fetchMock!.mock.calls).toHaveLength(0);
  });

  it("falls back when the default acoustic boundary evidence is empty", async () => {
    reply("noop");
    const result = await finalizeTranscriptionResultForSurface(text, "dictation", env(), { segments: [], pauses: [] });
    expect(result.text).toContain("\n\nAnyway");
    expectOnlyWhitespaceChanges(text, result.text);
  });

  it("retains retractions, fragment multiplicity, identifiers and the tail", async () => {
    const raw = text + " I want the blue one no wait the green one. Preserve ~~blue~~ green, fu… and fu... and x…, café and café, /tmp/example.txt and --keep-tail exactly.";
    reply("noop", raw);
    const result = await finalizeTranscriptionResultForSurface(raw, "voice_ask", env());
    expect(result.text).toContain("\n\n");
    expectOnlyWhitespaceChanges(raw, result.text);
  });

  for (const raw of [text.replace(". Anyway", ".\n\nAnyway"), text + "\n1. Keep this spoken item.", "One short sentence."]) {
    it("preserves existing paragraphs, list lines and short text", async () => {
      reply("noop", raw);
      const result = await finalizeTranscriptionResultForSurface(raw, "dictation", env());
      expect(result.text).toBe(raw);
    });
  }
});

describe("literal code fallback", () => {
  const literals = [
    ["inline", "`" + text + "`"],
    ["backtick fence", "```text\n" + text + "\n```"],
    ["tilde fence", "~~~text\n" + text + "\n~~~"],
  ] as const;
  for (const [kind, raw] of literals) {
    it(`preserves ${kind} layout in the default paragraph helper`, () => {
      expect(applyCoherentParagraphFallback(raw)).toBe(raw);
    });
    for (const surface of ["dictation", "voice_ask"] as const) {
      for (const behavior of ["noop", "rejected", "http-error", "timeout", "health-error", "off", "shadow"]) {
        it(`${surface} preserves ${kind} layout when polish is ${behavior}`, async () => {
          reply(behavior, raw);
          const result = await finalizeTranscriptionResultForSurface(raw, surface, {
            ...env(), VOICELAYER_STT_PAUSE_PARAGRAPHS: "0",
            QA_VOICE_STT_POLISH: behavior === "off" || behavior === "shadow" ? behavior : "on",
          });
          expect(result.text).toBe(raw);
          expect(result.polishStatus).toBe(behavior === "off" ? "skipped" : behavior === "shadow" ? "shadowed"
            : behavior === "noop" ? "applied" : behavior === "rejected" ? "rejected" : "failed");
        });
      }
      it(`${surface} vetoes ${kind} before the explicit text stage`, async () => {
        const result = await finalizeTranscriptionResultForSurface(raw, surface, {
          ...env(), QA_VOICE_STT_POLISH: "off", VOICELAYER_STT_COHERENT_PARAGRAPHS: "1",
        });
        expect(result.text).toBe(raw);
      });
    }
  }

  it("vetoes code before usable acoustic paragraph boundaries", async () => {
    const a = "`" + "First we describe the original problem and keep every single detail. ".repeat(5).trim();
    const b = "Next we explain the proposed solution and preserve all the spoken words. ".repeat(5).trim() + "`";
    const raw = `${a} ${b}`;
    const result = await finalizeTranscriptionResultForSurface(raw, "dictation", { ...env(), QA_VOICE_STT_POLISH: "off" }, {
      segments: [{ text: a, startS: 0, endS: 20 }, { text: b, startS: 23, endS: 43 }],
      pauses: [{ startS: 20.1, endS: 23 }],
    });
    expect(result.text).toBe(raw);
  });
});
