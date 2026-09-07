import { afterEach, describe, expect, it } from "bun:test";
import { STT_DICTATION_SEED_PROMPT, buildSinglePassWhisperServerOptions,
  buildWhisperServerOptions, sttSeedPromptEnabled } from "../stt";

const FLAG = "VOICELAYER_STT_SEED_PROMPT";
const savedFlag = process.env[FLAG];
const savedLanguage = process.env.QA_VOICE_WHISPER_LANG;
afterEach(() => {
  for (const [key, value] of [[FLAG, savedFlag], ["QA_VOICE_WHISPER_LANG", savedLanguage]]) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});
describe("single-pass auto-mode STT seed prompt", () => {
  it("is default-off and accepts only the documented true values", () => {
    for (const value of [undefined, "", "0", "false", "enabled", "2"]) {
      expect(sttSeedPromptEnabled({ [FLAG]: value })).toBe(false);
    }
    for (const value of ["1", "true", "TRUE", "on", "On", "yes", "YES"]) {
      expect(sttSeedPromptEnabled({ [FLAG]: value })).toBe(true);
    }
  });
  it("keeps the default auto-mode request byte-identical", () => {
    delete process.env[FLAG];
    delete process.env.QA_VOICE_WHISPER_LANG;
    expect(buildSinglePassWhisperServerOptions({ hasSpeech: true })).toEqual({ language: "auto" });
  });
  it("adds the term-free prompt only for detected speech in auto mode", () => {
    process.env[FLAG] = "yes";
    delete process.env.QA_VOICE_WHISPER_LANG;
    expect(buildSinglePassWhisperServerOptions({ hasSpeech: true })?.prompt)
      .toBe(STT_DICTATION_SEED_PROMPT);
    expect(buildSinglePassWhisperServerOptions({ hasSpeech: false })?.prompt)
      .toBeUndefined();

    process.env.QA_VOICE_WHISPER_LANG = "hebrew";
    expect(buildSinglePassWhisperServerOptions({ hasSpeech: true })?.prompt)
      .not.toContain(STT_DICTATION_SEED_PROMPT);
  });
  it("preserves chunk continuity instead of adding the seed prompt", () => {
    process.env[FLAG] = "1";
    delete process.env.QA_VOICE_WHISPER_LANG;
    expect(buildSinglePassWhisperServerOptions({
      hasSpeech: true, promptOverride: "previous chunk transcript",
    })?.prompt).toBe("previous chunk transcript");
    expect(buildWhisperServerOptions({ hasSpeech: true })).toEqual({ language: "auto" });
  });

  it("keeps the exact prompt short, punctuated, and term-free", () => {
    expect(STT_DICTATION_SEED_PROMPT.length).toBeLessThanOrEqual(200);
    expect(STT_DICTATION_SEED_PROMPT).toEndWith(".");
    expect(STT_DICTATION_SEED_PROMPT).toContain("colon, comma, period");
    expect(STT_DICTATION_SEED_PROMPT).toContain("new line, new paragraph");
    expect(STT_DICTATION_SEED_PROMPT).toContain("question mark");
    expect(STT_DICTATION_SEED_PROMPT).toContain("open paren");
    expect(STT_DICTATION_SEED_PROMPT).toContain("close paren");
    expect(STT_DICTATION_SEED_PROMPT)
      .not.toMatch(/Etan|Sarah|Claude|Codex|GitHub|TypeScript|VoiceLayer/i);
  });
});
