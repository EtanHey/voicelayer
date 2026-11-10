// A stop without a take id is a speech/playback stop. It never ends a VoiceBar dictation take
// (Etan, 2026-11-08: "Recording right after a recording breaks; it's consistent").
// Real socket handler and capture code; only the recorder child is the preload's silence stub.
import { afterEach, expect, it, spyOn } from "bun:test";
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { randomUUID } from "node:crypto";
import { chmodSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import * as stt from "../stt";
import * as socket from "../socket-client";
import * as captureTrace from "../capture-lifecycle";
import { handleSocketCommand } from "../socket-handlers";
import { setRecordingState } from "../recording-state";
import { recordingJobsSnapshot } from "../recording-jobs";
import { clearStopSignal, clearCancelSignal } from "../session-booking";
import type { SocketEvent } from "../socket-protocol";

async function until(predicate: () => boolean, label: string, limitMs = 5_000) {
  const deadline = Date.now() + limitMs;
  while (Date.now() < deadline) { if (predicate()) return; await Bun.sleep(5); }
  throw new Error(`isolated runtime did not reach: ${label}`);
}
function archivedWavs(since: number): Array<{ path: string; bytes: number }> {
  const root = process.env.QA_VOICE_RECORDINGS_DIR!;
  const found: Array<{ path: string; bytes: number }> = [];
  const walk = (dir: string) => {
    let entries: string[] = [];
    try { entries = readdirSync(dir); } catch { return; }
    for (const name of entries) {
      const path = join(dir, name);
      const stat = statSync(path);
      if (stat.isDirectory()) walk(path);
      else if (name === "audio.wav" && stat.mtimeMs >= since) found.push({ path, bytes: stat.size });
    }
  };
  walk(root);
  return found;
}

const spies: Array<{ mockRestore(): void }> = [];
const savedRecorder = process.env.VOICELAYER_TEST_FAKE_REC_BIN;
afterEach(async () => {
  await until(() => recordingJobsSnapshot().recording_jobs.length === 0, "jobs settled", 10_000).catch(() => {});
  for (const spy of spies.splice(0).reverse()) spy.mockRestore();
  process.env.VOICELAYER_TEST_FAKE_REC_BIN = savedRecorder;
  clearStopSignal(); clearCancelSignal();
  expect(recordingJobsSnapshot().recording_jobs).toEqual([]);
  setRecordingState("idle");
});

function harness() {
  const events: SocketEvent[] = [];
  spies.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(event); }));
  spies.push(spyOn(stt, "getBackend").mockResolvedValue({ name: "synthetic", isAvailable: async () => true,
    transcribe: async () => ({ text: "", backend: "synthetic", durationMs: 0 }) }));
  const captured = (take: string) => events.some(e => e.type === "state" && e.take_id === take && e.capture_id !== undefined);
  return { events, captured };
}
async function startTake(take: string) {
  expect(await handleSocketCommand({ cmd: "record", id: randomUUID(), take_id: take, press_to_talk: true }))
    .toMatchObject({ outcome: "accept" });
}
async function stopTake(take: string) {
  expect(await handleSocketCommand({ cmd: "stop", take_id: take, physical_press: true })).toMatchObject({ outcome: "accept" });
  await until(() => recordingJobsSnapshot().recording_jobs.length === 0, "take settled", 10_000);
}

describe("bare stop scoping (isolated fake recorder, never real mic)", () => {
  for (const bare of [{ cmd: "stop" }, { cmd: "stop", physical_press: true }, { cmd: "stop", scope: "capture" }] as const) {
    it(`${JSON.stringify(bare)} while a dictation take is capturing leaves the take recording`, async () => {
      const { captured } = harness();
      const take = randomUUID();
      await startTake(take);
      await until(() => captured(take), "capture state");
      await handleSocketCommand(bare as never);
      await Bun.sleep(600);
      expect(recordingJobsSnapshot().mic_take_id).toBe(take);
      await stopTake(take);
    });

    it(`${JSON.stringify(bare)} while a dictation take is opening leaves the take recording`, async () => {
      const { captured } = harness();
      const take = randomUUID();
      await startTake(take);
      // The incident window: the stop lands 18-30 ms after VoiceBar entered recording, before the mic opened.
      expect(captured(take)).toBe(false);
      await handleSocketCommand(bare as never);
      await until(() => captured(take), "capture state");
      await Bun.sleep(600);
      expect(recordingJobsSnapshot().mic_take_id).toBe(take);
      await stopTake(take);
    });
  }

  it("a scoped stop for the opening take still applies once the mic opens", async () => {
    const { captured } = harness();
    const take = randomUUID();
    await startTake(take);
    expect(captured(take)).toBe(false);
    expect(await handleSocketCommand({ cmd: "stop", take_id: take, physical_press: true })).toMatchObject({ outcome: "accept" });
    await until(() => recordingJobsSnapshot().recording_jobs.length === 0, "take settled", 10_000);
  });

  it("a bare stop for another take id never reaches the opening take", async () => {
    const { captured } = harness();
    const take = randomUUID();
    await startTake(take);
    expect(await handleSocketCommand({ cmd: "stop", take_id: randomUUID() })).toMatchObject({ outcome: "noop" });
    await until(() => captured(take), "capture state");
    await Bun.sleep(600);
    expect(recordingJobsSnapshot().mic_take_id).toBe(take);
    await stopTake(take);
  });

  it("reproduces the 44-byte archive: a bare stop on a slow-opening mic must not leave a header-only take", async () => {
    const recorder = join(process.cwd(), "src", "__tests__", "setup", "fake-rec-slow-open.sh");
    chmodSync(recorder, 0o755);
    process.env.VOICELAYER_TEST_FAKE_REC_BIN = recorder;
    harness();
    const since = Date.now() - 1;
    const take = randomUUID();
    let firstPCM = false;
    const trace = captureTrace.captureLifecycle;
    spies.push(spyOn(captureTrace, "captureLifecycle").mockImplementation((event, fields) => {
      trace(event, fields);
      if (event === "first-pcm" && fields.take_id === take) firstPCM = true;
    }));
    try {
      await startTake(take);
      await Bun.sleep(20);
      await handleSocketCommand({ cmd: "stop" });
      // Capture state precedes PCM. Under load, startup can outlast the old 900 ms
      // sleep; our own scoped stop would then create the header-only WAV.
      await until(() => firstPCM, "first PCM for the slow-opening take", 15_000);
      const survived = recordingJobsSnapshot().mic_take_id === take;
      if (survived) await stopTake(take);
      else await until(() => recordingJobsSnapshot().recording_jobs.length === 0, "killed take settled", 10_000);
      const wavs = archivedWavs(since);
      expect(wavs).toHaveLength(1);
      // 44 bytes is the WAV header with zero PCM frames: Etan's two incident takes.
      expect(wavs[0].bytes).toBeGreaterThan(44);
      expect(survived).toBe(true);
    } finally {
      // A failed PCM barrier must still settle this test's recorder before restoring spies.
      if (recordingJobsSnapshot().mic_take_id === take) await stopTake(take);
    }
  }, 30_000);
});
