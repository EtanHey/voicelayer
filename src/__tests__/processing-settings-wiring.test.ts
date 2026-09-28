import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { polishTranscriptionText } from "../stt-polish";
import { WhisperServerBackend } from "../stt";

// P1: a read site that still passes process.env ignores the Settings toggle
// silently: the "toggle that does nothing" bug. Every pipeline read of the four
// processing flags must go through processingEnv().
const SRC = join(import.meta.dir, "..");
const files = readdirSync(SRC).filter((name) => name.endsWith(".ts"));

const FORBIDDEN: Array<[RegExp, string]> = [
  [/\b(outroGateEnabled|smartBoundariesEnabled|isSmartWavChunkingEnabled|getSTTPolishMode)\(\s*(process\.env)?\s*\)/g,
    "a processing-flag parser called with process.env or no env"],
  [/\b(finalizeTranscriptionResultForSurface|buildBoundaryContext|finalizeTranscriptionTextForSurface)\([^;]*?process\.env/gs,
    "a finalize/boundary call handed process.env"],
  [/\bSTTFinalizeEnv = process\.env/g, "a finalize default of process.env"],
  [/input\.env \?\? process\.env/g, "polish falling back to process.env"],
];

// Polish server boot/recovery and the recording-start warm-up read the polish mode too.
const FILE_FORBIDDEN: Array<[string, RegExp, string]> = [
  ["stt-polish-server.ts", /const env = options\.env \?\? process\.env|STTPolishEnv = process\.env/g, "polish server env fallback"],
  ["input.ts", /warmPolishEndpointAtRecordingStart[\s\S]*?options\.env \?\? process\.env/g, "warm-up env fallback"],
];

describe("processing settings wiring (P1)", () => {
  test("no pipeline read site bypasses processingEnv()", () => {
    const offenders: string[] = [];
    for (const name of files) {
      const source = readFileSync(join(SRC, name), "utf8");
      for (const [pattern, what] of FORBIDDEN) {
        for (const match of source.matchAll(pattern)) {
          const line = source.slice(0, match.index).split("\n").length;
          offenders.push(`${name}:${line} ${what}: ${match[0].slice(0, 80)}`);
        }
      }
    }
    for (const [name, pattern, what] of FILE_FORBIDDEN) {
      const source = readFileSync(join(SRC, name), "utf8");
      for (const match of source.matchAll(pattern)) {
        offenders.push(`${name} ${what}: ${match[0].slice(-60)}`);
      }
    }
    expect(offenders).toEqual([]);
  });
});

describe("a settings file reaches the pipeline with no env set (P1)", () => {
  const dir = join(TEST_TMP, "processing-wiring");
  const saved = process.env.VOICELAYER_PROCESSING_SETTINGS_PATH;
  function useSettings(settings: Record<string, unknown>): void {
    mkdirSync(dir, { recursive: true });
    const path = join(dir, `settings-${process.pid}.json`);
    writeFileSync(path, JSON.stringify({ version: 1, ...settings }));
    process.env.VOICELAYER_PROCESSING_SETTINGS_PATH = path;
  }
  afterEach(() => {
    if (saved === undefined) delete process.env.VOICELAYER_PROCESSING_SETTINGS_PATH;
    else process.env.VOICELAYER_PROCESSING_SETTINGS_PATH = saved;
    rmSync(dir, { recursive: true, force: true });
  });

  test("Polish off in the file turns polish off", async () => {
    useSettings({ model_polish: "off" });
    const result = await polishTranscriptionText({ rawText: "hello there", cleanedText: "Hello there." });
    expect(result.mode).toBe("off");
  });

  test("the closing-phrase filter off in the file stops the chunked decode asking for segments", async () => {
    const segmentRequests: boolean[] = [];
    const wav = new Uint8Array(44 + 95 * 32_000);
    const view = new DataView(wav.buffer);
    const ascii = (at: number, text: string) => [...text].forEach((c, i) => { wav[at + i] = c.charCodeAt(0); });
    ascii(0, "RIFF"); view.setUint32(4, 36 + 95 * 32_000, true); ascii(8, "WAVE"); ascii(12, "fmt ");
    view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
    view.setUint32(24, 16_000, true); view.setUint32(28, 32_000, true); view.setUint16(32, 2, true);
    view.setUint16(34, 16, true); ascii(36, "data"); view.setUint32(40, 95 * 32_000, true);
    for (let i = 0; i < 95 * 16_000; i++) view.setInt16(44 + i * 2, Math.round(2000 * Math.sin(i / 14)), true);
    mkdirSync(dir, { recursive: true });
    const wavPath = join(dir, "long.wav");
    writeFileSync(wavPath, wav);
    const backend = new WhisperServerBackend({
      isServerAvailable: () => true,
      transcribeViaServer: async (_wav, options) => {
        segmentRequests.push(Boolean(options?.onSegments));
        return "same words every time";
      },
    });

    useSettings({ outro_gate: false, smart_boundaries: false });
    await backend.transcribe(wavPath);
    expect(segmentRequests.length).toBeGreaterThan(0);
    expect(segmentRequests.every((asked) => !asked)).toBe(true);
  });
});
