import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, realpathSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { TTS_HISTORY_FILE } from "../paths";
import { hasPreviousRead } from "../tts";

let previous: Buffer | undefined;
let observed: boolean;
let ownsHistory = false;

beforeAll(() => {
  const root = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !root) {
    throw new Error("T1 requires the isolated preload before any fixture access");
  }
  const scope = relative(realpathSync(root), realpathSync(dirname(TTS_HISTORY_FILE)));
  if (scope.startsWith("..") || scope.startsWith("/")) throw new Error("T1 history escaped isolated root");
  const directory = mkdtempSync(join(root, "etan-qa-0510-"));
  const audio = join(directory, "unheard.mp3");
  // Availability checks only existence. This is not playable audio; no player is started.
  writeFileSync(audio, "synthetic availability fixture");
  previous = existsSync(TTS_HISTORY_FILE) ? readFileSync(TTS_HISTORY_FILE) : undefined;
  writeFileSync(TTS_HISTORY_FILE, JSON.stringify([
    { id: 0, timestamp: Date.now(), text: "T1 archive-only item never queued or heard", file: audio, voice: "qa" },
  ]));
  ownsHistory = true;
  observed = hasPreviousRead();
  console.log(`[T1] current queue has no submitted fixture; archiveOnlyPreviousAvailable=${observed}`);
});

afterAll(() => {
  if (!ownsHistory) return;
  if (previous) writeFileSync(TTS_HISTORY_FILE, previous);
  else unlinkSync(TTS_HISTORY_FILE);
});

// Bun's strict expected-failure counterpart; arrangement/errors remain outside the inverted callback.
test.failing("T1_BackIgnoresArchiveOnlyItemsOutsideTheCurrentQueue [T1]", () => {
  expect(observed).toBe(false);
});
