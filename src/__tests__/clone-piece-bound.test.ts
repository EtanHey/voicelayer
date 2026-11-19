/**
 * T28: a cloned voice must never be asked for one long piece. The Qwen3 clone tends to stop at about its reference
 * clip's length (10 s), often mid-word (NarrationLayer #153: 4-9 of 12 takes of 35-39-word sentences stopped there;
 * 0 of 12 after splitting at 24 words). Every piece that reaches the clone engine is at most 24 words, and the pieces
 * carry every word of the request, in order. Sentences here are synthetic; no voice profile or reference is used.
 */
import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { readFileSync, writeFileSync } from "fs";
import "../tts";
import * as engines from "../narration/engines";
import { narrationSource } from "../narration/source";
import * as qwen from "../tts/qwen3";
import { TEST_TMP } from "./setup/test-tmp";

const BOUND = 24;
const words = (text: string) => text.split(/\s+/).filter(Boolean);
/** 40 words, one sentence, a single comma after word 19. */
const FORTY = "The build kept running for most of the afternoon while three reviewers waited on the long gate to finish, " +
  "and then the last check failed on a socket path that was simply far too deep for macOS to accept here.";
/** 40 words, no punctuation at all. */
const BARE = Array.from({ length: 40 }, (_, i) => `word${i}`).join(" ");

type Part = { file: string } | { silenceMs: number };

function stubSource(cloneOk = true) {
  const cloned: string[] = [], edged: string[] = [], assembled: Array<{ parts: Part[]; outFile: string }> = [], disposed: string[] = [];
  const source = engines.createEngineNarrationSource({
    async edge(text, _voice, _rate, outFile) { edged.push(text); return { audioFile: outFile, durationMs: 1, wordBoundaries: [] }; },
    async clone(text) { cloned.push(text); return cloneOk ? new TextEncoder().encode(`audio:${text}`) : null; },
    async assemble(parts: Part[], outFile: string) {
      assembled.push({ parts, outFile });
      writeFileSync(outFile, parts.map(part => "file" in part ? readFileSync(part.file, "utf8") : `[${part.silenceMs}]`).join("|"));
    },
    dispose(file: string) { disposed.push(file); },
  } as engines.EngineNarrationDeps);
  return { source, cloned, edged, assembled, disposed };
}

describe("T28: cloned pieces stay under the reference-length wall", () => {
  it("a 40-word sentence reaches the clone engine as pieces of at most 24 words, every word present in order", async () => {
    expect(words(FORTY)).toHaveLength(40);
    for (const text of [FORTY, BARE]) {
      const stub = stubSource();
      const outFile = `${TEST_TMP}/t28-forty.mp3`;
      const audio = await stub.source.synthesize({ text, engine: "clone", voice: "fixture", rate: "+0%", outFile });
      expect(stub.cloned.length).toBeGreaterThan(1);
      for (const piece of stub.cloned) expect(words(piece).length).toBeLessThanOrEqual(BOUND);
      expect(stub.cloned.flatMap(words)).toEqual(words(text));
      // One file for the caller, assembled from the pieces in order with no added silence.
      expect(audio).toMatchObject({ audioFile: outFile, engine: "qwen3-tts", wordBoundaries: [] });
      expect(stub.assembled).toHaveLength(1);
      expect(stub.assembled[0].parts.every(part => "file" in part)).toBe(true);
      expect(readFileSync(outFile, "utf8")).toBe(stub.cloned.map(piece => `audio:${piece}`).join("|"));
      // The piece files are temporary and are all removed.
      expect(stub.disposed.sort()).toEqual(stub.assembled[0].parts.map(part => (part as { file: string }).file).sort());
    }
  });

  it("splits at the clause break nearest the middle when there is one", async () => {
    const stub = stubSource();
    await stub.source.synthesize({ text: FORTY, engine: "clone", voice: "fixture", rate: "+0%", outFile: `${TEST_TMP}/t28-comma.mp3` });
    expect(stub.cloned).toHaveLength(2);
    expect(stub.cloned[0].endsWith("finish,")).toBe(true);
    expect(stub.cloned[1].startsWith("and then")).toBe(true);
  });

  it("splits a piece with no punctuation at its middle word", async () => {
    const stub = stubSource();
    await stub.source.synthesize({ text: BARE, engine: "clone", voice: "fixture", rate: "+0%", outFile: `${TEST_TMP}/t28-bare.mp3` });
    expect(stub.cloned.map(piece => words(piece).length)).toEqual([20, 20]);
  });

  it("a piece within the bound is one request, unchanged; edge voices are never split", async () => {
    const short = words(FORTY).slice(0, BOUND).join(" ");
    const stub = stubSource();
    await stub.source.synthesize({ text: short, engine: "clone", voice: "fixture", rate: "+0%", outFile: `${TEST_TMP}/t28-short.mp3` });
    await stub.source.synthesize({ text: FORTY, engine: "edge", voice: "en-US-AndrewNeural", rate: "+0%", outFile: `${TEST_TMP}/t28-edge.mp3` });
    expect(stub.cloned).toEqual([short]);
    expect(stub.edged).toEqual([FORTY]);
    expect(stub.assembled).toHaveLength(0);
  });

  it("an unavailable clone stays null so the caller keeps its edge fallback", async () => {
    const stub = stubSource(false);
    expect(await stub.source.synthesize({ text: FORTY, engine: "clone", voice: "missing", rate: "+0%", outFile: `${TEST_TMP}/t28-null.mp3` })).toBeNull();
    expect(stub.assembled).toHaveLength(0);
  });

  it("if the pieces cannot be assembled the request is sent whole, so no word is lost; an abort still aborts", async () => {
    const cloned: string[] = [];
    const deps = {
      async edge(): Promise<never> { throw new Error("unused"); },
      async clone(text: string) { cloned.push(text); return new TextEncoder().encode("audio"); },
      async assemble(): Promise<void> { throw new Error("ffmpeg unavailable"); },
      dispose() {},
    };
    const logged = spyOn(console, "error").mockImplementation(() => {});
    try {
      const audio = await engines.createEngineNarrationSource(deps).synthesize(
        { text: FORTY, engine: "clone", voice: "fixture", rate: "+0%", outFile: `${TEST_TMP}/t28-noasm.mp3` });
      expect(audio?.audioFile).toBe(`${TEST_TMP}/t28-noasm.mp3`);
      expect(cloned.at(-1)).toBe(FORTY);
      expect(cloned.slice(0, -1).flatMap(words)).toEqual(words(FORTY));
      const controller = new AbortController(); controller.abort();
      await expect(engines.createEngineNarrationSource(deps).synthesize(
        { text: FORTY, engine: "clone", voice: "fixture", rate: "+0%", outFile: `${TEST_TMP}/t28-abort.mp3`, signal: controller.signal }))
        .rejects.toThrow("ffmpeg unavailable");
    } finally { logged.mockRestore(); }
  });

  it("a 70-word structured segment (the longest clone path measured) splits down to the bound, words in order", async () => {
    const long = `${FORTY} ${words(BARE).slice(0, 30).join(" ")}`;
    const stub = stubSource();
    await stub.source.synthesize({ text: long, engine: "clone", voice: "fixture", rate: "+0%", outFile: `${TEST_TMP}/t28-seventy.mp3` });
    for (const piece of stub.cloned) expect(words(piece).length).toBeLessThanOrEqual(BOUND);
    expect(stub.cloned.flatMap(words)).toEqual(words(long));
  });
});

describe("T28: the daemon's real narration source", () => {
  let spawned: string[][];
  let restore: Array<() => void>;
  beforeEach(() => {
    spawned = [];
    const clone = spyOn(qwen, "synthesizeCloned").mockImplementation(async text => Buffer.from(`audio:${text}`));
    const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
      spawned.push(argv);
      if (argv.includes("-filter_complex")) writeFileSync(argv.at(-1)!, "assembled");
      return { pid: 4242, exited: Promise.resolve(0), exitCode: 0, kill() {}, stdout: new Blob([""]).stream(), stderr: new Blob([""]).stream() };
    }) as any);
    restore = [() => clone.mockRestore(), () => spawn.mockRestore()];
  });
  afterEach(() => { for (const undo of restore) undo(); });

  it("sends a 40-word cloned request to Qwen3 as bounded pieces and assembles them into the requested file", async () => {
    const outFile = `${TEST_TMP}/t28-daemon.mp3`;
    const audio = await narrationSource().synthesize({ text: FORTY, engine: "clone", voice: "fixture", rate: "+0%", outFile });
    const pieces = (qwen.synthesizeCloned as any).mock.calls.map((call: unknown[]) => call[0] as string);
    expect(pieces.length).toBeGreaterThan(1);
    for (const piece of pieces) expect(words(piece).length).toBeLessThanOrEqual(BOUND);
    expect(pieces.flatMap(words)).toEqual(words(FORTY));
    expect(audio?.audioFile).toBe(outFile);
    const assembly = spawned.filter(argv => argv.includes("-filter_complex"));
    expect(assembly).toHaveLength(1);
    expect(assembly[0].at(-1)).toBe(outFile);
    expect(assembly[0].join(" ")).not.toContain("anullsrc");
  });
});
