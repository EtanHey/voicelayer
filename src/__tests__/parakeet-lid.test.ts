import { describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "fs";
import { createHash } from "crypto";
import { testTmp } from "./setup/test-tmp";
import { languagePrefix, parseLanguageDetection, PARAKEET_LID_MAX_FRAMES } from "../parakeet-lid";
import { ParakeetBackend } from "../parakeet-backend";

const pcm = Buffer.alloc(32000, 7);
const bytes = languagePrefix({ bytes: pcm, frames: 16000, dataOffset: 0, inputSha256: "fixture" });
const inputSha256 = createHash("sha256").update(bytes).digest("hex");
const root = testTmp("parakeet-lid"); mkdirSync(root, { recursive: true });
const path = root + "/input.wav"; writeFileSync(path, bytes);
const native = { text: "Keep the actual selected engine text.", complete: true, input_frames: 16000, covered_frames: 16000,
  sample_rate: 16000, last_token_end_s: 1, inference_s: .1, language: null };
const fallback = { name: "whisper-fixture", isAvailable: async () => true, transcribe: async () => ({ text: "provider recovery", backend: "whisper-fixture", durationMs: 1 }) };
const env = () => ({ VOICELAYER_PARAKEET_LID_WARNING: "1" });

describe("optional LID is a warning, never an engine selector", () => {
  test("detect-only parser accepts one real-format result and withholds ambiguous/invalid estimates", () => {
    expect(parseLanguageDetection("whisper: auto-detected language: he (p = 0.940143)\n")).toEqual({ status: "COMPLETE", language: "he", probability: .940143 });
    for (const raw of ["", "auto-detected language: en (p = 2)", "auto-detected language: en (p = .9)\nauto-detected language: he (p = .8)"]) expect(parseLanguageDetection(raw).status).toBe("UNKNOWN");
  });
  test("at most 30 seconds of literal leading PCM; original input remains untouched", () => {
    const raw = Buffer.alloc(31 * 32000, 11), before = Buffer.from(raw);
    const prefix = languagePrefix({ bytes: raw, frames: 31 * 16000, dataOffset: 0, inputSha256: "fixture" });
    expect(prefix.length).toBe(44 + PARAKEET_LID_MAX_FRAMES * 2);
    expect(prefix.subarray(44)).toEqual(raw.subarray(0, 30 * 32000)); expect(raw).toEqual(before);
    expect(() => languagePrefix({ bytes: raw, frames: 1.5, dataOffset: 0, inputSha256: "fixture" })).toThrow();
  });
  test("high-confidence Hebrew cannot replace a complete selected-P response", async () => {
    let w = 0;
    const backend = new ParakeetBackend({ env, fallbackBackend: { ...fallback, transcribe: async () => { w++; return fallback.transcribe(); } },
      transcribe: async () => native, languageProbe: async () => ({ status: "COMPLETE", language: "he", probability: .94, inputSha256 }) });
    const result = await backend.transcribe(path);
    expect(result.text).toBe(native.text); expect(result.backend).toBe("parakeet-resident"); expect(w).toBe(0);
    expect(result.languageWarning).toBe("unsupported-language-advisory");
  });
  test("low confidence remains advisory, not an English gate", async () => {
    const backend = new ParakeetBackend({ env, fallbackBackend: fallback, transcribe: async () => native,
      languageProbe: async () => ({ status: "COMPLETE", language: "en", probability: .49, inputSha256 }) });
    expect((await backend.transcribe(path)).languageWarning).toBe("language-detection-low-confidence");
  });
  test("default-off makes no detector call", async () => {
    let calls = 0;
    const backend = new ParakeetBackend({ env: () => ({}), fallbackBackend: fallback, transcribe: async () => native,
      languageProbe: async () => { calls++; throw new Error("must not start"); } });
    expect((await backend.transcribe(path)).text).toBe(native.text); expect(calls).toBe(0);
  });
  test("advisory failure cannot replace a successful provider response", async () => {
    const backend = new ParakeetBackend({ env, fallbackBackend: fallback, transcribe: async () => native,
      languageProbe: async () => { throw new Error("LID unavailable"); } });
    const r = await backend.transcribe(path); expect(r.text).toBe(native.text); expect(r.languageEvidence?.status).toBe("UNKNOWN");
  });
  test("provider error waits for detector cleanup before unloading P or starting W", async () => {
    const calls: string[] = []; let finish!: () => void;
    const done = new Promise<void>(r => { finish = r; });
    const backend = new ParakeetBackend({ env, fallbackBackend: { ...fallback, transcribe: async () => { calls.push("W"); return fallback.transcribe(); } },
      transcribe: async () => { calls.push("P-error"); throw new Error("original provider error"); },
      unload: async () => { calls.push("unload"); }, languageProbe: async () => { calls.push("LID"); await done; calls.push("LID-cleanup"); return { status: "UNKNOWN", inputSha256 }; } });
    const pending = backend.transcribe(path); await new Promise(r => setTimeout(r, 10));
    expect(calls).not.toContain("unload"); expect(calls).not.toContain("W"); finish();
    expect((await pending).backend).toContain("fallback-provider-error");
    expect(calls.indexOf("LID-cleanup")).toBeLessThan(calls.indexOf("unload"));
  });
  test("wrong-audio language evidence is withheld", async () => {
    const backend = new ParakeetBackend({ env, fallbackBackend: fallback, transcribe: async () => native,
      languageProbe: async () => ({ status: "COMPLETE", language: "he", probability: .99, inputSha256: "wrong" }) });
    const r = await backend.transcribe(path); expect(r.languageEvidence?.status).toBe("UNKNOWN"); expect(r.languageWarning).toBe("auto-language-unverified");
  });
});
