import { expect, test, spyOn } from "bun:test";
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { beginSpeechArchive } from "../speech-archive-live";
import { migrateLegacySpeechSlice } from "../speech-archive-legacy-migration";
import { speechArchiveWriter } from "../speech-archive-writer";
import { speechOpenIndex } from "../speech-open-index";
import { recoverSpeakArchive } from "../speak-archive-store";

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
  const fault = spyOn(speechArchiveWriter, "write").mockImplementation(async (...args) => {
    if (args[1].kind === "move" && args[1].to === "paused") throw Error("synthetic pause failure");
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
