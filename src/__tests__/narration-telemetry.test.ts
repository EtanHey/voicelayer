import { expect, spyOn, test } from "bun:test";
import { readFileSync, writeFileSync } from "fs";
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
    archive.synthesisFallback("clone_synthesis_failed");
    archive.generated(file, "one two three four", "fixture", "short", "qwen3-tts", 0, 2000);
    const event = JSON.parse(String(log.mock.calls[0][0]));
    expect(event).toMatchObject({ event: "narration_generated", engine_tried: ["xtts-v2", "qwen3-tts"], engine_chosen: "qwen3-tts", configured_rate: "+5%", word_count: 4, audio_duration_ms: 2000, wpm: 120 });
    expect(event.fallback_reason).toBe("clone_synthesis_failed");
    expect(JSON.stringify(event)).not.toContain("one two");
    expect(JSON.stringify(event)).not.toContain("private original");
  } finally { log.mockRestore(); archive.move("playing"); archive.finish("completed", "USER_STOP"); await archive.settled(); }
});

test("D2 narration logging cannot throw or prevent archive audio retention", async () => {
  const archive = beginSpeechArchive("fixture"); await archive.settled();
  const file = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `${archive.key}-throw.mp3`);
  writeFileSync(file, "retained fixture audio");
  const log = spyOn(console, "error").mockImplementation(() => { throw Error("stderr unavailable"); });
  try { expect(() => archive.generated(file, "fixture words", "fixture", "short", "edge-tts", 0, 1000)).not.toThrow(); }
  finally { log.mockRestore(); }
  archive.move("playing"); archive.finish("completed", "USER_STOP"); await archive.settled();
  const metadata = JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8"));
  expect(readFileSync(join(archive.context.path, metadata.speech.generated[0].audio_path), "utf8")).toBe("retained fixture audio");
});

test("D2 partial receipt build metadata cannot break narration", async () => {
  const archive = beginSpeechArchive("fixture"); await archive.settled();
  const file = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `${archive.key}-partial.mp3`);
  writeFileSync(file, "fixture");
  const metadata = archive.context.metadata, build = metadata.build;
  Reflect.deleteProperty(metadata, "build");
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    expect(() => archive.generated(file, "fixture words", "fixture", "short", "edge-tts")).not.toThrow();
    expect(JSON.parse(String(log.mock.calls[0][0])).build_sha).toBeNull();
  } finally { metadata.build = build; log.mockRestore(); archive.finish("cancelled", "USER_STOP"); await archive.settled(); }
});

test("D4 requested rate is never reported as an effective rate", async () => {
  const archive = beginSpeechArchive("fixture"); await archive.settled();
  archive.context.metadata.requested.rate_raw = "+41%";
  const file = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `${archive.key}-unknown.mp3`);
  writeFileSync(file, "fixture");
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    archive.generated(file, "fixture words", "fixture", "short", "edge-tts");
    expect(JSON.parse(String(log.mock.calls[0][0])).configured_rate).toBeNull();
  } finally { log.mockRestore(); archive.finish("cancelled", "USER_STOP"); await archive.settled(); }
});

test("D4 a reused archive starts a narration with fresh diagnostics", async () => {
  const archive = beginSpeechArchive("fixture"); await archive.settled();
  archive.synthesisAttempt("previous-engine"); archive.synthesisConfiguredRate("-35%");
  const reused = beginSpeechArchive("fixture again", archive.context);
  const file = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `${archive.key}-reset.mp3`);
  writeFileSync(file, "fixture");
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    reused.generated(file, "fixture words", "fixture", "short", "edge-tts");
    expect(JSON.parse(String(log.mock.calls[0][0]))).toMatchObject({configured_rate: null, engine_tried: null, fallback_reason: null});
  } finally { log.mockRestore(); archive.finish("cancelled", "USER_STOP"); await archive.settled(); }
});
