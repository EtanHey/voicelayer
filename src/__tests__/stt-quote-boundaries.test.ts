import { expect, test } from "bun:test";
import { cleanupTranscriptionText } from "../stt-cleanup";
const env = { QA_VOICE_STT_VOCABULARY_DISABLED: "1", QA_VOICE_CORRECTOR: "off" };
for (const quote of ['"', "'"]) {
  test("keeps the word boundary after a closing quote " + quote.charCodeAt(0), () => {
    const text = `${quote}Lantern${quote} stays`;
    expect(cleanupTranscriptionText(text, env)).toBe(text);
  });
}
test("keeps a closing quote before a following word in prose", () => {
  const text = 'The "lantern" stays';
  expect(cleanupTranscriptionText(text, env)).toBe(text);
});
