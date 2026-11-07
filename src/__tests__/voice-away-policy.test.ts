import { expect, test } from "bun:test";
import { createVoiceToolContext } from "../mcp-notifications";
import { claimVoiceCall, recordNoAnswer, userVoicePresent } from "../voice-away-policy";

test("D5 speak consumes the same one-follow-up slot as Ask", () => {
  const context = createVoiceToolContext(undefined);
  expect(claimVoiceCall(context)).toBe(true);
  expect(recordNoAnswer(context)).toBe(true);
  expect(claimVoiceCall(context)).toBe(true); // follow-up voice_speak
  expect(claimVoiceCall(context)).toBe(false); // subsequent voice_ask or voice_speak
  userVoicePresent(); // VoiceBar record or detected speech
  expect(claimVoiceCall(context)).toBe(true);
  expect(recordNoAnswer(context)).toBe(true);
});
