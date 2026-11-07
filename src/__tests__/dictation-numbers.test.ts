import { expect, test } from "bun:test";
import { applyRules } from "../rules-engine";

const cases = [
  ["32k", "32k"], ["30,016", "30,016"],
  ["thirty two k", "32k"], ["thirty-two k", "32k"],
  ["thirty-two thousand", "32000"],
  ["thirty thousand and sixteen", "30,016"],
  ["thirty thousand sixteen", "30,016"],
  ["one of the things", "One of the things"],
  ["the one I wanted", "The one I wanted"],
  ["one more time", "One more time"],
  ["one thousand two hundred", "1200"],
  ["the one thousand apples", "The 1000 apples"],
  ["one apple", "1 apple"], ["two three", "2 3"],
  ["thirty thousand and sixteen apples", "30,016 apples"],
  ["thirty thousand and two three", "30000 and 2 3"],
  ["thirty thousand and two two", "30000 and 2 2"],
  ["thirty thousand and sixty thousand", "30000 and 60000"],
  ["thirty thousand and one more time", "30000 and one more time"],
  ["thirty-two people", "32 people"],
  ["thirty-two thousand.", "32000."],
  ["thirty thousand and sixteen.", "30,016."],
  ["thirty-two k, please", "32k, please"],
  ["thirty two. three", "32. 3"],
  ["one... one more time", "One... One more time"],
  ["one… one more time", "One… one more time"],
  ["thirty-two-year-old", "Thirty-two-year-old"],
  ["thirty two\nk", "32\nK"],
] as const;
for (const [input, output] of cases) {
  test(`number stage: ${input}`, () => expect(applyRules(input)).toBe(output));
}

// Exercise the shared dictation/voice_ask caller. The synthetic endpoint echoes
// the deterministic result; this is caller/guard proof, not acoustic evidence.
import { afterAll } from "bun:test";
import { finalizeTranscriptionResultForSurface } from "../input";
let reply = "";
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () =>
  Response.json({ choices: [{ message: { content: reply } }] }) });
afterAll(() => server.stop(true));
for (const surface of ["dictation", "voice_ask"] as const) {
  test(`${surface} number forms survive the polish caller`, async () => {
    for (const [raw, expected] of cases.slice(0, 12)) {
      reply = `${expected}.`;
      const result = await finalizeTranscriptionResultForSurface(raw, surface, {
        ...process.env, QA_VOICE_CORRECTOR: "off", QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
        QA_VOICE_STT_POLISH_TIMEOUT_MS: "5000",
        VOICELAYER_STT_COHERENT_PARAGRAPHS: "0", VOICELAYER_STT_PAUSE_PARAGRAPHS: "0",
      });
      expect(result.text).toBe(reply);
      expect(result.polishStatus).toBe("applied");
    }
  });
}
