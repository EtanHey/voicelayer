import { afterEach, expect, spyOn, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { getPriority } from "node:os";
import { join } from "node:path";
import * as binaries from "../resolve-binary";
import * as recording from "../recording-state";
import { startCloneTiming } from "../tts/clone-timing";
import { projectSpeakableText } from "../speakable-text";
import { TEST_TMP } from "./setup/test-tmp";
import { recordingStateFilePath } from "../paths";
import * as fsPromises from "node:fs/promises";
import { writeFileSync } from "node:fs";

let directory: string, model: string | undefined, spy: ReturnType<typeof spyOn> | undefined;
let jobs: ReturnType<typeof startCloneTiming>[] = [], published = 0;
afterEach(async () => {
  for (const job of jobs) job.cancel(); await Promise.all(jobs.map(job => job.done)); jobs = [];
  spy?.mockRestore(); recording.setRecordingState("idle");
  if (model === undefined) delete process.env.QA_VOICE_WHISPER_MODEL; else process.env.QA_VOICE_WHISPER_MODEL = model;
  if (directory) await rm(directory, { recursive: true, force: true });
  expect(published).toBe(0); published = 0;
});
async function fixture() {
  directory = await mkdtemp(join(TEST_TMP, "timing-"));
  model = process.env.QA_VOICE_WHISPER_MODEL;
  process.env.QA_VOICE_WHISPER_MODEL = join(directory, "model");
  const converter = join(directory, "converter"), decoder = join(directory, "decoder"), audioPath = join(directory, "audio.mp3");
  await writeFile(process.env.QA_VOICE_WHISPER_MODEL, "stub"); await writeFile(audioPath, "owned fixture");
  await writeFile(converter, `#!${process.execPath}\nimport {copyFileSync,writeFileSync} from 'node:fs'; import {getPriority} from 'node:os';
const a=process.argv.slice(2); writeFileSync(${JSON.stringify(join(directory, "converter-priority"))},String(getPriority())); copyFileSync(a[a.indexOf('-i')+1],a.at(-1));`, { mode: 0o700 });
  await writeFile(decoder, `#!${process.execPath}\nimport {writeFileSync} from 'node:fs';
writeFileSync(${JSON.stringify(join(directory, "pid"))},String(process.pid)); setTimeout(()=>{},10000);`, { mode: 0o700 });
  spy = spyOn(binaries, "resolveBinaryAsync").mockImplementation(async name => name === "ffmpeg" ? converter : decoder);
  const input = { ...projectSpeakableText("Hello world"), audioPath, durationMs: 8000, requestId: "native", chunkId: "0" };
  const start = () => { const job = startCloneTiming(input, () => true, () => { published++; }); jobs.push(job); return job; };
  const pid = async () => {
    for (let i = 0; i < 500; i++) {
      try { const text = (await readFile(join(directory, "pid"), "utf8")).trim(), pid = Number(text); if (text && Number.isSafeInteger(pid) && pid > 0) return pid; } catch {}
      await Bun.sleep(5);
    }
    throw new Error("native decoder did not start");
  };
  return { start, pid, converter, decoder };
}
for (const phase of ["converter", "decoder"] as const) test(`R2 admission rechecks persisted busy state immediately before ${phase}`, async () => {
  const f = await fixture(), spawned: string[] = [], originalWrite = fsPromises.writeFile;
  const busy = () => writeFileSync(recordingStateFilePath(), JSON.stringify({ state: "transcribing", pid: process.pid, updated_at: new Date().toISOString() }));
  // No poll is allowed to run: admission itself must catch this interleaving.
  const poll = spyOn(globalThis, "setInterval").mockImplementation(() => ({ unref() {} }) as any);
  const write = spyOn(fsPromises, "writeFile").mockImplementation(async (...args: any[]) => {
    await (originalWrite as any)(...args);
    if (phase === "converter" && String(args[0]).includes("vl-cln1a-") && String(args[0]).endsWith("audio.mp3")) busy();
  });
  const spawn = spyOn(Bun, "spawn").mockImplementation((argv: any) => {
    const kind = argv.includes(f.converter) ? "converter" : "decoder"; spawned.push(kind);
    return { exitCode: 0, exited: Promise.resolve().then(() => { if (phase === "decoder" && kind === "converter") busy(); return 0; }), kill() {} } as any;
  });
  try { await f.start().done; expect(spawned).toEqual(phase === "converter" ? [] : ["converter"]); }
  finally { spawn.mockRestore(); write.mockRestore(); poll.mockRestore(); }
});
test("R2 native PID readiness waits past an empty file", async () => {
  const f = await fixture(), file = join(directory, "pid"); await writeFile(file, "");
  const ready = Bun.sleep(10).then(() => writeFile(file, String(process.pid)));
  try { expect(await f.pid()).toBe(process.pid); } finally { await ready; }
});
test("busy dictation defers alignment without resolving or spawning a decoder", async () => {
  const f = await fixture(); recording.setRecordingState("transcribing");
  await f.start().done; expect(spy).not.toHaveBeenCalled();
});
for (const state of ["cancel", "recording", "transcribing", "external"] as const)
  test(`native background children run nice 19 and are reaped on ${state}`, async () => {
    const f = await fixture(), job = f.start(), pid = await f.pid();
    expect(await readFile(join(directory, "converter-priority"), "utf8")).toBe("19");
    expect(getPriority(pid)).toBe(19);
    if (state === "cancel") job.cancel();
    else if (state === "external") await writeFile(recordingStateFilePath(), JSON.stringify({ state: "transcribing", pid: process.pid, updated_at: new Date().toISOString() }));
    else recording.setRecordingState(state);
    await job.done; expect(() => process.kill(pid, 0)).toThrow();
  }, 10000);
test("native replacement decoder starts only after cancelled child is reaped", async () => {
  const f = await fixture(), first = f.start(), pid = await f.pid();
  const second = f.start(); await Bun.sleep(25);
  expect(Number(await readFile(join(directory, "pid"), "utf8"))).toBe(pid);
  await rm(join(directory, "pid")); first.cancel(); await first.done;
  const nextPid = await f.pid(); expect(nextPid).not.toBe(pid);
  expect(() => process.kill(pid, 0)).toThrow(); second.cancel(); await second.done;
}, 10000);
