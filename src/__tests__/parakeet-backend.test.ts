import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, writeFileSync, readFileSync, statSync, existsSync } from "fs";
import { testTmp } from "./setup/test-tmp";
import { ParakeetBackend, parakeetLanguage, parakeetOutputRisk, parakeetWavInfo } from "../parakeet-backend";
import { getBackend, resetBackendCache, buildWhisperServerOptions, type STTBackend } from "../stt";
import { cleanupTranscriptionText } from "../stt-cleanup";
import { ParakeetServiceError, type ParakeetResponse } from "../parakeet-server";

function wav(seconds = 1): Uint8Array {
  const b = Buffer.alloc(44 + seconds * 32000);
  b.write("RIFF"); b.writeUInt32LE(b.length - 8, 4); b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(b.length - 44, 40);
  for (let i = 44; i < b.length; i += 2) b.writeInt16LE(1000, i);
  return b;
}
const response = (text = "Keep every word and the last tail.", seconds = 1): ParakeetResponse => ({
  text, complete: true, input_frames: seconds * 16000, covered_frames: seconds * 16000,
  sample_rate: 16000, last_token_end_s: seconds, inference_s: 0.1, language: null,
});

describe("opt-in resident Parakeet router", () => {
  const path = testTmp("parakeet", "input.wav");
  let oldBackend: string | undefined;
  beforeEach(() => { mkdirSync(testTmp("parakeet"), { recursive: true }); writeFileSync(path, wav()); oldBackend = process.env.QA_VOICE_STT_BACKEND; resetBackendCache(); });
  afterEach(() => { if (oldBackend === undefined) delete process.env.QA_VOICE_STT_BACKEND; else process.env.QA_VOICE_STT_BACKEND = oldBackend; resetBackendCache(); });
  function setup(result = response()) {
    const calls: string[] = [];
    const fallback: STTBackend = { name: "whisper-test", isAvailable: async () => true, transcribe: async p => { calls.push("W"); expect(readFileSync(p)).toEqual(readFileSync(path)); return { text: "Whisper kept the whole recording.", backend: "whisper-test", durationMs: 3 }; } };
    const backend = new ParakeetBackend({ fallbackBackend: fallback, transcribe: async p => { calls.push("P"); expect(readFileSync(p)).toEqual(readFileSync(path)); return result; }, unload: async () => { calls.push("unload"); }, env: () => ({ QA_VOICE_WHISPER_LANG: "en" }) });
    return { backend, calls, fallback };
  }
  test("backend choice is explicit and returns the selected P backend", async () => {
    process.env.QA_VOICE_STT_BACKEND = "parakeet";
    expect((await getBackend()).name).toBe("parakeet-resident");
  });
  test.each(["he", "hebrew", "ar", "ja", "", "xx"])("unknown/unsupported %s cannot override selected P", async language => {
    const { backend, calls } = setup();
    const r = await backend.transcribe(path, { language });
    expect(r.backend).toBe("parakeet-resident"); expect(calls).toEqual(["P"]);
  });
  test.each(["en", "english", "fr", "es-MX", "de", "uk"])("supported explicit language %s", async language => {
    const { backend, calls } = setup(); expect((await backend.transcribe(path, { language })).backend).toBe("parakeet-resident"); expect(calls).toEqual(["P"]);
  });
  test("detected Hebrew is advisory and does not override selected P", async () => {
    const { backend, calls } = setup(); const result = await backend.transcribe(path, { language: "en", detectedLanguage: "he" });
    expect(calls).toEqual(["P"]); expect(result.languageWarning).toBe("unsupported-language-advisory");
    expect(buildWhisperServerOptions({ language: "en", detectedLanguage: "he" })?.language).toBe("he");
  });
  test("default auto uses multilingual P without silently classifying English", () => { expect(parakeetLanguage({}, {})).toBe("auto"); });
  test("explicit Hebrew remains an advisory even when an English hint disagrees", () => {
    expect(parakeetLanguage({ detectedLanguage: "en" }, { QA_VOICE_WHISPER_LANG: "he" })).toBe("he");
    expect(parakeetLanguage({ language: "he", detectedLanguage: "fr" }, {})).toBe("he");
    expect(parakeetLanguage({ detectedLanguage: "fr" }, {})).toBe("fr");
  });
  test.each(["hebrew", "he-IL", "he", "ar", "en-US"])("Whisper fallback preserves caller language %s", language => {
    expect(buildWhisperServerOptions({ language })?.language).toBe(language.startsWith("he") ? "he" : language.split("-")[0]);
  });
  test("fallback remains available when P is absent", async () => {
    const { fallback } = setup(); const b = new ParakeetBackend({ fallbackBackend: fallback, isAvailable: () => false }); expect(await b.isAvailable()).toBe(true);
  });
  test("a continuity prompt cannot override the selected P backend", async () => {
    const { backend, calls } = setup(); expect((await backend.transcribe(path, { promptOverride: "previous phrase" })).backend).toBe("parakeet-resident"); expect(calls).toEqual(["P"]);
  });
  test.each(["", "   "])("empty returned text falls back on the original audio", async text => {
    const { backend, calls } = setup(response(text)); expect((await backend.transcribe(path)).backend).toContain("fallback-empty-response"); expect(calls).toEqual(["P", "unload", "W"]);
  });
  test("frame loss cannot pass as a completed response", async () => {
    const { backend } = setup({ ...response(), covered_frames: 15999 }); expect((await backend.transcribe(path)).backend).toContain("fallback-incomplete-response");
  });
  test("Hebrew script in a complete output does not silently switch engines", async () => {
    const { backend, calls } = setup(response("שלום עולם")); const result = await backend.transcribe(path);
    expect(result.backend).toBe("parakeet-resident"); expect(result.text).toBe("שלום עולם"); expect(calls).toEqual(["P"]);
  });
  test("truncated tails are retry signals, never trimmed", () => {
    const info = parakeetWavInfo(wav(20));
    expect(parakeetOutputRisk({ ...response("one two three four five six seven", 20), last_token_end_s: 3 }, info)).toBe("uncovered-tail");
    expect(parakeetOutputRisk(response("short", 20), info)).toBe("sparse-response");
    expect(parakeetWavInfo(wav(20)).frames).toBe(320000);
  });
  test("tail silence is not declared lost speech", () => {
    const b = wav(20); b.fill(0, 44 + 16000 * 2 * 10);
    expect(parakeetOutputRisk({ ...response("one two three four five six seven", 20), last_token_end_s: 10 }, parakeetWavInfo(b))).toBeNull();
  });
  test("a missing late section of a long file remains suspicious", () => {
    const info = parakeetWavInfo(wav(180));
    expect(parakeetOutputRisk({ ...response(Array(60).fill("word").join(" "), 180), last_token_end_s: 160 }, info)).toBe("uncovered-tail");
  });
  test("provider failure has one full-audio Whisper fallback", async () => {
    const { fallback, calls } = setup(); let vadCalls = 0;
    const b = new ParakeetBackend({ fallbackBackend: fallback, env: () => ({ QA_VOICE_WHISPER_LANG: "en" }), unload: async () => {},
      speechProbe: async () => { vadCalls++; throw new Error("P errors must not be relabelled VAD no-speech"); },
      transcribe: async () => { throw new Error("offline"); } });
    expect((await b.transcribe(path)).backend).toContain("fallback-provider-error->whisper-test");
    expect(calls).toEqual(["W"]); expect(vadCalls).toBe(0);
  });
  test("partial provider bytes and secondary cleanup failure survive a refused fallback", async () => {
    const attempts: unknown[] = []; let whisperCalls = 0;
    const error = new ParakeetServiceError("PARTIAL", { attempt: { text: "retain partial provider words", complete: false, covered_frames: 10 } });
    error.cleanupFailure = { name: "Error", message: "Streams unconfirmed" };
    const barrier = new Error("Owned cleanup barrier remains");
    const b = new ParakeetBackend({
      fallbackBackend: { name: "W-fixture", isAvailable: async () => true, transcribe: async () => { whisperCalls++; return { text: "unexpected", backend: "W-fixture", durationMs: 0 }; } },
      env: () => ({ QA_VOICE_WHISPER_LANG: "en" }), transcribe: async () => { throw error; },
      unload: async () => { throw barrier; }, retainFallback: a => { attempts.push(a); return "private-fixture-path"; },
    });
    await expect(b.transcribe(path)).rejects.toBe(barrier);
    expect(whisperCalls).toBe(0); expect(attempts.length).toBe(2);
    expect(attempts[0]).toMatchObject({ parakeetErrorStatus: "PARTIAL", parakeetCleanupFailure: error.cleanupFailure, parakeet: error.attempt, stage: "native-or-input-boundary" });
    expect(attempts[1]).toMatchObject({ parakeet: error.attempt, whisper: null, outcome: "UNRESOLVED_FALLBACK_FAILED" });
  });
  test("failed cleanup prevents a second model launch", async () => {
    let w = 0;
    const b = new ParakeetBackend({ fallbackBackend: { name: "w", isAvailable: async () => true, transcribe: async () => { w++; throw new Error("must not run"); } }, env: () => ({}), unload: async () => { throw new Error("owned stop unconfirmed"); } });
    await expect(b.transcribe(path)).rejects.toThrow("owned stop unconfirmed"); expect(w).toBe(0);
  });
  test("raw Parakeet text reaches existing dictionary cleanup without prompt injection", async () => {
    const raw = "voice layer uses c mux and sq lite";
    const { backend } = setup(response(raw)); const r = await backend.transcribe(path);
    expect(r.text).toBe(raw);
    const clean = cleanupTranscriptionText(r.text, { ...process.env, QA_VOICE_STT_VOCABULARY_DISABLED: "1" });
    expect(clean).toContain("VoiceLayer"); expect(clean).toContain("cmux"); expect(clean).toContain("SQLite");
  });
  test("personal dictionary aliases are applied by the same finalizer", async () => {
    const vocabulary = testTmp("parakeet", "synthetic-dictionary.json");
    writeFileSync(vocabulary, JSON.stringify({ entries: [{ canonical: "ExampleTool", variants: ["example tool"] }] }));
    const { backend } = setup(response("use example tool")); const raw = (await backend.transcribe(path)).text;
    expect(raw).toBe("use example tool");
    expect(cleanupTranscriptionText(raw, { ...process.env, QA_VOICE_STT_VOCABULARY_PATH: vocabulary, QA_VOICE_STT_VOCABULARY_DISABLED: "" })).toContain("ExampleTool");
  });
  test("fallback alternatives are private and missing providers remain null", async () => {
    const { backend } = setup(response("")); const result = await backend.transcribe(path);
    expect(result.fallbackEvidencePath).toBeDefined(); const p = result.fallbackEvidencePath!;
    const value = JSON.parse(readFileSync(p, "utf8")); expect(value.parakeet.text).toBe(""); expect(value.whisper.text).toBe("Whisper kept the whole recording.");
    expect(statSync(p).mode & 0o777).toBe(0o600);
  });
  test("zero PCM still retries Whisper but does not deliver invented words", async () => {
    const bytes = wav(); bytes.fill(0, 44); writeFileSync(path, bytes);
    const { backend, calls } = setup(response("")); const result = await backend.transcribe(path);
    expect(calls).toEqual(["P", "unload", "W"]); expect(result.text).toBe("");
    const evidence = JSON.parse(readFileSync(result.fallbackEvidencePath!, "utf8"));
    expect(evidence.whisper.text).toBe("Whisper kept the whole recording."); expect(evidence.deliveryText).toBe("");
  });
  test("one nonzero sample cannot be suppressed as zero PCM", async () => {
    const bytes = wav(); bytes.fill(0, 44); new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).setInt16(44, 1, true); writeFileSync(path, bytes);
    const { backend } = setup(response("quiet speech")); expect((await backend.transcribe(path)).text).toBe("quiet speech");
  });
  test("both providers use the same full snapshot even if the original is replaced", async () => {
    const bytes = wav(); let pPath = "", wPath = "";
    const b = new ParakeetBackend({
      env: () => ({ QA_VOICE_WHISPER_LANG: "en" }), unload: async () => {},
      transcribe: async snapshot => {
        pPath = snapshot; expect(snapshot).not.toBe(path); expect(readFileSync(snapshot)).toEqual(Buffer.from(bytes));
        expect(statSync(snapshot).mode & 0o777).toBe(0o400);
        const replacement = wav(); replacement.fill(0, 44); writeFileSync(path, replacement);
        return response("");
      },
      fallbackBackend: { name: "w", isAvailable: async () => true, transcribe: async snapshot => {
        wPath = snapshot; await Bun.sleep(15); expect(readFileSync(snapshot)).toEqual(Buffer.from(bytes));
        return { text: "speech retained", backend: "w", durationMs: 1 };
      } },
    });
    const result = await b.transcribe(path);
    expect(pPath).toBe(wPath); expect(existsSync(pPath)).toBe(false); expect(result.text).toBe("speech retained");
    const evidence = JSON.parse(readFileSync(result.fallbackEvidencePath!, "utf8"));
    expect(evidence.audioPath).toBe(path); expect(evidence.inputSha256).toHaveLength(64);
  });
  test("a zero snapshot cannot acquire speech from a later file rewrite", async () => {
    const zero = wav(); zero.fill(0, 44); writeFileSync(path, zero);
    const b = new ParakeetBackend({ env: () => ({ QA_VOICE_WHISPER_LANG: "en" }), unload: async () => {},
      transcribe: async () => { writeFileSync(path, wav()); return response(""); },
      fallbackBackend: { name: "w", isAvailable: async () => true, transcribe: async snapshot => {
        expect(readFileSync(snapshot)).toEqual(Buffer.from(zero)); return { text: "invented words", backend: "w", durationMs: 1 };
      } },
    });
    expect((await b.transcribe(path)).text).toBe("");
  });
  test("raw words, repeated words and fragments are not rewritten in the backend", async () => {
    const raw = "I I meant the the other fu… no, the full thing.";
    const { backend } = setup(response(raw)); expect((await backend.transcribe(path)).text).toBe(raw);
  });
  test("secondary diagnostic failure cannot replace the primary fallback error", async () => {
    const primary = new Error("original Whisper failure"); let calls = 0;
    const b = new ParakeetBackend({ env: () => ({}), unload: async () => {}, retainFallback: () => { throw new Error("disk full"); }, fallbackBackend: { name: "w", isAvailable: async () => true, transcribe: async () => { calls++; throw primary; } } });
    let received: unknown; try { await b.transcribe(path); } catch (error) { received = error; }
    expect(received).toBe(primary); expect(calls).toBe(1);
  });
  test("secondary diagnostic failure does not turn a returned fallback into an error", async () => {
    const { fallback } = setup();
    const b = new ParakeetBackend({ env: () => ({}), unload: async () => {}, retainFallback: () => { throw new Error("disk full"); }, fallbackBackend: fallback });
    expect((await b.transcribe(path)).text).toBe("Whisper kept the whole recording.");
  });
  test("reject partial/foreign sample geometry before invoking P", async () => {
    const { backend, calls } = setup(); const b = wav(); writeFileSync(path, b.subarray(0, b.length - 2));
    expect((await backend.transcribe(path)).backend).toContain("fallback-input-format"); expect(calls).toEqual(["unload", "W"]);
  });
});
