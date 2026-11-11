import { afterAll, expect, test } from "bun:test";
import { finalizeTranscriptionText } from "../input";
import { polishTranscriptionText } from "../stt-polish";
let reply = "";
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () =>
  Response.json({ choices: [{ message: { content: reply } }] }) });
afterAll(() => server.stop(true));
for (const surface of ["dictation", "voice_ask"] as const) {
  for (const [raw, candidate, expected] of [
    ["hello world", "- Hello world.", "Hello world."],
    ["hello world", "— Hello world.", "Hello world."],
    ["- hello world", "- Hello world.", "- Hello world."],
    ["— hello world", "— Hello world.", "— Hello world."],
    ["dash hello world", "- hello world.", "- hello world."],
    ["use -s please", "Use -s please.", "Use -s please."],
    ["it is -32 today", "It is -32 today.", "It is -32 today."],
    ["first item and second item", "- First item\n- and second item.", "- First item\n- and second item."],
  ]) test(`${surface}: ${raw} / ${candidate}`, async () => {
    reply = candidate;
    const env = {
      ...process.env, QA_VOICE_CORRECTOR: "off", QA_VOICE_STT_POLISH: "on",
      QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
      VOICELAYER_STT_COHERENT_PARAGRAPHS: "0", VOICELAYER_STT_PAUSE_PARAGRAPHS: "0",
    };
    // The validator must retain supplied pause markers. Delivery substitutes
    // U+2014 later; l7-formatting.test.ts exercises that separate boundary.
    const result = await polishTranscriptionText({
      rawText: raw, cleanedText: finalizeTranscriptionText(raw, env), surface, env,
    });
    expect(result.text).toBe(expected);
  });
}
