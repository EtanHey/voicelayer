import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { createHash } from "crypto";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";
import { ParakeetBackend, parakeetWavInfo } from "../parakeet-backend";
import type { ParakeetResponse } from "../parakeet-server";
import type { ParakeetSpeechEvidence } from "../parakeet-vad";
import { VAD_CHUNK_SAMPLES } from "../vad-constants";
import { WhisperCppBackend, type STTBackend } from "../stt";
import { stripHallucinatedCaption } from "../stt-caption-gate";

// File-only synthetic PCM. Tones represent acoustic energy; VAD outputs below
// simulate Silero classifications. No playback, microphone or real decoder.
function wav(noisyTail = false, tailPeak = 0): Buffer {
  const b = Buffer.alloc(44 + 79 * 32000);
  b.write("RIFF"); b.writeUInt32LE(b.length - 8, 4); b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(b.length - 44, 40);
  for (let frame = 0; frame < 79 * 16000; frame++) {
    const s = frame / 16000;
    const peak = s < 26 ? 6000 : s >= 70 && s < 72 ? tailPeak : noisyTail ? 900 : 0;
    b.writeInt16LE(Math.round(peak * Math.sin(frame * 2 * Math.PI * 220 / 16000)), 44 + frame * 2);
  }
  return b;
}
const nativeText = "Keep every raw word and the unfinished fu… no, the full thought from Codex Sol.";
const native: ParakeetResponse = { text: nativeText, complete: true, input_frames: 79 * 16000,
  covered_frames: 79 * 16000, sample_rate: 16000, last_token_end_s: 26, inference_s: 0.1, language: null };
const root = testTmp("lane-k-tail"), path = join(root, "audio.wav");
const keys = ["VOICELAYER_STT_OUTRO_GATE", "QA_VOICE_WHISPER_LANG", "LANE_K_JSON", "LANE_K_ARGS"] as const;
let saved: (string | undefined)[];
beforeEach(() => {
  mkdirSync(root, { recursive: true }); writeFileSync(path, wav());
  saved = keys.map(key => process.env[key]);
  process.env.VOICELAYER_STT_OUTRO_GATE = "1"; process.env.QA_VOICE_WHISPER_LANG = "english";
});
afterEach(() => keys.forEach((key, i) => { if (saved[i] === undefined) delete process.env[key]; else process.env[key] = saved[i]; }));

function evidence(snapshot: string, tailSpeech: boolean): ParakeetSpeechEvidence {
  const bytes = readFileSync(snapshot), info = parakeetWavInfo(bytes);
  const probabilities = Array.from({ length: Math.ceil(info.frames / VAD_CHUNK_SAMPLES) }, (_, i) => {
    const seconds = i * VAD_CHUNK_SAMPLES / info.sampleRate;
    return seconds < 26 || tailSpeech && seconds >= 70 && seconds < 72 ? 0.9 : 0.01;
  });
  return { status: "COMPLETE", threshold: 0.3, inputSha256: createHash("sha256").update(bytes).digest("hex"),
    frames: info.frames, analyzedFrames: info.frames, probabilities, maxProbability: 0.9,
    speechFrames: probabilities.filter(p => p >= 0.3).length * VAD_CHUNK_SAMPLES };
}
function router(fallbackBackend: STTBackend, speechProbe: (snapshot: string) => Promise<ParakeetSpeechEvidence>, result = native) {
  return new ParakeetBackend({ fallbackBackend, speechProbe, transcribe: async () => result,
    unload: async () => {}, retainFallback: () => "fixture-receipt", env: () => ({ QA_VOICE_WHISPER_LANG: "en" }) });
}
function fakeCli(tail = "Thank you.", freshSpeech = false, outroSpeech: boolean | "unknown" = false) {
  const binary = join(root, "whisper-cli"), json = join(root, "response.json"), argsPath = join(root, "args.json");
  process.env.LANE_K_JSON = json; process.env.LANE_K_ARGS = argsPath;
  writeFileSync(json, JSON.stringify({ transcription: [
    { text: nativeText, offsets: { from: 0, to: 26000 } },
    { text: tail, offsets: { from: 70000, to: 72000 } },
  ] }));
  writeFileSync(binary, `#!${process.execPath}\nimport { readFileSync, writeFileSync } from "node:fs";
const args = process.argv.slice(2); writeFileSync(process.env.LANE_K_ARGS, JSON.stringify(args));
const prefix = args[args.indexOf("-of") + 1];
if (args.includes("-oj")) writeFileSync(prefix + ".json", readFileSync(process.env.LANE_K_JSON));
console.log("[00:00:00.000 --> 00:00:26.000] stdout is not the JSON text");\n`);
  chmodSync(binary, 0o700);
  let captionCalls = 0;
  const backend = new WhisperCppBackend({ noVocabularyPrompt: true, speechProbe: async p => {
    const e = evidence(p, false);
    e.status = outroSpeech === "unknown" ? "UNKNOWN" : "COMPLETE";
    e.probabilities = e.probabilities!.map(() => outroSpeech === true ? 0.9 : 0.01);
    e.maxProbability = outroSpeech === true ? 0.9 : 0.01; e.speechFrames = outroSpeech === true ? e.frames : 0;
    return e;
  }, captionGate: async (text, bytes, options) => {
    captionCalls++;
    const quiet = Array<number>(Math.ceil(79 * 16000 / VAD_CHUNK_SAMPLES)).fill(0.01);
    return stripHallucinatedCaption(text, bytes, { ...options, speechProbabilities: quiet,
      freshSpeechProbabilities: quiet.map((p, i) => freshSpeech && i * 0.032 >= 70 ? 0.9 : p) });
  } });
  Object.defineProperty(backend, "binaryPath", { value: binary });
  Object.defineProperty(backend, "modelPath", { value: join(root, "fixture.bin") });
  return { backend, json, argsPath, captionCalls: () => captionCalls };
}

describe("Lane K: Silero tail evidence and timestamped CLI fallback", () => {
  test("50 seconds of above-512 non-speech noise keeps Parakeet, ZERO Whisper calls", async () => {
    writeFileSync(path, wav(true));
    expect(parakeetWavInfo(readFileSync(path)).lastActiveSeconds).toBeGreaterThan(78);
    let whisperCalls = 0, vadCalls = 0;
    const fallback: STTBackend = { name: "fake", isAvailable: async () => true, transcribe: async () => {
      whisperCalls++; return { text: "invented Thank you.", backend: "fake", durationMs: 0 };
    } };
    const result = await router(fallback, async p => { vadCalls++; return evidence(p, false); }).transcribe(path);
    expect(result.text).toBe(nativeText); expect(result.backend).toBe("parakeet-resident");
    expect(whisperCalls).toBe(0); expect(vadCalls).toBe(1);
  });
  test.each(["unavailable", "throws", "wrong-hash", "partial", "invalid-probability"])("%s Silero keeps Parakeet without energy fallback", async mode => {
    writeFileSync(path, wav(true)); let whisperCalls = 0;
    const result = await router({ name: "fake", isAvailable: async () => true, transcribe: async () => {
      whisperCalls++; throw new Error("must not run");
    } }, async p => {
      if (mode === "throws") throw new Error("Silero unavailable");
      const e = evidence(p, true);
      if (mode === "unavailable") e.status = "UNKNOWN";
      if (mode === "wrong-hash") e.inputSha256 = "wrong";
      if (mode === "partial") e.analyzedFrames = 512;
      if (mode === "invalid-probability") e.probabilities![100] = NaN;
      return e;
    }).transcribe(path);
    expect(result.text).toBe(nativeText); expect(whisperCalls).toBe(0);
  });
  test("Silero-detected quiet tail speech still requests full-audio fallback", async () => {
    writeFileSync(path, wav(false, 30)); let calls = 0;
    const result = await router({ name: "fake", isAvailable: async () => true, transcribe: async p => {
      calls++; expect(readFileSync(p)).toEqual(readFileSync(path));
      return { text: "All words including quiet tail speech.", backend: "fake", durationMs: 0 };
    } }, async p => evidence(p, true)).transcribe(path);
    expect(calls).toBe(1); expect(result.backend).toContain("fallback-uncovered-tail");
    expect(result.text).toBe("All words including quiet tail speech.");
  });
  test("CLI fallback removes an invented Thank you over silence using JSON segments", async () => {
    const cli = fakeCli();
    const result = await router(cli.backend, async p => evidence(p, true)).transcribe(path);
    expect(result.text).toBe(nativeText); expect(result.backend).toContain("fallback-uncovered-tail->whisper.cpp+outro");
    const args: string[] = JSON.parse(readFileSync(cli.argsPath, "utf8"));
    expect(args).toContain("-oj"); expect(args).not.toContain("--no-timestamps");
    expect(existsSync(args[args.indexOf("-of") + 1]! + ".json")).toBe(false);
    expect(cli.captionCalls()).toBe(1);
  });
  test.each([6000, 30])("a genuinely spoken Thank you survives at uniform recording peak %i", async peak => {
    const bytes = wav(false, peak);
    if (peak === 30) for (let i = 44; i < 44 + 26 * 32000; i += 2) bytes.writeInt16LE(Math.round(bytes.readInt16LE(i) / 200), i);
    writeFileSync(path, bytes);
    const result = await router(fakeCli("Thank you.", false, true).backend, async p => evidence(p, true)).transcribe(path);
    expect(result.text).toBe(nativeText + " Thank you."); expect(result.backend).not.toContain("+outro");
  });
  test.each([true, "unknown"] as const)("quiet closer after loud speech is kept when fresh Silero evidence is %s", async speech => {
    writeFileSync(path, wav(false, 30));
    const result = await router(fakeCli("Thank you.", false, speech).backend, async p => evidence(p, true)).transcribe(path);
    expect(result.text).toBe(nativeText + " Thank you.");
  });
  test.each([false, true])("caption gate runs with both simulated Silero states; fresh speech=%s", async freshSpeech => {
    const cli = fakeCli("Subtitles by Example", freshSpeech);
    const result = await router(cli.backend, async p => evidence(p, true)).transcribe(path);
    expect(cli.captionCalls()).toBe(1);
    expect(result.text).toBe(nativeText + (freshSpeech ? " Subtitles by Example" : ""));
    expect(result.backend.includes("+caption")).toBe(!freshSpeech);
  });
  test("malformed or missing segment offsets cannot silently bypass the gate", async () => {
    const cli = fakeCli(); writeFileSync(cli.json, JSON.stringify({ transcription: [{ text: "Thank you." }] }));
    await expect(cli.backend.transcribe(path)).rejects.toThrow();
    const args: string[] = JSON.parse(readFileSync(cli.argsPath, "utf8"));
    expect(existsSync(args[args.indexOf("-of") + 1]! + ".json")).toBe(false);
  });
  test("an acoustically emptied fallback is qualified as gated empty, not provider failure", async () => {
    const cli = fakeCli();
    writeFileSync(cli.json, JSON.stringify({ transcription: [{ text: "Thank you.", offsets: { from: 70000, to: 72000 } }] }));
    const result = await router(cli.backend, async p => evidence(p, true)).transcribe(path);
    expect(result.text).toBe(""); expect(result.outcome).toBe("ACOUSTIC_GATE_EMPTY");
    expect(result.attemptEvidence?.gateRemoval?.gate).toBe("closing-caption");
  });
});
