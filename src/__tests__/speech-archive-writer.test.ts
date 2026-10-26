import { expect, test, spyOn } from "bun:test";
import * as fs from "fs";
import { join } from "path";
import { applyArchiveWrite } from "../speech-archive-worker";
import { beginSpeechArchive, unlinkSpeechAudio } from "../speech-archive-live";
import { speechArchiveWriter } from "../speech-archive-writer";
const at = "2026-10-26T00:00:00.000Z";
for (const fault of ["rename", "directory-sync"] as const) test(`terminal ${fault} uncertainty retries exactly one durable edge`, async () => {
  const archive = beginSpeechArchive("retry fixture"); await archive.settled();
  const c = archive.context, key = crypto.randomUUID();
  applyArchiveWrite(key, { kind: "init", text: "", context: c });
  applyArchiveWrite(key, { kind: "move", to: "playing", reason: null, at }, c);
  const rename = fs.renameSync, sync = fs.fsyncSync; let attempts = 0;
  const spy = fault === "rename" ? spyOn(fs, "renameSync").mockImplementation((a, b) => { if (String(b).endsWith("metadata.json") && attempts++ === 0) throw Error("synthetic"); rename(a, b); }) :
    spyOn(fs, "fsyncSync").mockImplementation(fd => { if (fs.fstatSync(fd).isDirectory() && attempts++ === 0) throw Error("synthetic"); sync(fd); });
  try { expect(applyArchiveWrite(key, { kind: "move", to: "completed", reason: "PLAYBACK_COMPLETED", at }, c)).toEqual({ context: c }); }
  finally { spy.mockRestore(); }
  const m = JSON.parse(fs.readFileSync(join(c.path, "metadata.json"), "utf8"));
  expect(m.speech.state).toBe("completed");
  expect(m.speech.transitions.filter((t: { to: string }) => t.to === "completed")).toHaveLength(1);
  expect(attempts).toBeGreaterThan(1);
});

test("exhausted terminal writes are retained, reported and explicitly retryable", async () => {
  const archive = beginSpeechArchive("retained failure fixture"); await archive.settled();
  archive.playerStarted(); await archive.settled();
  const write = speechArchiveWriter.write.bind(speechArchiveWriter);
  const log = spyOn(console, "error").mockImplementation(() => {});
  const spy = spyOn(speechArchiveWriter, "write").mockImplementation(async (...args) => {
    if (args[1].kind === "move" && args[1].to === "completed") throw Error("synthetic private failure");
    return write(...args);
  });
  try {
    archive.playerEnded(); archive.finish("completed", "PLAYBACK_COMPLETED"); await archive.settled();
    expect(archive.failures).toHaveLength(1);
    expect(log).toHaveBeenCalledWith("[speech] archive write failed: move");
  } finally { spy.mockRestore(); log.mockRestore(); }
  await archive.retryFailed();
  expect(archive.failures).toEqual([]);
  expect(JSON.parse(fs.readFileSync(join(archive.context.path, "metadata.json"), "utf8")).speech.state).toBe("completed");
});

test("failed audio publication retains source through cleanup and successful retry", async () => {
  const archive = beginSpeechArchive("audio retry fixture"); await archive.settled();
  const source = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `${crypto.randomUUID()}.mp3`); fs.writeFileSync(source, "synthetic audio");
  const write = speechArchiveWriter.write.bind(speechArchiveWriter), log = spyOn(console, "error").mockImplementation(() => {});
  const spy = spyOn(speechArchiveWriter, "write").mockImplementation(async (...args) => {
    if (args[1].kind === "audio") throw Error("synthetic"); return write(...args);
  });
  try {
    archive.generated(source, "actual", "effective", "long", "fixture", 0, 2500); unlinkSpeechAudio(source);
    await archive.settled(); expect(fs.existsSync(source)).toBe(true); expect(archive.failures).toHaveLength(1);
  } finally { spy.mockRestore(); log.mockRestore(); }
  await archive.retryFailed(); expect(fs.existsSync(source)).toBe(false);
  archive.finish("cancelled", "USER_CANCEL"); await archive.settled();
  const m = JSON.parse(fs.readFileSync(join(archive.context.path, "metadata.json"), "utf8"));
  expect(m.lifecycle.summary.generated_audio_ms).toBe(2500);
  expect(m.speech.played_ms).toBe(0);
  expect(m.speech.generated).toHaveLength(1);
  expect(fs.readFileSync(join(archive.context.path, m.speech.generated[0].audio_path), "utf8")).toBe("synthetic audio");
});

test("generated duration sums chunks without counting concatenated playback twice", async () => {
  const archive = beginSpeechArchive("duration sum"); await archive.settled();
  const paths = [0, 1, 2].map(i => join(process.env.VOICELAYER_TEST_RUN_ROOT!, `${crypto.randomUUID()}-${i}.mp3`));
  paths.forEach((p, i) => fs.writeFileSync(p, `synthetic ${i}`));
  archive.generated(paths[0], "chunk zero", "voice", "long", "fixture", 0, 1000);
  archive.generated(paths[1], "chunk one", "voice", "long", "fixture", 1, 2000);
  archive.keepAudio(paths[2], 3000);
  paths.forEach(unlinkSpeechAudio);
  archive.finish("cancelled", "USER_CANCEL"); await archive.settled();
  const m = JSON.parse(fs.readFileSync(join(archive.context.path, "metadata.json"), "utf8"));
  expect(m.lifecycle.summary.generated_audio_ms).toBe(3000);
  expect(m.speech.played_ms).toBe(0); expect(m.artifacts).toHaveLength(3);
  expect(paths.every(p => !fs.existsSync(p))).toBe(true);
});

test("permanent metadata rename fault uses three bounded retries without publication", async () => {
  const archive = beginSpeechArchive("bounded failure"); await archive.settled();
  const c = archive.context, prior = fs.readFileSync(join(c.path, "metadata.json"));
  let attempts = 0;
  const spy = spyOn(fs, "renameSync").mockImplementation(() => { attempts++; throw Error("synthetic private diagnostic"); });
  try { expect(applyArchiveWrite(crypto.randomUUID(), { kind: "move", to: "failed", reason: "SYNTH_FAILED", at }, c)).toEqual({ error: "WRITE_UNCERTAIN" }); }
  finally { spy.mockRestore(); }
  expect(attempts).toBe(3);
  expect(fs.readFileSync(join(c.path, "metadata.json"))).toEqual(prior);
});
