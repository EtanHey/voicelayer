import { expect, test, spyOn } from "bun:test";
import { readFileSync, writeFileSync, unlinkSync } from "fs";
import { join } from "path";
import { beginSpeechArchive, recoverSpeechArchives } from "../speech-archive-live";
import { transitionSpeakArchive } from "../speak-archive-store";
const disk = (path: string) => JSON.parse(readFileSync(join(path, "metadata.json"), "utf8"));
for (const terminal of ["completed", "stopped", "cancelled", "failed"] as const) {
  test(`durable ${terminal} preserves original, actual input and audio`, () => {
    expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
    const archive = beginSpeechArchive("  **original**\n");
    const file = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `${archive.context.id}.mp3`);
    writeFileSync(file, "synthetic audio");
    archive.generated(file, "actual engine input", "fixture voice", "long", "fixture engine");
    unlinkSync(file);
    archive.move("playing"); archive.move("paused"); archive.move("playing");
    archive.finish(terminal, "FIXTURE_REASON");
    const metadata = disk(archive.context.path);
    expect(metadata.speech).toMatchObject({ state: terminal, reason: "FIXTURE_REASON", generated: [
      { text: "actual engine input", voice: "fixture voice", profile: "long", engine: "fixture engine" }] });
    expect(readFileSync(join(archive.context.path, "input.txt"), "utf8")).toBe("  **original**\n");
    expect(readFileSync(join(archive.context.path, metadata.speech.generated[0].audio_path), "utf8")).toBe("synthetic audio");
    expect(transitionSpeakArchive(archive.context, "preparing")).toEqual({ kind: "failed", code: "CONFLICT" });
    recoverSpeechArchives();
    expect(disk(archive.context.path).speech.state).toBe(terminal);
  });
}
test("restart recovers preparing, playing and paused as interrupted", () => {
  for (const state of ["preparing", "playing", "paused"] as const) {
    const archive = beginSpeechArchive(`fixture ${state}`);
    if (state !== "preparing") archive.move(state);
    recoverSpeechArchives();
    expect(disk(archive.context.path).speech).toMatchObject({ state: "interrupted", reason: "PROCESS_RESTART" });
    const before = readFileSync(join(archive.context.path, "metadata.json"), "utf8");
    recoverSpeechArchives();
    expect(readFileSync(join(archive.context.path, "metadata.json"), "utf8")).toBe(before);
  }
});

test("player segments exclude synthesis gaps and paused time", () => {
  const archive = beginSpeechArchive("timing fixture");
  archive.playerStarted();
  const first = disk(archive.context.path).speech.playing_since;
  const now = spyOn(Date, "now").mockReturnValue(Date.parse(first) + 1000);
  try { archive.playerEnded(); } finally { now.mockRestore(); }
  expect(disk(archive.context.path).speech.played_ms).toBe(1000);
  expect(disk(archive.context.path).speech.playing_since).toBeNull();
  archive.playerStarted();
  const second = disk(archive.context.path).speech.playing_since;
  const later = spyOn(Date, "now").mockReturnValue(Date.parse(second) + 500);
  try { archive.playerEnded(); } finally { later.mockRestore(); }
  archive.finish("completed", "PLAYBACK_COMPLETED");
  expect(disk(archive.context.path).speech.played_ms).toBe(1500);
});
