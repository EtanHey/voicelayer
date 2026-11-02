import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";
import { CJK_HALLUCINATION_PHRASES, findOutroCandidates, stripHallucinatedOutro } from "../stt-outro-gate";
import { stripHallucinatedCaption } from "../stt-caption-gate";
import { WhisperCppBackend, WhisperServerBackend } from "../stt";

/** File-only PCM: optional 220 Hz tone stands for energy, never played. */
function wav(toneStart = Infinity, peak = 6000): Uint8Array {
  const b = Buffer.alloc(44 + 3 * 32000);
  b.write("RIFF"); b.writeUInt32LE(b.length - 8, 4); b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(b.length - 44, 40);
  for (let frame = 0; frame < 48000; frame++) if (frame / 16000 >= toneStart) {
    b.writeInt16LE(Math.round(peak * Math.sin(frame * 2 * Math.PI * 220 / 16000)), 44 + frame * 2);
  }
  return b;
}

describe("CJK hallucination candidates retain acoustic safety", () => {
  for (const phrase of CJK_HALLUCINATION_PHRASES) {
    test(`whole silent result: ${phrase}`, () => {
      for (const ending of ["", ".", "。"])
        expect(stripHallucinatedOutro(phrase + ending, wav()).text).toBe("");
    });
    test(`spoken words survive at normal and low gain: ${phrase}`, () => {
      for (const peak of [6000, 30]) {
        const segments = [{ text: phrase, startS: 0.5, endS: 2.8 }];
        expect(stripHallucinatedOutro(phrase, wav(0.5, peak), { segments, segmentsText: phrase }).text).toBe(phrase);
      }
    });
    test(`caption boundary uses both VAD and energy: ${phrase}`, async () => {
      const text = `Ship it. ${phrase}`;
      const segments = [{ text: "Ship it.", startS: 0, endS: 1 }, { text: phrase, startS: 1.5, endS: 2.8 }];
      const quiet = Array<number>(93).fill(0.01), speech = quiet.map((p, i) => i > 46 ? 0.95 : p);
      const options = { segments, segmentsText: text, speechProbabilities: quiet };
      expect((await stripHallucinatedCaption(text, wav(), options)).text).toBe("Ship it.");
      expect((await stripHallucinatedCaption(text, wav(), { ...options, freshSpeechProbabilities: speech })).text).toBe(text);
      expect((await stripHallucinatedCaption(text, wav(1.5, 30), options)).text).toBe(text);
      expect((await stripHallucinatedCaption(text, wav(0, 30), options)).text).toBe(text);
    });
  }
  test("unknown all-CJK output is a candidate only under a fixed non-CJK language", () => {
    const text = "これは別の文章です。";
    for (const explicitLanguage of ["en", "he"] as const) {
      expect(stripHallucinatedOutro(text, wav(), { explicitLanguage }).text).toBe("");
      expect(stripHallucinatedOutro(text, wav(0.5, 30), { explicitLanguage,
        segments: [{ text, startS: 0.5, endS: 2.8 }], segmentsText: text }).text).toBe(text);
    }
    expect(stripHallucinatedOutro(text, wav()).text).toBe(text);
    for (const mixed of ["Ship it. 字幕", "שלום 字幕", "ありがとう…", "ありがとう?", "ありがとう？"]) {
      expect(stripHallucinatedOutro(mixed, wav(), { explicitLanguage: "en" }).text).toBe(mixed);
    }
  });
  test("CJK punctuation splits sentences without allowing fragments or questions", () => {
    expect(findOutroCandidates("ご視聴ありがとうございました。谢谢观看。")).toHaveLength(2);
    for (const ending of ["…", "...", "?", "？", "!", "！"]) {
      expect(findOutroCandidates(`ご視聴ありがとうございました${ending}`)).toEqual([]);
    }
  });
  test("mismatch never removes a multi-sentence paragraph or more than 20 CJK characters", () => {
    for (const text of ["これは最初の文章です。これは次の文章です。", "これは最初です.これは次です.", "あ".repeat(21) + "。", "短い未完の語"]) {
      expect(stripHallucinatedOutro(text, wav(), { explicitLanguage: "en" }).text).toBe(text);
    }
    expect(stripHallucinatedOutro("あ".repeat(20) + "。", wav(), { explicitLanguage: "en" }).text).toBe("");
  });
  test("wrong-language candidate retains stale or missing segment evidence on non-flat audio", () => {
    const text = "これは別の文章です。", audio = wav(0, 30);
    expect(stripHallucinatedOutro(text, audio, { explicitLanguage: "en" }).text).toBe(text);
    expect(stripHallucinatedOutro(text, audio, { explicitLanguage: "en", segmentsText: "different",
      segments: [{ text, startS: 0.5, endS: 2.8 }] }).text).toBe(text);
  });
  test("server backend passes configured language and gates a silent CJK response before returning it", async () => {
    const root = testTmp("cjk-backend"), path = join(root, "silence.wav");
    const savedLanguage = process.env.QA_VOICE_WHISPER_LANG, savedGate = process.env.VOICELAYER_STT_OUTRO_GATE;
    mkdirSync(root, { recursive: true }); writeFileSync(path, wav());
    try {
      process.env.VOICELAYER_STT_OUTRO_GATE = "1";
      for (const [setting, language] of [["english", "en"], ["hebrew", "he"]]) {
        process.env.QA_VOICE_WHISPER_LANG = setting;
        let requested: string | undefined;
        const backend = new WhisperServerBackend({ isServerAvailable: () => true,
          transcribeViaServer: async (_, options) => { requested = options?.language; return "これは別の文章です。"; } });
        const result = await backend.transcribe(path);
        expect(requested).toBe(language); expect(result.text).toBe(""); expect(result.backend).toContain("+outro");
      }
      process.env.QA_VOICE_WHISPER_LANG = "auto";
      const backend = new WhisperServerBackend({ isServerAvailable: () => true,
        transcribeViaServer: async (_, options) => { expect(options?.language).toBe("he"); return "これは別の文章です。"; } });
      expect((await backend.transcribe(path, { language: "en", detectedLanguage: "he" })).text).toBe("これは別の文章です。");
    } finally {
      if (savedLanguage === undefined) delete process.env.QA_VOICE_WHISPER_LANG; else process.env.QA_VOICE_WHISPER_LANG = savedLanguage;
      if (savedGate === undefined) delete process.env.VOICELAYER_STT_OUTRO_GATE; else process.env.VOICELAYER_STT_OUTRO_GATE = savedGate;
      rmSync(root, { recursive: true, force: true });
    }
  });
  test("CLI fallback passes -l and retains spoken CJK while gating dead-device silence", async () => {
    const root = testTmp("cjk-cli"), path = join(root, "input.wav"), binary = join(root, "whisper-cli");
    const argsPath = join(root, "args.txt");
    const keys = ["QA_VOICE_WHISPER_LANG", "VOICELAYER_STT_OUTRO_GATE", "LANE_D_CLI_ARGS_PATH"] as const;
    const saved = keys.map(key => process.env[key]);
    mkdirSync(root, { recursive: true });
    writeFileSync(binary, '#!/bin/sh\nprintf "%s\\n" "$@" > "$LANE_D_CLI_ARGS_PATH"\nprintf "%s\\n" "これは別の文章です。"\n'); chmodSync(binary, 0o700);
    try {
      process.env.LANE_D_CLI_ARGS_PATH = argsPath; process.env.VOICELAYER_STT_OUTRO_GATE = "1";
      const backend = new WhisperCppBackend();
      Object.defineProperty(backend, "binaryPath", { value: binary });
      Object.defineProperty(backend, "modelPath", { value: join(root, "model-fixture.bin") });
      for (const [setting, code] of [["english", "en"], ["hebrew", "he"]]) {
        process.env.QA_VOICE_WHISPER_LANG = setting; writeFileSync(path, wav());
        const result = await backend.transcribe(path);
        expect(result.text).toBe("");
        expect(result.attemptEvidence).toMatchObject({ status: "EMPTY_RESPONSE",
          gateRemoval: { gate: "cjk-outro", removedSpans: 1, rawCharacters: "これは別の文章です。".length } });
        const args = readFileSync(argsPath, "utf8").trim().split("\n");
        expect(args[args.indexOf("-l") + 1]).toBe(code);
        writeFileSync(path, wav(0, 30));
        expect((await backend.transcribe(path)).text).toBe("これは別の文章です。");
      }
      process.env.QA_VOICE_WHISPER_LANG = "auto"; writeFileSync(path, wav());
      const autoResult = await backend.transcribe(path, { language: "en", detectedLanguage: "he" });
      expect(autoResult.text).toBe("これは別の文章です。");
      expect(autoResult.attemptEvidence).toMatchObject({ status: "RETURNED" });
      expect(autoResult.attemptEvidence?.gateRemoval).toBeUndefined();
    } finally {
      keys.forEach((key, i) => { if (saved[i] === undefined) delete process.env[key]; else process.env[key] = saved[i]; });
      rmSync(root, { recursive: true, force: true });
    }
  });
});
