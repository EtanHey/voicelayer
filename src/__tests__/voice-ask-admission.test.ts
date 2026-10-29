import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { VoiceAskSchema } from "../schemas/mcp-inputs";
import { parseVoiceAskIngress, type NormalAskRequest } from "../voice-ask-admission";

const archiveId = "2026-10-25T00-00-00-000Z-aabbccdd";
const invalidText = "Invalid voice_ask arguments: provide exactly one mode — {message: ...} or {retranscribe_archive_id: ...}.";
const refusal = (reason: string, text: string) => ({
  kind: "refused", reason, result: { content: [{ type: "text", text }], isError: true },
});
const spies: Array<{ mockRestore(): void }> = [];
afterEach(() => { for (const spy of spies.splice(0).reverse()) spy.mockRestore(); });

describe("pure public Ask ingress", () => {
  for (const args of [undefined, null, false, 0, "prompt", () => {}]) {
    it(`preserves the full missing-arguments refusal for ${typeof args}:${String(args)}`, () => {
      const parse = spyOn(VoiceAskSchema, "safeParse"); spies.push(parse);
      expect(parseVoiceAskIngress(args)).toEqual(refusal("missing-arguments", "Missing arguments"));
      expect(parse).not.toHaveBeenCalled();
    });
  }
  for (const args of [[], {}, { message: 1 }, { message: " \n\t" },
    { message: "prompt", timeout_seconds: 1 }, { message: "prompt", timeout_seconds: "30" },
    { message: "prompt", timeout_seconds: 3601 }, { retranscribe_archive_id: "invalid" },
    { message: "prompt", retranscribe_archive_id: archiveId }]) {
    it(`preserves the full invalid-mode refusal: ${JSON.stringify(args)}`, () => {
      const parse = spyOn(VoiceAskSchema, "safeParse"); spies.push(parse);
      expect(parseVoiceAskIngress(args)).toEqual(refusal("invalid-mode", invalidText));
      expect(parse).toHaveBeenCalledTimes(1);
      expect(parse.mock.calls[0][0]).toBe(args);
    });
  }
  it("retains original Unicode/retractions/fragments independently of trimmed, defaulted, stripped input", () => {
    const raw = " \tשלום🙂 fu… no, full\r\n  ";
    const request = { message: raw } satisfies NormalAskRequest;
    expect(parseVoiceAskIngress({ ...request, untrusted: "discard" })).toEqual({
      kind: "normal", input: { message: raw.trim(), timeout_seconds: 30 },
      originalMessage: raw, legacyPressToTalk: false,
    });
  });
  it("keeps an explicitly undefined archive field in normal mode", () => {
    expect(parseVoiceAskIngress({ message: "prompt", retranscribe_archive_id: undefined })).toEqual({
      kind: "normal", input: { message: "prompt", timeout_seconds: 30, retranscribe_archive_id: undefined },
      originalMessage: "prompt", legacyPressToTalk: false,
    });
  });
  it("accepts explicit normal options without changing their values", () => {
    const args = { message: "prompt", timeout_seconds: 5, voice: "synthetic", silence_mode: "quick", push_to_end: false };
    expect(parseVoiceAskIngress(args)).toEqual({ kind: "normal", input: args,
      originalMessage: "prompt", legacyPressToTalk: false });
  });
  it("accepts only the strict archive mode", () => {
    expect(parseVoiceAskIngress({ retranscribe_archive_id: archiveId })).toEqual({
      kind: "retranscribe", input: { retranscribe_archive_id: archiveId },
    });
    for (const extra of [{ message: undefined }, { press_to_talk: false }, { unknown: undefined }]) {
      expect(parseVoiceAskIngress({ retranscribe_archive_id: archiveId, ...extra })).toEqual(refusal("invalid-mode", invalidText));
    }
  });
  for (const value of [false, undefined]) it(`detects own legacy flag with value ${value}`, () => {
    expect(parseVoiceAskIngress({ message: "prompt", press_to_talk: value })).toEqual({
      kind: "normal", input: { message: "prompt", timeout_seconds: 30 },
      originalMessage: "prompt", legacyPressToTalk: true,
    });
  });
  it("ignores inherited legacy flags", () => {
    const args = Object.assign(Object.create({ press_to_talk: true }), { message: "prompt" });
    expect(parseVoiceAskIngress(args)).toEqual({ kind: "normal", input: { message: "prompt", timeout_seconds: 30 },
      originalMessage: "prompt", legacyPressToTalk: false });
  });
  it("reads the original message twice before the one public parse and checks ownership afterwards", () => {
    const events: string[] = [];
    let reads = 0;
    const args = new Proxy({ message: "unused" }, {
      get(target, key, receiver) {
        if (key === "message") { events.push("message"); return ++reads <= 2 ? " raw " : " parsed "; }
        return Reflect.get(target, key, receiver);
      },
      getOwnPropertyDescriptor(target, key) {
        if (key === "press_to_talk") events.push("ownership");
        return Reflect.getOwnPropertyDescriptor(target, key);
      },
    });
    const realParse = VoiceAskSchema.safeParse.bind(VoiceAskSchema);
    const parse = spyOn(VoiceAskSchema, "safeParse").mockImplementation(value => {
      events.push("safeParse"); return realParse(value);
    }); spies.push(parse);
    expect(parseVoiceAskIngress(args)).toEqual({ kind: "normal", input: { message: "parsed", timeout_seconds: 30 },
      originalMessage: " raw ", legacyPressToTalk: false });
    expect(events).toEqual(["message", "message", "safeParse", "message", "ownership"]);
    expect(parse).toHaveBeenCalledTimes(1);
  });
  for (const throwAt of [1, 2, 3]) it(`preserves accessor exception identity on read ${throwAt}`, () => {
    const sentinel = new Error(`synthetic accessor ${throwAt}`);
    let reads = 0;
    const args = { get message() { if (++reads === throwAt) throw sentinel; return "prompt"; } };
    const parse = spyOn(VoiceAskSchema, "safeParse"); spies.push(parse);
    let caught: unknown;
    try { parseVoiceAskIngress(args); } catch (error) { caught = error; }
    expect(caught).toBe(sentinel);
    expect(parse).toHaveBeenCalledTimes(throwAt === 3 ? 1 : 0);
  });
  it("lets a schema exception escape with its identity after original-message access", () => {
    const sentinel = new Error("synthetic schema exception"), events: string[] = [];
    const parse = spyOn(VoiceAskSchema, "safeParse").mockImplementation(() => { events.push("parse"); throw sentinel; });
    spies.push(parse);
    let caught: unknown;
    try { parseVoiceAskIngress({ get message() { events.push("message"); return "prompt"; } }); }
    catch (error) { caught = error; }
    expect(caught).toBe(sentinel);
    expect(events).toEqual(["message", "message", "parse"]);
    expect(parse).toHaveBeenCalledTimes(1);
  });
});
