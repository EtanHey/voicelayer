import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, readdirSync, rmSync, writeFileSync, readFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import {
  processingEnv,
  readProcessingSettings,
  setProcessingSetting,
} from "../processing-settings";
import { readPolishControlsStatus } from "../polish-controls-status";
import { getSTTPolishMode } from "../stt-polish";
import { outroGateEnabled } from "../stt-outro-gate";
import { isSmartWavChunkingEnabled } from "../stt";
import { smartBoundariesEnabled } from "../stt-sentence-boundaries";

const dir = join(TEST_TMP, "processing-settings");
let n = 0;
function fileEnv(content?: string): Record<string, string | undefined> {
  mkdirSync(dir, { recursive: true });
  const path = join(dir, `settings-${process.pid}-${n++}.json`);
  if (content !== undefined) writeFileSync(path, content);
  return { VOICELAYER_PROCESSING_SETTINGS_PATH: path };
}

afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe("processing settings (P1)", () => {
  test("no file keeps today's four defaults", () => {
    const env = processingEnv(fileEnv());
    expect(getSTTPolishMode(env)).toBe("on");
    expect(outroGateEnabled(env)).toBe(true);
    expect(isSmartWavChunkingEnabled(env)).toBe(false);
    expect(smartBoundariesEnabled(env)).toBe(false);
  });

  test("writes only the keys the user set, and reads them back", () => {
    const env = fileEnv();
    setProcessingSetting("outro_gate", false, env);
    setProcessingSetting("smart_chunks", true, env);
    const written = JSON.parse(readFileSync(env.VOICELAYER_PROCESSING_SETTINGS_PATH!, "utf8"));
    expect(Object.keys(written).sort()).toEqual(["outro_gate", "smart_chunks", "updated_at", "version"]);
    expect(readProcessingSettings(env)).toEqual({ outro_gate: false, smart_chunks: true });

    const effective = processingEnv(env);
    expect(outroGateEnabled(effective)).toBe(false);
    expect(isSmartWavChunkingEnabled(effective)).toBe(true);
    expect(getSTTPolishMode(effective)).toBe("on");
    expect(smartBoundariesEnabled(effective)).toBe(false);
  });

  test("polish is stored as on/off", () => {
    const env = fileEnv();
    setProcessingSetting("model_polish", false, env);
    expect(JSON.parse(readFileSync(env.VOICELAYER_PROCESSING_SETTINGS_PATH!, "utf8")).model_polish).toBe("off");
    expect(getSTTPolishMode(processingEnv(env))).toBe("off");
  });

  test("a corrupt file or a wrong-typed value falls back to the default", () => {
    expect(readProcessingSettings(fileEnv("{not json"))).toEqual({});
    const env = fileEnv(JSON.stringify({ version: 1, outro_gate: "no", smart_chunks: 1, smart_boundaries: true }));
    expect(readProcessingSettings(env)).toEqual({ smart_boundaries: true });
    expect(outroGateEnabled(processingEnv(env))).toBe(true);
  });

  test("an environment variable that is set wins over the file, even empty", () => {
    const env = fileEnv(JSON.stringify({ version: 1, outro_gate: false, smart_chunks: true, model_polish: "off" }));
    const effective = processingEnv({
      ...env,
      VOICELAYER_STT_OUTRO_GATE: "",
      VOICELAYER_STT_SMART_CHUNKS: "0",
      QA_VOICE_STT_POLISH: "shadow",
    });
    expect(outroGateEnabled(effective)).toBe(true);
    expect(isSmartWavChunkingEnabled(effective)).toBe(false);
    expect(getSTTPolishMode(effective)).toBe("shadow");
  });

  test("an unknown env value stays off even when the file says on", () => {
    const env = fileEnv(JSON.stringify({ version: 1, outro_gate: true }));
    expect(outroGateEnabled(processingEnv({ ...env, VOICELAYER_STT_OUTRO_GATE: "maybe" }))).toBe(false);
  });

  test("status reports settings as the source only for keys in the file", () => {
    const env = fileEnv(JSON.stringify({ version: 1, smart_boundaries: true }));
    expect(readPolishControlsStatus({ ...env, VOICELAYER_STT_OUTRO_GATE: "0" })).toEqual({
      model_polish: { source: "default", raw: null, effective: "on" },
      outro_gate: { source: "environment", raw: "0", effective: false },
      smart_chunks: { source: "default", raw: null, effective: false },
      smart_boundaries: { source: "settings", raw: null, effective: true },
    });
  });
});

describe("Polish off also stops the recording-start warm-up (#145 round 2)", () => {
  test("warmPolishEndpoint makes no request when Polish is off", async () => {
    const { warmPolishEndpoint } = await import("../stt-polish");
    const realFetch = globalThis.fetch;
    let requests = 0;
    globalThis.fetch = (async () => {
      requests++;
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch;
    try {
      const result = await warmPolishEndpoint(processingEnv({
        ...fileEnv(JSON.stringify({ version: 1, model_polish: "off" })),
        VOICELAYER_STT_POLISH_WARMUP: "1",
        QA_VOICE_STT_POLISH_ENDPOINT: "http://127.0.0.1:59999",
      }));
      expect(result.status).toBe("skipped");
      expect(requests).toBe(0);
    } finally {
      globalThis.fetch = realFetch;
    }
  });
});

describe("the settings file is replaced atomically (#145 round 2)", () => {
  test("a write leaves only the settings file behind", () => {
    const env = fileEnv();
    setProcessingSetting("outro_gate", false, env);
    setProcessingSetting("smart_chunks", true, env);
    const path = env.VOICELAYER_PROCESSING_SETTINGS_PATH!;
    const siblings = readdirSync(dir).filter((name) => name.startsWith(path.split("/").at(-1)!));
    expect(siblings).toEqual([path.split("/").at(-1)!]);
    expect(readProcessingSettings(env)).toEqual({ outro_gate: false, smart_chunks: true });
  });
});
