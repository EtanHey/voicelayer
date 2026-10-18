import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { normalizedSpeechHash } from "../speech-identity";
import { parseCommand } from "../socket-protocol";
import { handleSocketCommand } from "../socket-handlers";
import * as tts from "../tts";
import * as input from "../input";
import * as recording from "../recording-state";
import * as reservation from "../voice-operation-reservation";

const spies: ReturnType<typeof spyOn>[] = [];
afterEach(() => { for (const spy of spies.splice(0)) spy.mockRestore(); });
describe("speak_text socket command", () => {
  it("accepts more than MCP's cap and preserves all text and optional fields", () => {
    const command = { cmd: "speak_text", text: "word ".repeat(10000), profile: "long", format: "markdown", source: "selection", id: "s1", text_hash: "a".repeat(64) };
    expect(parseCommand(JSON.stringify(command))).toEqual(command);
  });
  it("hashes normalized Unicode whitespace without projecting or changing the input", () => {
    expect(normalizedSpeechHash(" hello\nworld ")).toBe("b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9");
    expect(normalizedSpeechHash("hello\u0085\u00a0\u2003world")).toBe(normalizedSpeechHash("hello world"));
    expect(normalizedSpeechHash("**hello** world")).not.toBe(normalizedSpeechHash("hello world"));
    for (const text_hash of ["invalid", 4, "A".repeat(64)]) {
      expect(parseCommand(JSON.stringify({ cmd: "speak_text", text: "hello", text_hash }))).toBeNull();
    }
  });
  it("enforces the 200,000-character sanity maximum", () => {
    expect(parseCommand(JSON.stringify({ cmd: "speak_text", text: "x".repeat(200000) }))).not.toBeNull();
    expect(parseCommand(JSON.stringify({ cmd: "speak_text", text: "x".repeat(200001) }))).toBeNull();
  });
  it("rejects empty text and invalid options", () => {
    for (const fields of [{ text: " " }, { text: 3 }, { text: "a", profile: "invalid" }, { text: "a", format: "html" }, { text: "a", source: 4 }]) {
      expect(parseCommand(JSON.stringify({ cmd: "speak_text", ...fields }))).toBeNull();
    }
  });
  it("refuses while local or cross-process recording is busy", () => {
    const local = spyOn(input, "getRecordingState").mockReturnValue("idle"); spies.push(local);
    const effective = spyOn(recording, "getEffectiveRecordingState"); spies.push(effective);
    for (const state of ["recording", "transcribing"] as const) {
      effective.mockReturnValue(state);
      expect(handleSocketCommand({ cmd: "speak_text", text: "hello" } as any)).toMatchObject({ command: "speak_text", outcome: "reject", reason: "busy" });
    }
  });
  it("refuses during voice_ask's reserved prompt-to-recording transition", () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(reservation, "hasActiveVoiceOperation").mockReturnValue(true));
    expect(handleSocketCommand({ cmd: "speak_text", text: "hello" } as any)).toMatchObject({ outcome: "reject", reason: "busy" });
  });
  it("normalizes markdown before starting through the profile seam", () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(reservation, "hasActiveVoiceOperation").mockReturnValue(false));
    const start = spyOn(tts, "speakText").mockReturnValue({ id: "test", done: Promise.resolve() }); spies.push(start);
    expect(handleSocketCommand({ cmd: "speak_text", text: "**Hi**", format: "markdown", profile: "long", id: "s2" } as any)).toMatchObject({ outcome: "accept", id: "s2" });
    expect(start).toHaveBeenCalledWith("Hi", "long", { request_id: "s2", text_hash: "46f3be07cae69b13f2cf62e764b4aa3f3aa67de0f952d0e37cd1d87f6fff63a4" });
  });
});
