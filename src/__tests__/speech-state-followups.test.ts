import { expect, test, spyOn } from "bun:test";
import { mkdirSync, readFileSync, renameSync, rmdirSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { beginSpeechArchive, recoverSpeechArchives, unlinkSpeechAudio } from "../speech-archive-live";
import { migrateLegacySpeechSlice } from "../speech-archive-legacy-migration";
import { speechArchiveWriter } from "../speech-archive-writer";
import { speechOpenIndex } from "../speech-open-index";
import { recoverSpeakArchive } from "../speak-archive-store";
import * as store from "../speak-archive-store";

const disk = (path: string) => JSON.parse(readFileSync(join(path, "metadata.json"), "utf8"));

for (const corrupt of ["schema", "json"] as const) test(`R1C migration advances past corrupt legacy ${corrupt} to healthy receipts`, async () => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const original = process.env.QA_VOICE_RECORDINGS_DIR;
  const root = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `legacy-corrupt-${corrupt}`);
  mkdirSync(root, { mode: 0o700 });
  process.env.QA_VOICE_RECORDINGS_DIR = root;
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    const id = "2020-01-01T00-00-00-000Z-00000000";
    const bad = join(root, "2020-01-01", id);
    mkdirSync(bad, { recursive: true, mode: 0o700 });
    writeFileSync(join(bad, "input.txt"), "corrupt receipt fixture", { mode: 0o600 });
    const bytes = corrupt === "schema" ? '{"source":"speak","status":"playing"}' : "{";
    writeFileSync(join(bad, "metadata.json"), bytes, { mode: 0o600 });
    expect(recoverSpeakArchive(id)).toEqual({ kind: "failed", code: "CORRUPT_METADATA" });
    const healthy = beginSpeechArchive("healthy legacy fixture");
    healthy.move("playing");
    await healthy.settled();
    unlinkSync(join(speechOpenIndex(), healthy.context.id));
    expect(await migrateLegacySpeechSlice()).toEqual({ more: false, recovered: [healthy.context.id] });
    expect(disk(healthy.context.path).speech).toMatchObject({ state: "interrupted", reason: "PROCESS_RESTART" });
    expect(readFileSync(join(bad, "metadata.json"), "utf8")).toBe(bytes);
    expect(readFileSync(join(root, ".speech-index-migration-v1"), "utf8")).toBe("done");
    expect(log).toHaveBeenCalled();
  } finally {
    process.env.QA_VOICE_RECORDINGS_DIR = original;
    log.mockRestore();
  }
});

test("R1C failed pause retries before later resume and completion writes", async () => {
  const archive = beginSpeechArchive("ordered retry fixture");
  archive.playerStarted();
  await archive.settled();
  const write = speechArchiveWriter.write.bind(speechArchiveWriter);
  const log = spyOn(console, "error").mockImplementation(() => {});
  let pausedFailures = 0;
  const fault = spyOn(speechArchiveWriter, "write").mockImplementation(async (...args) => {
    if (args[1].kind === "move" && args[1].to === "paused" && pausedFailures++ === 0) throw Error("synthetic pause failure");
    return write(...args);
  });
  try {
    archive.move("paused");
    await archive.settled();
    expect(archive.failures).toHaveLength(1);
    archive.playerStarted();
    archive.playerEnded();
    archive.finish("completed", "PLAYBACK_COMPLETED");
    await archive.settled();
  } finally { fault.mockRestore(); log.mockRestore(); }
  await archive.retryFailed();
  expect(archive.failures).toEqual([]);
  const speech = disk(archive.context.path).speech;
  expect(speech.state).toBe("completed");
  expect(speech.transitions.map((edge: { to: string }) => edge.to)).toEqual([
    "preparing", "playing", "paused", "playing", "completed",
  ]);
});

test("R1C R2 lasting invalid audio never blocks completed status or changes it on restart", async () => {
  const archive = beginSpeechArchive("lasting empty audio fixture");
  await archive.settled();
  const file = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `${archive.key}-empty.mp3`);
  writeFileSync(file, "");
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    archive.keepAudio(file, 1000);
    unlinkSpeechAudio(file);
    await archive.settled();
    expect(archive.failures).toHaveLength(1);
    archive.playerStarted();
    archive.playerEnded();
    archive.finish("completed", "PLAYBACK_COMPLETED");
    await archive.settled();
    expect(disk(archive.context.path).speech.state).toBe("completed");
    await archive.retryFailed();
    expect(archive.failures).toEqual([]);
    expect(log.mock.calls.flat().join(" ")).toContain("INVALID_INPUT");
    const speech = disk(archive.context.path).speech;
    expect(recoverSpeakArchive(archive.context.id).kind).toBe("stored");
    expect(disk(archive.context.path)).toMatchObject({ status: "completed", speech });
  } finally { log.mockRestore(); }
});

test("R1C R2 a new write retries a transient pause before resume without shutdown flush", async () => {
  const archive = beginSpeechArchive("automatic ordered retry fixture");
  archive.playerStarted();
  await archive.settled();
  const write = speechArchiveWriter.write.bind(speechArchiveWriter);
  let failures = 0;
  const fault = spyOn(speechArchiveWriter, "write").mockImplementation(async (...args) => {
    if (args[1].kind === "move" && args[1].to === "paused" && failures++ === 0) throw Error("IO_ERROR");
    return write(...args);
  });
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    archive.move("paused");
    await archive.settled();
    expect(archive.failures).toHaveLength(1);
    archive.playerStarted();
    archive.playerEnded();
    archive.finish("completed", "PLAYBACK_COMPLETED");
    await archive.settled();
    expect(archive.failures).toEqual([]);
    const speech = disk(archive.context.path).speech;
    expect(speech.state).toBe("completed");
    expect(speech.transitions.map((edge: { to: string }) => edge.to)).toEqual([
      "preparing", "playing", "paused", "playing", "completed",
    ]);
  } finally { fault.mockRestore(); log.mockRestore(); }
});

for (const kind of ["audio", "start", "end"] as const) test(`R1C R2 lasting transient ${kind} failure cannot block completed status`, async () => {
  const archive = beginSpeechArchive(`lasting ${kind} fixture`);
  archive.playerStarted();
  await archive.settled();
  const file = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `${archive.key}.mp3`);
  writeFileSync(file, "synthetic audio");
  const write = speechArchiveWriter.write.bind(speechArchiveWriter);
  const fault = spyOn(speechArchiveWriter, "write").mockImplementation(async (...args) => {
    if (args[1].kind === kind) throw Error("IO_ERROR");
    return write(...args);
  });
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    if (kind === "audio") archive.keepAudio(file, 1000);
    if (kind === "start") archive.playerStarted();
    archive.playerEnded();
    archive.finish("completed", "PLAYBACK_COMPLETED");
    await archive.settled();
    expect(disk(archive.context.path).speech.state).toBe("completed");
  } finally { fault.mockRestore(); log.mockRestore(); }
  await archive.retryFailed();
  expect(archive.failures).toEqual([]);
  expect(disk(archive.context.path).speech.state).toBe("completed");
});

for (const code of ["IO_ERROR", "WRITE_UNCERTAIN", "SYNC_UNCERTAIN"] as const) test(`R1C R2 legacy ${code} retains its cursor for the next boot`, async () => {
  const original = process.env.QA_VOICE_RECORDINGS_DIR;
  const root = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `legacy-transient-${code}`);
  mkdirSync(root, { mode: 0o700 });
  process.env.QA_VOICE_RECORDINGS_DIR = root;
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    const archive = beginSpeechArchive("transient migration fixture");
    archive.playerStarted();
    await archive.settled();
    unlinkSync(join(speechOpenIndex(), archive.context.id));
    const fault = spyOn(store, "recoverSpeakArchive").mockReturnValue({ kind: "failed", code });
    try {
      await expect(migrateLegacySpeechSlice()).rejects.toThrow("LEGACY_MIGRATION_DEFERRED");
      expect(readFileSync(join(root, ".speech-index-migration-v1"), "utf8")).toBe("");
      expect(disk(archive.context.path).speech.state).toBe("playing");
    } finally { fault.mockRestore(); }
    expect(await migrateLegacySpeechSlice()).toEqual({ more: false, recovered: [archive.context.id] });
    expect(disk(archive.context.path).speech.state).toBe("interrupted");
    expect(readFileSync(join(root, ".speech-index-migration-v1"), "utf8")).toBe("done");
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = original; log.mockRestore(); }
});

test("R1C R2 unreadable legacy metadata is recovered by the next boot instead of skipped", async () => {
  const original = process.env.QA_VOICE_RECORDINGS_DIR;
  const root = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "legacy-unreadable-metadata");
  mkdirSync(root, { mode: 0o700 });
  process.env.QA_VOICE_RECORDINGS_DIR = root;
  try {
    const archive = beginSpeechArchive("unreadable legacy fixture");
    archive.playerStarted();
    await archive.settled();
    unlinkSync(join(speechOpenIndex(), archive.context.id));
    const metadata = join(archive.context.path, "metadata.json");
    const saved = join(archive.context.path, "fixture-metadata.backup");
    renameSync(metadata, saved);
    mkdirSync(metadata, { mode: 0o700 });
    try {
      await recoverSpeechArchives();
      expect(readFileSync(join(root, ".speech-index-migration-v1"), "utf8")).toBe("");
    } finally { rmdirSync(metadata); renameSync(saved, metadata); }
    expect(disk(archive.context.path).speech.state).toBe("playing");
    await recoverSpeechArchives();
    expect(disk(archive.context.path).speech.state).toBe("interrupted");
    expect(readFileSync(join(root, ".speech-index-migration-v1"), "utf8")).toBe("done");
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = original; }
});

test("R1C S4 a newer move supersedes a pause that still fails after retry", async () => {
  const archive = beginSpeechArchive("superseded pause fixture");
  archive.playerStarted();
  await archive.settled();
  const write = speechArchiveWriter.write.bind(speechArchiveWriter);
  let pauseAttempts = 0;
  const fault = spyOn(speechArchiveWriter, "write").mockImplementation(async (...args) => {
    if (args[1].kind === "move" && args[1].to === "paused" && pauseAttempts++ < 2) throw Error("IO_ERROR");
    return write(...args);
  });
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    archive.move("paused");
    archive.playerStarted();
    archive.finish("completed", "PLAYBACK_COMPLETED");
    await archive.settled();
    expect(disk(archive.context.path).speech.state).toBe("completed");
    await archive.retryFailed();
    expect(disk(archive.context.path)).toMatchObject({ status: "completed", speech: { state: "completed" } });
    expect(archive.failures).toEqual([]);
    expect(log).toHaveBeenCalledWith("[speech] archive write superseded: move");
    expect(recoverSpeakArchive(archive.context.id).kind).toBe("stored");
    expect(disk(archive.context.path).speech.state).toBe("completed");
  } finally { fault.mockRestore(); log.mockRestore(); }
});

test("R1C S5 missing legacy metadata does not block a later healthy receipt", async () => {
  const original = process.env.QA_VOICE_RECORDINGS_DIR;
  const root = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "legacy-missing-metadata");
  mkdirSync(root, { mode: 0o700 });
  process.env.QA_VOICE_RECORDINGS_DIR = root;
  try {
    const missing = "2020-01-01T00-00-00-000Z-00000000";
    mkdirSync(join(root, "2020-01-01", missing), { recursive: true, mode: 0o700 });
    const archive = beginSpeechArchive("healthy legacy after missing metadata");
    archive.playerStarted();
    await archive.settled();
    unlinkSync(join(speechOpenIndex(), archive.context.id));
    expect(await migrateLegacySpeechSlice()).toEqual({ more: false, recovered: [archive.context.id] });
    expect(disk(archive.context.path).speech.state).toBe("interrupted");
    expect(readFileSync(join(root, ".speech-index-migration-v1"), "utf8")).toBe("done");
    for (let boot = 0; boot < 2; boot++) {
      expect(await migrateLegacySpeechSlice()).toEqual({ more: false, recovered: [] });
    }
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = original; }
});
