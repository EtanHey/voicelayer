import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTranscribeCli, TRANSCRIPT_FORMAT } from "../cli/transcribe";
import { finalizeTranscriptionTextForSurface } from "../input";
import { processingEnv } from "../processing-settings";
import type { STTBackend } from "../stt";
import { hasWavAudio, prepareSpeechAiff, speechFixtureAvailable } from "./setup/speech-fixture";
import { testTmp } from "./setup/test-tmp";

// Invented speech only; never a real recording or archive file.
const SPOKEN = "The harbor lights came on just after the ferry left.";
// What the fake decoder "hears": raw decoder text that dictation's finalize rewrites.
const RAW_DECODE = "um the harbor lights came on just after the ferry left";

const dir = testTmp("transcribe-cli");
mkdirSync(dir, { recursive: true });
const aiff = join(dir, "spoken.aiff");
const wav = join(dir, "spoken.wav");
const wideWav = join(dir, "spoken-44k.wav");

function prepareFixtures(): string | null {
  const failure = prepareSpeechAiff(aiff, SPOKEN);
  if (failure) return failure;
  for (const [out, rate] of [[wav, "16000"], [wideWav, "44100"]] as const) {
    const result = Bun.spawnSync(["sox", aiff, "-r", rate, "-c", "1", "-b", "16", out], { env: process.env });
    if (result.exitCode !== 0) return `sox exited ${result.exitCode}: ${result.stderr.toString().trim()}`;
  }
  return hasWavAudio(wav) ? null : "converted WAV has no audio";
}
const speechReady = speechFixtureAvailable("transcribe-cli", prepareFixtures());
const speechTest = speechReady ? test : test.skip;

function capture() {
  const out: string[] = [], err: string[] = [];
  let shutdowns = 0;
  return {
    out, err,
    get shutdowns() { return shutdowns; },
    deps: (backend: STTBackend) => ({
      stdout: (s: string) => { out.push(s); },
      stderr: (s: string) => { err.push(s); },
      getBackend: async () => backend,
      shutdown: async () => { shutdowns++; },
    }),
  };
}

function fakeBackend(text: string, seen: { path?: string; lang?: string }): STTBackend {
  return {
    name: "whisper.cpp",
    isAvailable: async () => true,
    transcribe: async (path: string) => {
      seen.path = path;
      seen.lang = process.env.QA_VOICE_WHISPER_LANG;
      return { text, backend: "whisper.cpp", durationMs: 1 };
    },
  };
}

async function runWrapper(args: string[], extraEnv: Record<string, string> = {}) {
  const child = Bun.spawn(["bash", "src/cli/voicelayer.sh", "transcribe", ...args], {
    env: { ...process.env, ...extraEnv }, stdout: "pipe", stderr: "pipe",
  });
  const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
  return { code, stdout, stderr };
}

describe("voicelayer transcribe", () => {
  test("the installed wrapper routes the command and documents the format", async () => {
    const help = await runWrapper(["--help"]);
    expect(help.code).toBe(0);
    expect(help.stdout).toContain("voicelayer transcribe <file.wav>");
    expect(help.stdout).toContain(TRANSCRIPT_FORMAT);
    expect(help.stdout).toContain("3 on an empty result");
  }, 30_000);

  test("a missing file exits nonzero and prints nothing on stdout", async () => {
    const missing = await runWrapper([join(dir, "no-such.wav"), "--json"]);
    expect(missing.code).toBe(1);
    expect(missing.stdout).toBe("");
    expect(missing.stderr).toContain("file not found");
  }, 30_000);

  speechTest("a backend failure through the real wrapper exits nonzero with no partial JSON", async () => {
    // The preload points the model at a missing file; the dictation selector refuses it.
    const failed = await runWrapper([wav, "--json"], { QA_VOICE_STT_BACKEND: "whisper", QA_VOICE_WISPR_KEY: "" });
    expect(failed.code).toBe(1);
    expect(failed.stdout).toBe("");
    expect(failed.stderr).toContain("Whisper model is missing");
  }, 30_000);

  speechTest("--json gives the dictation text of the file in voicelayer-transcript/1", async () => {
    const expected = await finalizeTranscriptionTextForSurface(RAW_DECODE, "dictation", processingEnv());
    // The proof needs a finalize that changes the decode, or raw passthrough would pass too.
    expect(expected.trim()).not.toBe(RAW_DECODE);
    const saved = process.env.QA_VOICE_WHISPER_LANG;
    const seen: { path?: string; lang?: string } = {};
    const io = capture();
    try {
      expect(await runTranscribeCli([wav, "--language", "he", "--json"], io.deps(fakeBackend(RAW_DECODE, seen)))).toBe(0);
    } finally {
      if (saved === undefined) delete process.env.QA_VOICE_WHISPER_LANG;
      else process.env.QA_VOICE_WHISPER_LANG = saved;
    }
    expect(seen).toEqual({ path: wav, lang: "hebrew" });
    expect(io.out.length).toBe(1);
    const parsed = JSON.parse(io.out[0]!);
    expect(parsed).toEqual({ format: TRANSCRIPT_FORMAT, text: expected, backend: "whisper.cpp", model: expect.any(String), language: "he" });
    expect(parsed.model.length > 0).toBe(true);
    expect(io.shutdowns).toBe(1);
  }, 30_000);

  speechTest("without --json only the text is printed", async () => {
    const expected = await finalizeTranscriptionTextForSurface(RAW_DECODE, "dictation", processingEnv());
    const io = capture();
    expect(await runTranscribeCli([wav], io.deps(fakeBackend(RAW_DECODE, {})))).toBe(0);
    expect(io.out).toEqual([`${expected}\n`]);
  }, 30_000);

  speechTest("an empty result exits 3, prints nothing on stdout and still stops owned sidecars", async () => {
    const io = capture();
    expect(await runTranscribeCli([wav, "--json"], io.deps(fakeBackend("  ", {})))).toBe(3);
    expect(io.out).toEqual([]);
    expect(io.err.join("")).toContain("empty result");
    expect(io.shutdowns).toBe(1);
  }, 30_000);

  speechTest("a result the gates emptied is an empty result (3), not a failure", async () => {
    const gated: STTBackend = {
      name: "whisper.cpp",
      isAvailable: async () => true,
      transcribe: async () => ({ text: "", backend: "whisper.cpp+outro", durationMs: 1,
        attemptEvidence: { status: "EMPTY_RESPONSE", gateRemoval: { gate: "closing-caption", removedSpans: 1, rawCharacters: 10 } } }),
    };
    const io = capture();
    expect(await runTranscribeCli([wav, "--json"], io.deps(gated))).toBe(3);
    expect(io.out).toEqual([]);
  }, 30_000);

  speechTest("a backend that throws is a real failure (1), distinct from empty", async () => {
    const broken: STTBackend = {
      name: "whisper.cpp",
      isAvailable: async () => true,
      transcribe: async () => { throw new Error("decoder crashed"); },
    };
    const io = capture();
    expect(await runTranscribeCli([wav, "--json"], io.deps(broken))).toBe(1);
    expect(io.out).toEqual([]);
    expect(io.err.join("")).toContain("decoder crashed");
    expect(io.shutdowns).toBe(1);
  }, 30_000);

  speechTest("audio the dictation path does not record is refused before any decode", async () => {
    const seen: { path?: string } = {};
    const io = capture();
    expect(await runTranscribeCli([wideWav, "--json"], io.deps(fakeBackend(RAW_DECODE, seen)))).toBe(1);
    expect(seen.path).toBeUndefined();
    expect(io.err.join("")).toContain("need 16 kHz mono 16-bit PCM");
  }, 30_000);

  test("bad arguments exit 2", async () => {
    for (const args of [[], ["a.wav", "b.wav"], ["a.wav", "--language", "fr"], ["a.wav", "--oops"]]) {
      const io = capture();
      expect(await runTranscribeCli(args, io.deps(fakeBackend(RAW_DECODE, {})))).toBe(2);
      expect(io.out).toEqual([]);
    }
  });
});

// Signal proof uses a synthetic PCM file and a slow injected decoder, no microphone.
for (const [signal, exitCode] of [["SIGTERM", 143], ["SIGINT", 130]] as const) {
  for (const outcome of ["pending", "late", "cleanup-timeout"]) {
  if (signal === "SIGINT" && outcome === "cleanup-timeout") continue;
  const settles = outcome === "late";
  test(`${signal} (${outcome}) mid-decode awaits owned-sidecar cleanup and discards output`, async () => {
    const root = join(dir, `${signal}-${outcome}`);
    mkdirSync(root, { recursive: true });
    const audio = join(root, "silence.wav");
    const pcm = Buffer.alloc(364);
    pcm.write("RIFF"); pcm.writeUInt32LE(356, 4); pcm.write("WAVEfmt ", 8);
    pcm.writeUInt32LE(16, 16); pcm.writeUInt16LE(1, 20); pcm.writeUInt16LE(1, 22);
    pcm.writeUInt32LE(16000, 24); pcm.writeUInt32LE(32000, 28);
    pcm.writeUInt16LE(2, 32); pcm.writeUInt16LE(16, 34); pcm.write("data", 36); pcm.writeUInt32LE(320, 40);
    writeFileSync(audio, pcm);
    const ready = join(root, "ready"), cleaned = join(root, "cleaned");
    const fixture = join(root, "signal-fixture.ts");
    writeFileSync(fixture, `
import { runTranscribeCli } from ${JSON.stringify(join(import.meta.dir, "../cli/transcribe.ts"))};
import { writeFileSync } from "node:fs";
const sidecar = Bun.spawn([process.execPath, "-e", "setInterval(() => {}, 1000)"], { env: process.env, stdout: "ignore", stderr: "ignore" });
process.exit(await runTranscribeCli([${JSON.stringify(audio)}], {
  getBackend: async () => ({ name: "slow", isAvailable: async () => true,
    transcribe: async () => new Promise(resolve => {
      if (${settles}) process.once(${JSON.stringify(signal)}, () => resolve({ text: "late result", backend: "slow", durationMs: 1 }));
      writeFileSync(${JSON.stringify(ready)}, String(sidecar.pid));
    }) }),
  shutdown: async () => {
    sidecar.kill("SIGTERM"); await sidecar.exited;
    await Bun.sleep(50); writeFileSync(${JSON.stringify(cleaned)}, "owned sidecar reaped");
    if (${outcome === "cleanup-timeout"}) await new Promise(() => {});
  },
}));
`);
    const child = Bun.spawn([process.execPath, fixture], { env: process.env, stdout: "pipe", stderr: "pipe" });
    let timedOut = false;
    const deadline = setTimeout(() => { timedOut = true; child.kill("SIGKILL"); }, 8000);
    try {
      const start = Date.now();
      while (!existsSync(ready) && Date.now() - start < 4000) await Bun.sleep(10);
      expect(existsSync(ready)).toBe(true);
      child.kill(signal);
      const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      expect(timedOut).toBe(false);
      expect(code).toBe(exitCode);
      expect(stdout).toBe("");
      if (outcome === "cleanup-timeout") expect(stderr).toContain("signal cleanup timed out; sidecar shutdown unconfirmed");
      expect(readFileSync(cleaned, "utf8")).toBe("owned sidecar reaped");
      const pid = Number(readFileSync(ready, "utf8"));
      expect(() => process.kill(pid, 0)).toThrow();
    } finally {
      clearTimeout(deadline);
      child.kill("SIGKILL"); await child.exited;
      if (existsSync(ready)) { try { process.kill(Number(readFileSync(ready, "utf8")), "SIGKILL"); } catch {} }
    }
  }, 12000);
}
}
