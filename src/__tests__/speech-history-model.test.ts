import { expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import { z } from "zod";
import { initialSpeech, speechStates, transitionSpeech } from "../speech-state";

const path = process.env.VOICELAYER_SPEECH_HISTORY_MODEL_CASES;
test.skipIf(!path)("TLC History transitions preserve the first accepted terminal in real code", () => {
  if (!path) throw new Error("Run formal/speech-queue/check.sh");
  const cases = z.array(z.object({ trace: z.array(z.enum(speechStates)), state: z.enum(speechStates), moves: z.number().int() })).min(1)
    .parse(JSON.parse(readFileSync(path, "utf8")));
  const diagnostic = spyOn(console, "error").mockImplementation(() => {});
  try {
    for (const row of cases) {
      let record = initialSpeech();
      for (const to of row.trace) record = transitionSpeech(record, to, null, "2026-01-01T00:00:00.000Z") ?? record;
      expect({ state: record.state, moves: record.transitions.length }, `TLC History trace ${row.trace}`)
        .toEqual({ state: row.state, moves: row.moves });
    }
  } finally { diagnostic.mockRestore(); }
  console.log(`Replayed ${cases.length} TLC History transitions against transitionSpeech`);
});
