import { afterEach, expect, test } from "bun:test";
import { VoiceAskSchema, ConverseArgsSchema } from "../schemas/mcp-inputs";
import { getToolDefinitions } from "../mcp-tools";
import { formatVoiceAskTurnResult } from "../voice-turn-result";

const saved = process.env.VOICELAYER_ASK_NO_ANSWER_SECONDS;
afterEach(() => {
  if (saved === undefined) delete process.env.VOICELAYER_ASK_NO_ANSWER_SECONDS;
  else process.env.VOICELAYER_ASK_NO_ANSWER_SECONDS = saved;
});
for (const [raw, expected] of [[undefined, 120], ["", 120], ["garbage", 120], ["Infinity", 120], ["-1", 120], ["4", 120], ["3601", 120], ["240", 240]] as const) {
  test(`D5 no-answer env ${raw} -> ${expected}s in both ingress paths`, () => {
    if (raw === undefined) delete process.env.VOICELAYER_ASK_NO_ANSWER_SECONDS;
    else process.env.VOICELAYER_ASK_NO_ANSWER_SECONDS = raw;
    for (const schema of [VoiceAskSchema, ConverseArgsSchema]) {
      const parsed = schema.parse({ message: "Question?" });
      expect(parsed.timeout_seconds).toBe(expected);
      expect(schema.parse({ message: "Question?", timeout_seconds: 60 }).timeout_seconds).toBe(60);
    }
  });
}
test("D5 both tool descriptions limit agents to ONE follow-up, then away", () => {
  for (const tool of getToolDefinitions()) {
    expect(tool.description).toContain("ONE follow-up voice_speak or voice_ask");
    expect(tool.description).toContain("then continue as if the user is away");
    expect(tool.description).toContain("do not keep asking");
  }
});
test("D5 no-answer result explains retained path and follow-up limit", () => {
  const result = formatVoiceAskTurnResult({ kind: "no-answer", timeoutSeconds: 120,
    recovery: { archiveId: "synthetic", audioPath: "/synthetic/audio.wav" }, promptPlayback: undefined });
  expect(result.isError).not.toBe(true);
  expect(result.content[0].text).toContain("No answer within 2 minutes; recording kept at /synthetic/audio.wav");
  expect(result.content[0].text).toContain("ONE follow-up");
  expect(result.content[0].text).toContain("archive synthetic");
  expect(result.content[0].text).toContain("continue as if the user is away");
});
