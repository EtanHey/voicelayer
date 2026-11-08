import { expect, spyOn, test } from "bun:test";
import { writeFileSync } from "fs";
import { join } from "path";
import { beginSpeechArchive } from "../speech-archive-live";

test("narration diagnostics report measured pace and fallback without private text", async () => {
  const archive = beginSpeechArchive("private original");
  await archive.settled();
  const file = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "telemetry.mp3");
  writeFileSync(file, "fixture");
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    archive.synthesisAttempt("xtts-v2");
    archive.synthesisAttempt("qwen3-tts");
    archive.synthesisConfiguredRate("+5%");
    archive.generated(file, "one two three four", "fixture", "short", "qwen3-tts", 0, 2000);
    const event = JSON.parse(String(log.mock.calls[0][0]));
    expect(event).toMatchObject({ event: "narration_generated", engine_tried: ["xtts-v2", "qwen3-tts"], engine_chosen: "qwen3-tts", configured_rate: "+5%", word_count: 4, audio_duration_ms: 2000, wpm: 120 });
    expect(event.fallback_reason).toBe("preceding_engine_unavailable_or_failed");
    expect(JSON.stringify(event)).not.toContain("one two");
    expect(JSON.stringify(event)).not.toContain("private original");
  } finally { log.mockRestore(); archive.finish("completed", "TEST"); await archive.settled(); }
});
