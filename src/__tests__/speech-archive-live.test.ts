import { expect, test, spyOn, setSystemTime } from "bun:test";
import { readFileSync, writeFileSync, unlinkSync, mkdirSync } from "fs";
import { join } from "path";
import { speechOpenIndex, speechPendingIndex, beginSpeechReceipt } from "../speech-open-index";
import { beginSpeechArchive, recoverSpeechArchives, unlinkSpeechAudio } from "../speech-archive-live";
import { transitionSpeakArchive } from "../speak-archive-store";
const disk = (path: string) => JSON.parse(readFileSync(join(path, "metadata.json"), "utf8"));
for (const terminal of ["completed", "stopped", "cancelled", "failed"] as const) {
  test(`durable ${terminal} preserves original, actual input and audio`, async () => {
    expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
    const archive = beginSpeechArchive("  **original**\n");
    await archive.settled();
    const file = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `${archive.context.id}.mp3`);
    writeFileSync(file, "synthetic audio");
    archive.generated(file, "actual engine input", "fixture voice", "long", "fixture engine");
    unlinkSpeechAudio(file);
    archive.move("playing"); archive.move("paused"); archive.move("playing");
    archive.finish(terminal, "USER_STOP");
    await archive.settled();
    const metadata = disk(archive.context.path);
    expect(metadata.speech).toMatchObject({ state: terminal, reason: "USER_STOP", generated: [
      { text: "actual engine input", voice: "fixture voice", profile: "long", engine: "fixture engine" }] });
    expect(readFileSync(join(archive.context.path, "input.txt"), "utf8")).toBe("  **original**\n");
    expect(readFileSync(join(archive.context.path, metadata.speech.generated[0].audio_path), "utf8")).toBe("synthetic audio");
    expect(transitionSpeakArchive(archive.context, "preparing")).toEqual({ kind: "failed", code: "CONFLICT" });
    await recoverSpeechArchives();
    expect(disk(archive.context.path).speech.state).toBe(terminal);
  });
}
test("restart recovers preparing, playing and paused as interrupted", async () => {
  for (const state of ["preparing", "playing", "paused"] as const) {
    const archive = beginSpeechArchive(`fixture ${state}`);
    if (state !== "preparing") archive.move(state);
    await archive.settled();
    writeFileSync(join(speechOpenIndex(), archive.context.id), "2147483647");
    await recoverSpeechArchives();
    expect(disk(archive.context.path).speech).toMatchObject({ state: "interrupted", reason: "PROCESS_RESTART" });
    const before = readFileSync(join(archive.context.path, "metadata.json"), "utf8");
    await recoverSpeechArchives();
    expect(readFileSync(join(archive.context.path, "metadata.json"), "utf8")).toBe(before);
  }
});

test("player segments exclude delayed publication, synthesis gaps and paused time", async () => {
  const archive = beginSpeechArchive("timing fixture"); await archive.settled();
  const now = Date.now();
  try {
    setSystemTime(now); archive.playerStarted();
    setSystemTime(now + 1000); archive.playerEnded();
    setSystemTime(now + 10000); archive.playerStarted();
    setSystemTime(now + 10500); archive.playerEnded();
    archive.finish("completed", "PLAYBACK_COMPLETED");
  } finally { setSystemTime(); }
  await archive.settled();
  expect(disk(archive.context.path).speech.played_ms).toBe(1500);
});

test("recovery leaves terminal metadata byte-identical", async () => {
  const archive = beginSpeechArchive("terminal recovery fixture");
  archive.move("playing"); archive.finish("completed", "PLAYBACK_COMPLETED"); await archive.settled();
  const path = join(archive.context.path, "metadata.json");
  const before = readFileSync(path, "utf8");
  await recoverSpeechArchives();
  expect(readFileSync(path, "utf8")).toBe(before);
});

test("capture Cancel preserves a queue-owned preparing archive", async () => {
  const queued = beginSpeechArchive("queued read survives capture cancellation");
  await queued.settled();
  const { stopPlayback } = await import("../tts");
  stopPlayback(undefined, true); await queued.settled();
  expect(disk(queued.context.path).speech.state).toBe("preparing");
  queued.move("playing"); queued.finish("completed", "PLAYBACK_COMPLETED");
  await queued.settled();
  expect(disk(queued.context.path).speech.state).toBe("completed");
});

test("startup recovery stays off the event loop with 10k terminal records", async () => {
  const original = process.env.QA_VOICE_RECORDINGS_DIR!;
  const root = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "ten-thousand-terminal");
  mkdirSync(root, { mode: 0o700 });
  process.env.QA_VOICE_RECORDINGS_DIR = root;
  try {
    const day = join(root, "2026-10-26"); mkdirSync(day, { mode: 0o700 });
    for (let n = 0; n < 10000; n++) {
      const dir = join(day, `2026-10-26T00-00-00-000Z-${n.toString(16).padStart(8, "0")}`);
      mkdirSync(dir, { mode: 0o700 });
      writeFileSync(join(dir, "metadata.json"), '{"source":"speak","status":"completed"}', { mode: 0o600 });
    }
    const errors = spyOn(console, "error").mockImplementation(() => {});
    try {
      // Startup only schedules a worker; terminal count cannot add synchronous I/O.
      const start = performance.now();
      const recovered = recoverSpeechArchives();
      expect(performance.now() - start).toBeLessThan(100);
      let heartbeat = false;
      await new Promise<void>(resolve => setTimeout(() => { heartbeat = true; resolve(); }, 0));
      expect(heartbeat).toBe(true);
      await recovered;
      expect(errors).not.toHaveBeenCalled();
      expect(readFileSync(join(day, "2026-10-26T00-00-00-000Z-00000000", "metadata.json"), "utf8")).toBe('{"source":"speak","status":"completed"}');
    } finally { errors.mockRestore(); }
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = original; }
});

test("recovery skips another live writer and recovers indexed missing metadata", async () => {
  const live = beginSpeechArchive("another process is still speaking"); await live.settled();
  await recoverSpeechArchives();
  expect(disk(live.context.path).speech.state).toBe("preparing");
  const missing = beginSpeechArchive("missing metadata still has durable input"); await missing.settled();
  unlinkSync(join(missing.context.path, "metadata.json"));
  writeFileSync(join(speechOpenIndex(), missing.context.id), "2147483647");
  await recoverSpeechArchives();
  expect(disk(missing.context.path)).toMatchObject({ status: "interrupted_unknown", recovery: { metadata_missing: true } });
  live.finish("cancelled", "USER_CANCEL"); await live.settled();
});

test("one-time migration recovers pre-index open records", async () => {
  const original = process.env.QA_VOICE_RECORDINGS_DIR!;
  const root = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "legacy-open");
  mkdirSync(root, { mode: 0o700 }); process.env.QA_VOICE_RECORDINGS_DIR = root;
  try {
    for (const state of ["preparing", "playing", "paused"] as const) {
      const archive = beginSpeechArchive(`legacy ${state}`);
      if (state !== "preparing") archive.move(state);
      await archive.settled();
      unlinkSync(join(speechOpenIndex(), archive.context.id));
    }
    await recoverSpeechArchives();
    const { readdirSync } = await import("fs");
    for (const day of readdirSync(root).filter(name => /^\d{4}-/.test(name))) {
      for (const id of readdirSync(join(root, day))) {
        expect(disk(join(root, day, id)).speech).toMatchObject({ state: "interrupted", reason: "PROCESS_RESTART" });
      }
    }
    const later = beginSpeechArchive("after migration"); await later.settled();
    unlinkSync(join(speechOpenIndex(), later.context.id));
    await recoverSpeechArchives();
    expect(disk(later.context.path).speech.state).toBe("preparing");
    later.finish("cancelled", "USER_CANCEL"); await later.settled();
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = original; }
});

test("legacy migration checkpoints a bounded slice and resumes after restart", async () => {
  const { migrateLegacySpeechSlice } = await import("../speech-archive-legacy-migration");
  const original = process.env.QA_VOICE_RECORDINGS_DIR!;
  const root = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "legacy-resume");
  mkdirSync(root, { mode: 0o700 }); process.env.QA_VOICE_RECORDINGS_DIR = root;
  try {
    const day = join(root, "2020-01-01"); mkdirSync(day, { mode: 0o700 });
    for (let n = 0; n < 100; n++) {
      const dir = join(day, `2020-01-01T00-00-00-000Z-${n.toString(16).padStart(8, "0")}`);
      mkdirSync(dir, { mode: 0o700 });
      writeFileSync(join(dir, "metadata.json"), '{"source":"speak","status":"completed"}');
      // Reconciliation would reject this invalid audio; terminal history must skip it.
      mkdirSync(join(dir, "audio")); writeFileSync(join(dir, "audio", "invalid.mp3"), "fixture");
    }
    const legacy = beginSpeechArchive("resume legacy fixture"); await legacy.settled();
    unlinkSync(join(speechOpenIndex(), legacy.context.id));
    expect(await migrateLegacySpeechSlice()).toEqual({ more: true, recovered: [] });
    expect(readFileSync(join(root, ".speech-index-migration-v1"), "utf8")).toBe("2020-01-01T00-00-00-000Z-00000063");
    expect(disk(legacy.context.path).speech.state).toBe("preparing");
    // A fresh worker reads the persisted cursor, rather than process-local state.
    await recoverSpeechArchives();
    expect(disk(legacy.context.path).speech).toMatchObject({ state: "interrupted", reason: "PROCESS_RESTART" });
    expect(readFileSync(join(root, ".speech-index-migration-v1"), "utf8")).toBe("done");
    expect(readFileSync(join(day, "2020-01-01T00-00-00-000Z-00000000", "metadata.json"), "utf8")).toBe('{"source":"speak","status":"completed"}');
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = original; }
});


test("startup recovers pending publication gaps after legacy migration has finished", async () => {
  const root = process.env.QA_VOICE_RECORDINGS_DIR!;
  await recoverSpeechArchives();
  for (const missingMetadata of [false, true]) {
    const archive = beginSpeechArchive("pending publication fixture"); await archive.settled();
    unlinkSync(join(speechOpenIndex(), archive.context.id));
    beginSpeechReceipt(archive.context.id);
    const pending = join(speechPendingIndex(), archive.context.id);
    const { renameSync, existsSync } = await import("fs");
    renameSync(join(pending, String(process.pid)), join(pending, "2147483647"));
    if (missingMetadata) unlinkSync(join(archive.context.path, "metadata.json"));
    await recoverSpeechArchives();
    expect(disk(archive.context.path).status).toBe("interrupted_unknown");
    expect(existsSync(pending)).toBe(false);
    expect(readFileSync(join(archive.context.path, "input.txt"), "utf8")).toBe("pending publication fixture");
  }
});

test("legacy migration leaves a live pending receipt alone", async () => {
  const { migrateLegacySpeechSlice } = await import("../speech-archive-legacy-migration");
  const root = process.env.QA_VOICE_RECORDINGS_DIR!;
  const archive = beginSpeechArchive("live pending publication fixture"); await archive.settled();
  unlinkSync(join(speechOpenIndex(), archive.context.id));
  beginSpeechReceipt(archive.context.id);
  const { rmSync } = await import("fs");
  rmSync(join(root, ".speech-index-migration-v1"), { force: true });
  await migrateLegacySpeechSlice();
  expect(disk(archive.context.path).speech.state).toBe("preparing");
});


test("bounded startup slices recover every pending intent beyond one hundred", async () => {
  const original = process.env.QA_VOICE_RECORDINGS_DIR!;
  const root = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "pending-slices");
  mkdirSync(root, { mode: 0o700 }); process.env.QA_VOICE_RECORDINGS_DIR = root;
  const { renameSync, existsSync } = await import("fs");
  const paths: string[] = [];
  try {
    for (let n = 0; n < 105; n++) {
      const archive = beginSpeechArchive(`pending slice fixture ${n}`); await archive.settled();
      unlinkSync(join(speechOpenIndex(), archive.context.id));
      beginSpeechReceipt(archive.context.id);
      const pending = join(speechPendingIndex(), archive.context.id);
      renameSync(join(pending, String(process.pid)), join(pending, "2147483647"));
      paths.push(archive.context.path);
    }
    await recoverSpeechArchives();
    for (const path of paths) {
      expect(disk(path).status).toBe("interrupted_unknown");
      expect(existsSync(join(speechPendingIndex(), path.split("/").at(-1)!))).toBe(false);
    }
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = original; }
});
