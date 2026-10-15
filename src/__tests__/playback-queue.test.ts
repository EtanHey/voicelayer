/**
 * P0-1 playback queue tests + P0-2 awaitCurrentPlayback queue awareness.
 *
 * TDD RED phase: tests define desired behavior that doesn't exist yet.
 *
 * P0-1: voice_speak audio overlap — rapid calls must queue, not overlap.
 *        Speaking broadcast must be tied to actual playback start.
 *        Idle broadcast only fires when queue fully drains.
 *
 * P0-2: awaitCurrentPlayback must wait for full queue, not just current item.
 *        This prevents voice_ask from starting recording while queued audio
 *        is still pending.
 */

import { it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import { TEST_TMP } from "./setup/test-tmp";
// AIDEV-NOTE: R-014 — this file can reach the microphone, the recorder
// device probe, or files the resident VoiceBar reads. `describe` is the
// live-host guard, so the suite skips loudly rather than racing the live app.
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { existsSync, unlinkSync, writeFileSync } from "fs";
import * as recordingState from "../recording-state";
import * as socketClient from "../socket-client";
import * as tts from "../tts";
import * as input from "../input";
import * as booking from "../session-booking";
import { handleVoiceAsk } from "../handlers";

// --- Mock helpers ---

interface MockPlayer {
  cmd: string[];
  resolveExit: () => void;
  exitedSettled?: boolean;
}

interface MockDecoder {
  killed: boolean;
  exited: Promise<number>;
  resolveExit: () => void;
}

async function waitFor(
  predicate: () => boolean,
  description: string,
  timeoutMs = 1_000,
): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) {
      throw new Error(`Timed out waiting for ${description}`);
    }
    await Bun.sleep(1);
  }
}

function pcm16(samples: number[]): Uint8Array {
  const bytes = new Uint8Array(samples.length * 2);
  const view = new DataView(bytes.buffer);
  samples.forEach((sample, index) => view.setInt16(index * 2, sample, true));
  return bytes;
}

const TEST_RECORDING_STATE_FILE = `${TEST_TMP}/voicelayer-playback-queue-state-${process.pid}.json`;
const SPEAKER_REFUSED = "user is recording — speaker output refused";

function writeRecordingState(state: "idle" | "recording" | "transcribing") {
  writeFileSync(
    TEST_RECORDING_STATE_FILE,
    JSON.stringify({
      state,
      pid: process.pid,
      updated_at: new Date().toISOString(),
    }),
  );
}

function cleanupRecordingState() {
  try {
    if (existsSync(TEST_RECORDING_STATE_FILE)) {
      unlinkSync(TEST_RECORDING_STATE_FILE);
    }
  } catch {}
}

describe("playback queue — P0-1 sequential playback", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;
  let broadcasts: unknown[];
  let playerMocks: MockPlayer[];
  const originalSpawn = Bun.spawn;
  const originalSpawnSync = Bun.spawnSync;
  let originalRecordingStatePath: string | undefined;
  let decodeSucceeds: boolean;
  let speakingSpawnCounts: number[];
  let queueEvents: string[];
  let decoderMocks: MockDecoder[];
  let holdDecoderExits: boolean;
  let holdKilledDecoderExits: boolean;
  let synchronousDecodeCount: number;
  let decoderSpawnOptions: unknown;

  beforeEach(async () => {
    originalRecordingStatePath = process.env.QA_VOICE_RECORDING_STATE_PATH;
    process.env.QA_VOICE_RECORDING_STATE_PATH = TEST_RECORDING_STATE_FILE;
    writeRecordingState("idle");

    try {
      const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
      stopPlayback();
      await awaitCurrentPlayback();
    } catch {}

    broadcasts = [];
    playerMocks = [];
    decodeSucceeds = true;
    speakingSpawnCounts = [];
    queueEvents = [];
    decoderMocks = [];
    holdDecoderExits = false;
    holdKilledDecoderExits = false;
    synchronousDecodeCount = 0;
    decoderSpawnOptions = undefined;

    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      (event: unknown) => {
        if ((event as any).type === "state" && (event as any).state === "speaking") {
          speakingSpawnCounts.push(playerMocks.length);
        }
        broadcasts.push(JSON.parse(JSON.stringify(event)));
      },
    );

    // @ts-ignore — mock Bun.spawnSync for getAudioPlayer + ffprobe
    Bun.spawnSync = (cmd: string[]) => {
      if (cmd[0] === "which" && ["ffmpeg", "ffprobe"].includes(cmd[1])) return {exitCode: 0, stdout: Buffer.from(`${cmd[1]}\n`), stderr: Buffer.alloc(0)};
      if (cmd[1] === "-version") return {exitCode: ["ffmpeg", "ffprobe"].includes(cmd[0]) ? 0 : 1, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0)};
      if (Array.isArray(cmd) && cmd[0] === "which") {
        return {
          exitCode: 1,
          stdout: new Uint8Array(0),
          stderr: new Uint8Array(0),
        };
      }
      if (Array.isArray(cmd) && cmd[0] === "ffprobe") {
        return {
          exitCode: 0,
          stdout: Buffer.from("1.0\n"),
          stderr: new Uint8Array(0),
        };
      }
      if (Array.isArray(cmd) && cmd[0] === "ffmpeg") {
        synchronousDecodeCount += 1;
        const inputIndex = cmd.indexOf("-i");
        queueEvents.push(`decode:${cmd[inputIndex + 1]}`);
        const samples = [
          ...Array(50).fill(1000),
          ...Array(50).fill(8000),
        ];
        return {
          exitCode: decodeSucceeds ? 0 : 1,
          stdout: decodeSucceeds ? pcm16(samples) : new Uint8Array(0),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSync(cmd);
    };

    // @ts-ignore — mock Bun.spawn: audio players are controllable
    Bun.spawn = (cmd: string[], opts?: unknown) => {
      if (cmd[0] === "which" && cmd[1] === "ffmpeg") return {pid: 89990, exited: Promise.resolve(0), stdout: new Blob(["ffmpeg\n"]).stream(), kill() {}};
      if (cmd[1] === "-version") return {pid: 89991, exited: Promise.resolve(cmd[0] === "ffmpeg" ? 0 : 1), kill() {}};
      const cmdArray = Array.isArray(cmd) ? [...cmd] : [String(cmd)];
      if (cmdArray[0] === "ffmpeg") {
        decoderSpawnOptions = opts;
        const inputIndex = cmdArray.indexOf("-i");
        queueEvents.push(`decode:${cmdArray[inputIndex + 1]}`);
        const samples = [
          ...Array(50).fill(1000),
          ...Array(50).fill(8000),
        ];
        let resolveExit!: () => void;
        const exited = new Promise<number>((resolve) => {
          resolveExit = () => resolve(decodeSucceeds ? 0 : 1);
        });
        const decoder = { killed: false, exited, resolveExit };
        decoderMocks.push(decoder);
        if (!holdDecoderExits) queueMicrotask(resolveExit);
        return {
          exited,
          pid: 98000 + decoderMocks.length,
          stdout: new Blob([
            decodeSucceeds ? pcm16(samples) : new Uint8Array(),
          ]).stream(),
          kill: () => {
            decoder.killed = true;
            if (!holdKilledDecoderExits) resolveExit();
          },
        };
      }
      let resolveExit!: () => void;
      const exited = new Promise<number>((r) => {
        resolveExit = () => r(0);
      });
      const player = { cmd: cmdArray, exitedSettled: false, resolveExit: () => { player.exitedSettled = true; resolveExit(); } };
      playerMocks.push(player);
      return {
        exited,
        pid: 99000 + playerMocks.length,
        kill: () => queueEvents.push(`kill:${cmdArray.at(-1)}`),
      };
    };
  });

  afterEach(async () => {
    for (const decoder of decoderMocks) decoder.resolveExit();
    // Drain queue before restoring spawn
    for (let i = 0; i < playerMocks.length; i++) {
      try {
        playerMocks[i].resolveExit();
      } catch {}
    }
    await Bun.sleep(100);
    for (let i = 0; i < playerMocks.length; i++) {
      try {
        playerMocks[i].resolveExit();
      } catch {}
    }
    await Bun.sleep(50);
    try {
      const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
      stopPlayback();
      await awaitCurrentPlayback();
    } catch {}

    broadcastSpy.mockRestore();
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
    cleanupRecordingState();
    if (originalRecordingStatePath === undefined) {
      delete process.env.QA_VOICE_RECORDING_STATE_PATH;
    } else {
      process.env.QA_VOICE_RECORDING_STATE_PATH = originalRecordingStatePath;
    }
  });

  function askOnRealQueue(beforeQueue?: Promise<void>, afterPrompt?: Promise<void>) {
    const capture = Promise.withResolvers<string>();
    let prompt: ReturnType<typeof tts.playAudioNonBlocking> | undefined;
    const spies = [
      spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true } as any),
      spyOn(booking, "clearStopSignal").mockImplementation(() => {}),
      spyOn(input, "clearInput").mockImplementation(() => {}),
      spyOn(tts, "speak").mockImplementation(async (_text, options) => {
        if (beforeQueue) await beforeQueue;
        prompt = tts.playAudioNonBlocking(`${TEST_TMP}/fx1-prompt.mp3`, {
          text: "Question", voice: "fixture", priority: "critical", durationMs: 1_000, nextState: "recording",
          onQueued: options?.onPlaybackQueued,
        });
        const playbackOutcome = await prompt.exited;
        if (afterPrompt) await afterPrompt;
        return { displayText: "Question", engine: "edge-tts", voice: "fixture", playbackOutcome,
          audioArtifact: { bytes: new Uint8Array([1]), format: "mp3" } };
      }),
    ];
    const captureSpy = spyOn(input, "waitForInput").mockImplementation(() => capture.promise);
    spies.push(captureSpy);
    const request = handleVoiceAsk({ message: "Question", timeout_seconds: 30 });
    return { request, capture, captureSpy, clearSpy: spies[2], get prompt() { return prompt!; }, async dispose() {
      await Bun.sleep(0);
      for (const decoder of decoderMocks) decoder.resolveExit();
      for (const player of playerMocks) player.resolveExit();
      capture.resolve("raw answer"); await request;
      await Bun.sleep(0);
      for (const player of playerMocks) player.resolveExit();
      for (const spy of spies.reverse()) spy.mockRestore();
    } };
  }

  function controlAskDeadlines() {
    const native = globalThis.setTimeout, deadlines = new Map<number, () => void>();
    const spy = spyOn(globalThis, "setTimeout").mockImplementation(((fn, ms, ...args) => {
      const timer = native(fn, ms, ...args);
      if (ms === 180_000 || ms === 5_000) deadlines.set(ms, () => { clearTimeout(timer); fn(...args); });
      return timer;
    }) as typeof setTimeout);
    return { fire: (ms: number) => {
      const expire = deadlines.get(ms); expect(expire).toBeFunction(); expire!();
    }, restore: () => spy.mockRestore() };
  }

  for (const stallBackend of [false, true]) {
  it(`FX-1 ${stallBackend ? "stalled" : "normal"} prompt timeout releases admission within the cleanup bound while retry waits for physical exit`, async () => {
    const deadlines = controlAskDeadlines(), stalled = Promise.withResolvers<void>();
    const ask = askOnRealQueue(undefined, stallBackend ? stalled.promise : undefined);
    let returned = false; void ask.request.then(() => { returned = true; });
    let retry: ReturnType<typeof handleVoiceAsk> | undefined;
    try {
      await waitFor(() => playerMocks.length === 1, "timed-out prompt");
      const foreign = tts.playAudioNonBlocking(`${TEST_TMP}/fx1-timeout-foreign.mp3`);
      deadlines.fire(180_000); await Bun.sleep(10);
      expect(returned).toBe(false); deadlines.fire(5_000);
      expect((await ask.request).isError).toBe(true);
      expect((await ask.request).content[0].text).toContain("Hard timeout during prompt stage");
      expect(tts.isCaptureAdmissionReserved()).toBe(false);
      expect((await ask.prompt.exited).reason).toBe("stopped");
      retry = handleVoiceAsk({ message: "Retry question" });
      await Bun.sleep(10);
      expect(playerMocks).toHaveLength(1);
      expect(ask.captureSpy).not.toHaveBeenCalled();
      stalled.resolve(); playerMocks[0].resolveExit();
      await waitFor(() => playerMocks.length === 2, "preserved foreign speech");
      expect(playerMocks[1].cmd).toContain(`${TEST_TMP}/fx1-timeout-foreign.mp3`);
      playerMocks[1].resolveExit(); await foreign.exited;
      await waitFor(() => playerMocks.length === 3, "retry prompt after reap");
      playerMocks[2].resolveExit();
      await waitFor(() => ask.captureSpy.mock.calls.length === 1, "retry capture");
      ask.capture.resolve("raw retry answer"); expect((await retry).isError).toBeUndefined();
    } finally { stalled.resolve(); await ask.dispose(); await retry; deadlines.restore(); }
  });

  }

  for (const completion of ["exit", "seek", "seek-decoder", "stop", "cancel", "cancel-decoder"] as const) {
    it(`FX-1.1 quiet Ask ${completion} emits only its validated playback idle after reap`, async () => {
      const duringDecode = completion.endsWith("-decoder");
      holdDecoderExits = duringDecode; holdKilledDecoderExits = duringDecode;
      const ask = askOnRealQueue();
      try {
        await waitFor(() => duringDecode ? decoderMocks.length === 1 : playerMocks.length === 1, "owned child");
        if (completion.startsWith("seek")) expect(tts.seekPlayback(1_000).outcome).toBe("accept");
        if (completion === "stop") expect(tts.stopPlayback()).toBe(true);
        if (completion.startsWith("cancel")) expect(tts.cancelPlayback({ id: ask.prompt.id })).toBe(true);
        await Bun.sleep(10); expect(ask.captureSpy).not.toHaveBeenCalled();
        expect(broadcasts.filter((event: any) => event.type === "state" && event.state === "idle")).toHaveLength(0);
        if (duringDecode) decoderMocks[0].resolveExit(); else playerMocks[0].resolveExit();
        await waitFor(() => ask.captureSpy.mock.calls.length === 1, "capture after reap");
        expect(broadcasts.filter((event: any) => event.type === "state" && event.state === "idle")).toEqual([
          { type: "state", state: "idle", source: "playback", next_state: "recording" },
        ]);
      } finally { await ask.dispose(); }
    });
  }

  it("FX-1 endpoint seek after prompt timeout cannot emit a stale recording hint", async () => {
    const deadlines = controlAskDeadlines(), stalled = Promise.withResolvers<void>();
    const ask = askOnRealQueue(undefined, stalled.promise);
    try {
      await waitFor(() => playerMocks.length === 1, "expired seek prompt");
      deadlines.fire(180_000); await Bun.sleep(0); deadlines.fire(5_000);
      expect((await ask.request).isError).toBe(true);
      tts.seekPlayback(1_000); playerMocks[0].resolveExit(); await Bun.sleep(10);
      expect(ask.captureSpy).not.toHaveBeenCalled();
      expect(broadcasts.filter((event: any) => event.next_state === "recording")).toHaveLength(0);
    } finally { stalled.resolve(); await ask.dispose(); deadlines.restore(); }
  });

  it("FX-1 timed-out synthesis releases admission and rejects its late queued player", async () => {
    const synthesis = Promise.withResolvers<void>(), deadlines = controlAskDeadlines();
    const ask = askOnRealQueue(synthesis.promise);
    try {
      await Bun.sleep(0); deadlines.fire(180_000);
      expect((await ask.request).isError).toBe(true);
      const foreign = tts.playAudioNonBlocking(`${TEST_TMP}/fx1-after-timeout.mp3`);
      expect(playerMocks).toHaveLength(1);
      synthesis.resolve(); await Bun.sleep(0);
      expect(playerMocks).toHaveLength(1);
      expect(ask.captureSpy).not.toHaveBeenCalled();
      playerMocks[0].resolveExit(); await foreign.exited;
    } finally { synthesis.resolve(); await ask.dispose(); deadlines.restore(); }
  });

  it("FX-1 a second Ask cannot clear an active Ask's input", async () => {
    const ask = askOnRealQueue();
    try {
      await waitFor(() => playerMocks.length === 1, "prompt"); playerMocks[0].resolveExit();
      await waitFor(() => ask.captureSpy.mock.calls.length === 1, "capture");
      const second = await handleVoiceAsk({ message: "Another question" });
      expect(second.isError).toBe(true);
      expect(ask.clearSpy).toHaveBeenCalledTimes(1);
      expect(ask.captureSpy).toHaveBeenCalledTimes(1);
    } finally { await ask.dispose(); }
  });

  it("FX-1 an already recording user is refused before clearing input", async () => {
    writeRecordingState("recording");
    const ask = askOnRealQueue();
    try {
      expect((await ask.request).isError).toBe(true);
      expect(ask.clearSpy).not.toHaveBeenCalled();
      expect(ask.captureSpy).not.toHaveBeenCalled();
    } finally { await ask.dispose(); }
  });

  for (const priority of ["normal", "critical"] as const) {
  it(`FX-1 real queue reserves the prompt-to-capture gap and preserves ${priority} speech`, async () => {
    const ask = askOnRealQueue();
    try {
      await waitFor(() => playerMocks.length === 1, "prompt");
      const foreign = tts.playAudioNonBlocking(`${TEST_TMP}/fx1-foreign.mp3`, { text: "Other agent", voice: "fixture", priority });
      playerMocks[0].resolveExit();
      await waitFor(() => ask.captureSpy.mock.calls.length === 1, "capture admission");
      await Bun.sleep(10);
      expect(playerMocks.filter(player => !player.exitedSettled)).toHaveLength(0);
      expect(queueEvents).not.toContain(`decode:${TEST_TMP}/fx1-foreign.mp3`);
      expect(playerMocks).toHaveLength(1);
      expect(broadcasts).toContainEqual({ type: "state", state: "idle", source: "playback", next_state: "recording" });
      ask.capture.resolve("raw answer"); await ask.request;
      await waitFor(() => playerMocks.length === 2, "preserved speech after capture");
      expect(playerMocks[1].cmd).toContain(`${TEST_TMP}/fx1-foreign.mp3`);
      playerMocks[1].resolveExit(); expect((await foreign.exited).status).toBe("completed");
    } finally { await ask.dispose(); }
  });
  }

  it("FX-1 an unconfirmed exit fails within its own bound without capture or a late handoff", async () => {
    const deadlines = controlAskDeadlines();
    const ask = askOnRealQueue();
    try {
      await waitFor(() => playerMocks.length === 1, "prompt");
      tts.cancelPlayback({ id: ask.prompt.id });
      await Bun.sleep(10);
      deadlines.fire(5_000);
      const result = await ask.request;
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("exit");
      expect(ask.captureSpy).not.toHaveBeenCalled();
      expect(broadcasts.filter((event: any) => event.type === "state" && event.state === "idle")).toEqual([
        { type: "state", state: "idle" },
      ]);
      const before = broadcasts.length; playerMocks[0].resolveExit(); await Bun.sleep(10);
      expect(broadcasts.slice(before).some((event: any) => event.next_state === "recording")).toBe(false);
    } finally { await ask.dispose(); deadlines.restore(); }
  });

  it("times out polling independently of the mocked playback clock", async () => {
    const nowSpy = spyOn(Date, "now").mockReturnValue(10_000);
    const polling = waitFor(() => false, "mocked-clock polling", 20).then(
      () => "resolved",
      (error: Error) => error.message,
    );
    let firstOutcome: string;
    try {
      firstOutcome = await Promise.race([
        polling,
        Bun.sleep(100).then(() => "hung"),
      ]);
    } finally {
      nowSpy.mockRestore();
    }
    await polling;

    expect(firstOutcome).toBe("Timed out waiting for mocked-clock polling");
  });

  it("plays audio files sequentially — second spawns only after first finishes", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    playAudioNonBlocking(`${TEST_TMP}/pq-seq1.mp3`);
    playAudioNonBlocking(`${TEST_TMP}/pq-seq2.mp3`);

    await Bun.sleep(50);

    // Only first player should be spawned (queue serializes)
    expect(playerMocks.length).toBe(1);
    expect(playerMocks[0].cmd).toContain(`${TEST_TMP}/pq-seq1.mp3`);

    // Finish first playback
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    // Now second player should be spawned
    expect(playerMocks.length).toBe(2);
    expect(playerMocks[1].cmd).toContain(`${TEST_TMP}/pq-seq2.mp3`);

    // Finish second
    playerMocks[1].resolveExit();
    await Bun.sleep(50);
  });

  it("waits for killed playback to exit and collapses rapid restart attempts", async () => {
    const { playAudioNonBlocking, stopPlayback } = await import("../tts");

    playAudioNonBlocking(`${TEST_TMP}/pq-replay-original.mp3`);
    await waitFor(() => playerMocks.length === 1, "original player creation");

    stopPlayback();
    playAudioNonBlocking(`${TEST_TMP}/pq-replay-superseded.mp3`);
    stopPlayback();
    playAudioNonBlocking(`${TEST_TMP}/pq-replay-final.mp3`);

    // SIGTERM is asynchronous. A replacement must not spawn while the old
    // afplay process is still alive, even across rapid repeated Replay clicks.
    expect(playerMocks).toHaveLength(1);

    playerMocks[0].resolveExit();
    await waitFor(() => playerMocks.length === 2, "final replay player creation");

    expect(playerMocks[1].cmd).toContain(`${TEST_TMP}/pq-replay-final.mp3`);
    expect(
      playerMocks.some((player) =>
        player.cmd.includes(`${TEST_TMP}/pq-replay-superseded.mp3`),
      ),
    ).toBe(false);

    playerMocks[1].resolveExit();
    await Bun.sleep(10);
  });

  it("atomically restarts active playback without resolving its blocking handle", async () => {
    const { playAudioNonBlocking, restartPlayback } = await import("../tts");

    const playback = playAudioNonBlocking(`${TEST_TMP}/pq-atomic-replay.mp3`, {
      text: "Question remains blocking until replay finishes",
      voice: "TestVoice",
      nextState: "recording",
    });
    let resolved = false;
    playback.exited.then(() => {
      resolved = true;
    });
    await waitFor(() => playerMocks.length === 1, "original replay player");

    expect(restartPlayback()).toBe(true);
    expect(restartPlayback()).toBe(true);
    expect(playerMocks).toHaveLength(1);
    expect(resolved).toBe(false);

    playerMocks[0].resolveExit();
    await waitFor(() => playerMocks.length === 2, "replacement replay player");
    expect(playerMocks[1].cmd).toContain(`${TEST_TMP}/pq-atomic-replay.mp3`);
    expect(resolved).toBe(false);
    expect(
      broadcasts.filter(
        (event: any) => event.type === "state" && event.state === "idle",
      ),
    ).toHaveLength(0);

    playerMocks[1].resolveExit();
    expect(await playback.exited).toMatchObject({
      playback_id: playback.id,
      status: "completed",
    });
    const speaking = broadcasts.filter(
      (event: any) => event.type === "state" && event.state === "speaking",
    );
    expect(speaking).toHaveLength(2);
    const idles = broadcasts.filter(
      (event: any) => event.type === "state" && event.state === "idle",
    );
    expect(idles).toHaveLength(1);
    expect(
      broadcasts.filter((event: any) => event.type === "playback_outcome"),
    ).toEqual([
      expect.objectContaining({
        playback_id: playback.id,
        status: "completed",
      }),
    ]);
  });

  it("collapses only duplicate replay jobs and preserves unrelated pending speech", async () => {
    const { playAudioNonBlocking, restartPlayback } = await import("../tts");
    const replayMetadata = {
      text: "Replay this item",
      voice: "TestVoice",
    };

    const active = playAudioNonBlocking(
      `${TEST_TMP}/pq-selective-replay.mp3`,
      replayMetadata,
    );
    await waitFor(() => playerMocks.length === 1, "selective replay player");

    const duplicate = playAudioNonBlocking(
      `${TEST_TMP}/pq-selective-replay.mp3`,
      replayMetadata,
    );
    const unrelated = playAudioNonBlocking(`${TEST_TMP}/pq-after-replay.mp3`, {
      text: "Keep this queued item",
      voice: "OtherVoice",
    });
    let unrelatedResolved = false;
    unrelated.exited.then(() => {
      unrelatedResolved = true;
    });

    expect(restartPlayback()).toBe(true);
    expect(await duplicate.exited).toMatchObject({
      status: "skipped",
      reason: "collapsed",
    });
    await Bun.sleep(10);
    expect(unrelatedResolved).toBe(false);

    playerMocks[0].resolveExit();
    await waitFor(() => playerMocks.length === 2, "selective replay restart");
    expect(playerMocks[1].cmd).toContain(`${TEST_TMP}/pq-selective-replay.mp3`);
    playerMocks[1].resolveExit();
    expect(await active.exited).toMatchObject({ status: "completed" });

    await waitFor(() => playerMocks.length === 3, "preserved queued player");
    expect(playerMocks[2].cmd).toContain(`${TEST_TMP}/pq-after-replay.mp3`);
    playerMocks[2].resolveExit();
    expect(await unrelated.exited).toMatchObject({ status: "completed" });
  });

  it("collapses rapid replay while the replacement is still preparing", async () => {
    const { playAudioNonBlocking, restartPlayback } = await import("../tts");

    const playback = playAudioNonBlocking(`${TEST_TMP}/pq-preparing-replay.mp3`, {
      text: "Keep the blocking turn attached to one replacement",
      voice: "TestVoice",
      nextState: "recording",
    });
    await waitFor(() => playerMocks.length === 1, "original replay player");

    holdDecoderExits = true;
    expect(restartPlayback()).toBe(true);
    playerMocks[0].resolveExit();
    await waitFor(
      () => decoderMocks.length === 2,
      "replacement amplitude preparation",
    );

    expect(playerMocks).toHaveLength(1);
    expect(restartPlayback()).toBe(true);
    decoderMocks[1].resolveExit();
    await waitFor(() => playerMocks.length === 2, "prepared replacement player");
    playerMocks[1].resolveExit();

    expect(await playback.exited).toMatchObject({
      playback_id: playback.id,
      status: "completed",
    });
    expect(playerMocks).toHaveLength(2);
    expect(
      broadcasts.filter((event: any) => event.type === "playback_outcome"),
    ).toHaveLength(1);
  });

  it("does not acknowledge replay while an unrelated queued job is preparing", async () => {
    const { playAudioNonBlocking, restartPlayback } = await import("../tts");

    const first = playAudioNonBlocking(`${TEST_TMP}/pq-unrelated-first.mp3`);
    await waitFor(() => playerMocks.length === 1, "first queued player");

    holdDecoderExits = true;
    const second = playAudioNonBlocking(`${TEST_TMP}/pq-unrelated-preparing.mp3`, {
      text: "This preparation was not created by Replay",
      voice: "TestVoice",
    });
    playerMocks[0].resolveExit();
    await first.exited;
    await waitFor(
      () => decoderMocks.length === 1,
      "unrelated queued amplitude preparation",
    );

    expect(restartPlayback()).toBe(false);
    decoderMocks[0].resolveExit();
    await waitFor(() => playerMocks.length === 2, "second queued player");
    expect(playerMocks[1].cmd).toContain(`${TEST_TMP}/pq-unrelated-preparing.mp3`);
    playerMocks[1].resolveExit();
    expect(await second.exited).toMatchObject({ status: "completed" });
  });

  it("does not acknowledge socket stop until the killed player has exited", async () => {
    const { playAudioNonBlocking } = await import("../tts");
    const { handleSocketCommand } = await import("../socket-handlers");

    playAudioNonBlocking(`${TEST_TMP}/pq-stop-ack-original.mp3`);
    await waitFor(() => playerMocks.length === 1, "stop-ack player creation");

    let acknowledged = false;
    const responsePromise = Promise.resolve(
      handleSocketCommand({ cmd: "stop", id: "stop-after-exit" }),
    ).then((response) => {
      acknowledged = true;
      return response;
    });
    await Bun.sleep(10);
    expect(acknowledged).toBe(false);

    playerMocks[0].resolveExit();
    expect(await responsePromise).toEqual({
      type: "ack",
      command: "stop",
      outcome: "accept",
      id: "stop-after-exit",
    });
  });

  it("broadcasts speaking via metadata when playback actually starts, not when queued", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    // Queue two items WITH metadata — this param doesn't exist yet (TDD RED)
    playAudioNonBlocking(`${TEST_TMP}/pq-meta1.mp3`, {
      text: "First message",
      voice: "TestVoice",
    });
    playAudioNonBlocking(`${TEST_TMP}/pq-meta2.mp3`, {
      text: "Second message",
      voice: "TestVoice",
    });

    await Bun.sleep(50);

    // Only first speaking broadcast should exist (second hasn't started playing yet)
    const speakingEvents = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "speaking",
    );
    expect(speakingEvents.length).toBe(1);
    expect((speakingEvents[0] as any).text).toBe("First message");
    expect(speakingSpawnCounts[0]).toBe(1);
    expect((speakingEvents[0] as any).playback_amplitude).toEqual({
      source: "decoded-rms",
      sample_interval_ms: 50,
      samples: expect.arrayContaining([expect.any(Number), expect.any(Number)]),
    });
    expect((speakingEvents[0] as any).playback_amplitude.samples[1]).toBeGreaterThan(
      (speakingEvents[0] as any).playback_amplitude.samples[0],
    );

    // Finish first playback → second should start and broadcast
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    const allSpeaking = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "speaking",
    );
    expect(allSpeaking.length).toBe(2);
    expect((allSpeaking[1] as any).text).toBe("Second message");
    expect(speakingSpawnCounts[1]).toBe(2);

    // Cleanup
    playerMocks[1].resolveExit();
    await Bun.sleep(50);
  });

  it("publishes an explicit flat fallback when cached audio cannot be decoded", async () => {
    const { playAudioNonBlocking } = await import("../tts");
    decodeSucceeds = false;

    const playback = playAudioNonBlocking(`${TEST_TMP}/pq-replay-corrupt.mp3`, {
      text: "Cached replay",
      voice: "TestVoice",
    });
    await waitFor(
      () => broadcasts.some(
        (event: any) => event.type === "state" && event.state === "speaking",
      ),
      "fallback speaking event",
    );

    const speaking = broadcasts.find(
      (event: any) => event.type === "state" && event.state === "speaking",
    ) as any;
    expect(speaking.playback_amplitude).toEqual({
      source: "unavailable",
      sample_interval_ms: 50,
      samples: [],
    });
    expect(speakingSpawnCounts).toEqual([1]);

    playerMocks[0].resolveExit();
    await playback.exited;
  });

  it("announces the recording follow-up on the playback-finished idle edge", async () => {
    const { playAudioNonBlocking } = await import("../tts");
    const playback = playAudioNonBlocking(`${TEST_TMP}/pq-converse.mp3`, {
      text: "Ask prompt",
      voice: "TestVoice",
      nextState: "recording",
    });
    await waitFor(() => playerMocks.length === 1, "converse player creation");

    playerMocks[0].resolveExit();
    await playback.exited;

    const finalIdle = broadcasts.findLast(
      (event: any) => event.type === "state" && event.state === "idle",
    ) as any;
    expect(finalIdle).toEqual({
      type: "state",
      state: "idle",
      source: "playback",
      next_state: "recording",
    });
  });

  it("returns before asynchronous envelope preparation completes", async () => {
    const { playAudioNonBlocking } = await import("../tts");
    holdDecoderExits = true;

    const playback = playAudioNonBlocking(`${TEST_TMP}/pq-nonblocking.mp3`, {
      text: "Nonblocking",
      voice: "TestVoice",
    });

    expect(synchronousDecodeCount).toBe(0);
    await waitFor(() => decoderMocks.length === 1, "resolved amplitude decoder");
    expect(decoderMocks).toHaveLength(1);
    expect(playerMocks).toHaveLength(0);
    expect(decoderSpawnOptions).toMatchObject({
      maxBuffer: 2_400_001,
      timeout: 30_000,
    });

    decoderMocks[0].resolveExit();
    await waitFor(() => playerMocks.length === 1, "prepared player creation");

    expect(playerMocks).toHaveLength(1);
    playerMocks[0].resolveExit();
    await playback.exited;
  });

  it("does not expire an eligible job while amplitude preparation is active", async () => {
    const { playAudioNonBlocking } = await import("../tts");
    holdDecoderExits = true;
    let now = 1_000;
    const nowSpy = spyOn(Date, "now").mockImplementation(() => now);

    try {
      const playback = playAudioNonBlocking(`${TEST_TMP}/pq-slow-preparation.mp3`, {
        text: "Prepared fallback must still play",
        voice: "TestVoice",
      });
      await waitFor(() => decoderMocks.length === 1, "resolved amplitude decoder");
      expect(decoderMocks).toHaveLength(1);

      now += 30_001;
      decoderMocks[0].resolveExit();
      await decoderMocks[0].exited;
      await Bun.sleep(10);

      expect(playerMocks).toHaveLength(1);
      playerMocks[0].resolveExit();
      await playback.exited;
    } finally {
      nowSpy.mockRestore();
    }
  });

  it("cancels a job while asynchronous envelope preparation is in flight", async () => {
    const { playAudioNonBlocking, stopPlayback } = await import("../tts");
    holdDecoderExits = true;

    const playback = playAudioNonBlocking(`${TEST_TMP}/pq-cancel-preparing.mp3`, {
      text: "Cancel preparing",
      voice: "TestVoice",
    });
    let exited = false;
    playback.exited.then(() => {
      exited = true;
    });

    await waitFor(() => decoderMocks.length === 1, "resolved amplitude decoder");
    expect(stopPlayback()).toBe(true);
    await playback.exited;
    expect(exited).toBe(true);
    expect(decoderMocks[0].killed).toBe(true);

    decoderMocks[0].resolveExit();
    await decoderMocks[0].exited;
    await Promise.resolve();
    expect(playerMocks).toHaveLength(0);
  });

  it("terminates superseded envelope preparation on critical barge-in", async () => {
    const { playAudioNonBlocking, stopPlayback } = await import("../tts");
    holdDecoderExits = true;

    playAudioNonBlocking(`${TEST_TMP}/pq-barge-preparing.mp3`, {
      text: "Preparing",
      voice: "TestVoice",
    });
    await waitFor(() => decoderMocks.length === 1, "resolved amplitude decoder");
    expect(decoderMocks).toHaveLength(1);

    playAudioNonBlocking(`${TEST_TMP}/pq-barge-preparing-critical.mp3`, {
      text: "Critical",
      voice: "TestVoice",
      priority: "critical",
    });

    expect(decoderMocks[0].killed).toBe(true);
    await waitFor(() => decoderMocks.length === 2, "replacement amplitude decoder");
    expect(decoderMocks).toHaveLength(2);
    stopPlayback();
    expect(decoderMocks[1].killed).toBe(true);
  });

  it("defers envelope decoding for queued audio until that job can start", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    const first = playAudioNonBlocking(`${TEST_TMP}/pq-decode-first.mp3`, {
      text: "First",
      voice: "TestVoice",
    });
    const second = playAudioNonBlocking(`${TEST_TMP}/pq-decode-second.mp3`, {
      text: "Second",
      voice: "TestVoice",
    });
    await waitFor(() => playerMocks.length === 1, "first prepared player");

    expect(queueEvents.filter((event) => event.startsWith("decode:"))).toEqual([
      `decode:${TEST_TMP}/pq-decode-first.mp3`,
    ]);

    playerMocks[0].resolveExit();
    await first.exited;
    await waitFor(
      () => queueEvents.includes(`decode:${TEST_TMP}/pq-decode-second.mp3`),
      "second decoder start",
    );

    expect(queueEvents.filter((event) => event.startsWith("decode:"))).toEqual([
      `decode:${TEST_TMP}/pq-decode-first.mp3`,
      `decode:${TEST_TMP}/pq-decode-second.mp3`,
    ]);

    await waitFor(() => playerMocks.length === 2, "second prepared player");
    playerMocks[1].resolveExit();
    await second.exited;
  });

  it("PLAYER0 B0-COLLATERAL: scoped prompt cancellation preserves another agent's queued speech", async () => {
    const tts = await import("../tts");
    const prompt = tts.playAudioNonBlocking(`${TEST_TMP}/pq-owned-prompt.mp3`);
    await waitFor(() => playerMocks.length === 1, "prompt player");
    const other = tts.playAudioNonBlocking(`${TEST_TMP}/pq-other-agent.mp3`);
    let otherSettled = false; void other.exited.then(() => { otherSettled = true; });
    const cancel = tts.cancelPlayback;
    expect(cancel({ id: prompt.id })).toBe(true);
    expect(await prompt.exited).toMatchObject({ status: "interrupted", reason: "stopped" });
    await Bun.sleep(5);
    expect(otherSettled).toBe(false);
    playerMocks[0].resolveExit();
    await waitFor(() => playerMocks.length === 2, "unrelated player");
    playerMocks[1].resolveExit(); expect((await other.exited).status).toBe("completed");
  });

  it("PLAYER0 player exit is distinct from logical Stop completion", async () => {
    const tts = await import("../tts");
    const h = tts.playAudioNonBlocking(`${TEST_TMP}/pq-reap.mp3`);
    await waitFor(() => playerMocks.length === 1, "owned player");
    let reaped = false; void h.playerExited.then(() => { reaped = true; });
    let attemptExited = false; void h.waitForPlayerExit().then(() => { attemptExited = true; });
    tts.stopPlayback(); await h.exited; await Bun.sleep(5);
    expect(reaped).toBe(false); expect(attemptExited).toBe(false);
    playerMocks[0].resolveExit();
    await h.playerExited; await Bun.sleep(5); expect(reaped).toBe(true); expect(attemptExited).toBe(true);
  });

  it("PLAYER0 cancelled decoder remains owned until reaped and cannot start a player", async () => {
    const tts = await import("../tts");
    holdDecoderExits = true; holdKilledDecoderExits = true;
    const h = tts.playAudioNonBlocking(`${TEST_TMP}/pq-decoder-reap.mp3`, { text: "Prompt", voice: "T" });
    await waitFor(() => decoderMocks.length === 1, "held decoder");
    let reaped = false; void h.playerExited.then(() => { reaped = true; });
    tts.stopPlayback(); await h.exited; await Bun.sleep(5);
    expect(decoderMocks[0].killed).toBe(true);
    expect(reaped).toBe(false); expect(tts.getPlaybackQueueDepth()).toBeGreaterThan(0);
    decoderMocks[0].resolveExit(); await h.playerExited;
    expect(playerMocks).toHaveLength(0);
  });

  it("PLAYER0 foreign and stale Replay-generation cancels are no-ops", async () => {
    const tts = await import("../tts");
    const h = tts.playAudioNonBlocking(`${TEST_TMP}/pq-generation.mp3`);
    await waitFor(() => playerMocks.length === 1, "first player");
    const stale = { id: h.id, generation: h.generation };
    const cancel = tts.cancelPlayback;
    expect(cancel({ id: "foreign-utterance" })).toBe(false);
    expect(tts.restartPlayback()).toBe(true);
    expect(cancel(stale)).toBe(false);
    playerMocks[0].resolveExit();
    await waitFor(() => playerMocks.length === 2, "replayed player");
    expect(cancel(stale)).toBe(false);
    expect(cancel({ id: h.id, generation: h.generation })).toBe(true);
    playerMocks[1].resolveExit(); await h.exited;
    expect(cancel({ id: h.id })).toBe(false);
  });

  it("PLAYER0 critical barge-in preserves unrelated pending jobs", async () => {
    const tts = await import("../tts");
    const current = tts.playAudioNonBlocking(`${TEST_TMP}/pq-preempt-current.mp3`);
    await waitFor(() => playerMocks.length === 1, "current player");
    const other = tts.playAudioNonBlocking(`${TEST_TMP}/pq-preempt-other.mp3`);
    let settled = false; void other.exited.then(() => { settled = true; });
    const critical = tts.playAudioNonBlocking(`${TEST_TMP}/pq-preempt-critical.mp3`, { text: "Critical", voice: "T", priority: "critical" });
    await current.exited; await Bun.sleep(5); expect(settled).toBe(false);
    playerMocks[0].resolveExit(); await waitFor(() => playerMocks.length === 2, "critical player");
    playerMocks[1].resolveExit(); await critical.exited;
    await waitFor(() => playerMocks.length === 3, "preserved player");
    playerMocks[2].resolveExit(); await other.exited;
  });

  it("interrupts active playback before decoding a critical barge-in", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    const current = playAudioNonBlocking(`${TEST_TMP}/pq-barge-current.mp3`, {
      text: "Current",
      voice: "TestVoice",
    });
    await waitFor(() => playerMocks.length === 1, "current player start");
    queueEvents = [];

    const critical = playAudioNonBlocking(`${TEST_TMP}/pq-barge-critical.mp3`, {
      text: "Critical",
      voice: "TestVoice",
      priority: "critical",
    });
    await current.exited;
    expect(playerMocks).toHaveLength(1);
    expect(queueEvents).toEqual([`kill:${TEST_TMP}/pq-barge-current.mp3`]);

    playerMocks[0].resolveExit();
    await waitFor(
      () => playerMocks.length === 2,
      "critical speaking player",
    );

    expect(queueEvents.slice(0, 2)).toEqual([
      `kill:${TEST_TMP}/pq-barge-current.mp3`,
      `decode:${TEST_TMP}/pq-barge-critical.mp3`,
    ]);

    playerMocks[1].resolveExit();
    await critical.exited;
  });

  it("preserves elapsed telemetry when a critical barge-in interrupts restart termination", async () => {
    const { playAudioNonBlocking, restartPlayback } = await import("../tts");
    let now = 10_000;
    const nowSpy = spyOn(Date, "now").mockImplementation(() => now);

    try {
      const playback = playAudioNonBlocking(
        `${TEST_TMP}/pq-barge-restarting.mp3`,
        {
          text: "one two three",
          voice: "TestVoice",
          durationMs: 1_000,
          wordBoundaries: [
            { offset_ms: 0, duration_ms: 200, text: "one" },
            { offset_ms: 400, duration_ms: 200, text: "two" },
            { offset_ms: 800, duration_ms: 200, text: "three" },
          ],
        } as any,
      );
      await waitFor(() => playerMocks.length === 1, "restarting barge player");

      now = 10_300;
      expect(restartPlayback()).toBe(true);
      now = 10_550;
      const critical = playAudioNonBlocking(`${TEST_TMP}/pq-barge-after-replay.mp3`, {
        text: "Critical",
        voice: "TestVoice",
        priority: "critical",
      });

      expect(await playback.exited).toEqual({
        type: "playback_outcome",
        playback_id: playback.id,
        status: "interrupted",
        reason: "barge-in",
        stopped_at_ms: 550,
        duration_ms: 1_000,
        progress: 0.55,
        word_index: 1,
        word_count: 3,
      });

      playerMocks[0].resolveExit();
      await waitFor(() => playerMocks.length === 2, "post-replay critical player");
      playerMocks[1].resolveExit();
      await critical.exited;
    } finally {
      nowSpy.mockRestore();
    }
  });

  it("reports the exact stopped-at position when the user interrupts playback", async () => {
    const { playAudioNonBlocking, stopPlayback } = await import("../tts");
    let now = 10_000;
    const nowSpy = spyOn(Date, "now").mockImplementation(() => now);
    const completed: any[] = [];

    try {
      const playback = playAudioNonBlocking(
        `${TEST_TMP}/pq-interrupted-position.mp3`,
        {
          text: "one two three",
          voice: "TestVoice",
          durationMs: 1_000,
          wordBoundaries: [
            { offset_ms: 0, duration_ms: 200, text: "one" },
            { offset_ms: 400, duration_ms: 200, text: "two" },
            { offset_ms: 800, duration_ms: 200, text: "three" },
          ],
          onCompleted: (outcome: unknown) => completed.push(outcome),
        } as any,
      );
      await waitFor(() => playerMocks.length === 1, "interrupted player start");

      now = 10_550;
      expect(stopPlayback()).toBe(true);
      const outcome = await playback.exited;

      expect(playback.id).toMatch(/^playback-/);
      expect(outcome).toEqual({
        type: "playback_outcome",
        playback_id: playback.id,
        status: "interrupted",
        reason: "stopped",
        stopped_at_ms: 550,
        duration_ms: 1_000,
        progress: 0.55,
        word_index: 1,
        word_count: 3,
      });
      expect(completed).toEqual([outcome]);
      expect(broadcasts).toContainEqual(outcome);
    } finally {
      nowSpy.mockRestore();
    }
  });

  it("uses the teleprompter elapsed clock for interrupt word telemetry", async () => {
    const { playAudioNonBlocking, stopPlayback } = await import("../tts");
    let now = 20_000;
    const nowSpy = spyOn(Date, "now").mockImplementation(() => now);

    try {
      const playback = playAudioNonBlocking(`${TEST_TMP}/pq-visual-cut-position.mp3`, {
        text: "one two three four",
        voice: "TestVoice",
        durationMs: 1_600,
        wordBoundaries: [
          { offset_ms: 0, duration_ms: 200, text: "one" },
          { offset_ms: 400, duration_ms: 200, text: "two" },
          { offset_ms: 800, duration_ms: 200, text: "three" },
          { offset_ms: 1_200, duration_ms: 200, text: "four" },
        ],
      });
      await waitFor(() => playerMocks.length === 1, "visual-clock player start");

      now = 21_200;
      expect((stopPlayback as (elapsedMs?: number) => boolean)(800)).toBe(true);
      const outcome = await playback.exited;

      expect(outcome).toMatchObject({
        stopped_at_ms: 800,
        word_index: 2,
        word_count: 4,
      });
    } finally {
      nowSpy.mockRestore();
    }
  });

  it("broadcasts idle only when queue fully drains, not between items", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    playAudioNonBlocking(`${TEST_TMP}/pq-idle1.mp3`);
    playAudioNonBlocking(`${TEST_TMP}/pq-idle2.mp3`);

    await Bun.sleep(50);

    // Finish first — second is still queued
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    // No idle broadcast yet — queue not empty
    const idlesBeforeDrain = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idlesBeforeDrain.length).toBe(0);

    // Finish second — queue fully drained
    playerMocks[1].resolveExit();
    await Bun.sleep(50);

    // Exactly one idle broadcast
    const idlesAfterDrain = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idlesAfterDrain.length).toBe(1);
  });

  it("single item broadcasts idle immediately after finishing", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    playAudioNonBlocking(`${TEST_TMP}/pq-single.mp3`);

    await Bun.sleep(50);
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    const idles = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idles.length).toBe(1);
  });

  it("does not broadcast idle when queued playback is refused during active recording", async () => {
    const originalRecordingStatePath = process.env.QA_VOICE_RECORDING_STATE_PATH;
    const { playAudioNonBlocking } = await import("../tts");

    try {
      process.env.QA_VOICE_RECORDING_STATE_PATH = TEST_RECORDING_STATE_FILE;
      writeRecordingState("idle");

      playAudioNonBlocking(`${TEST_TMP}/pq-recording-skip-1.mp3`);
      playAudioNonBlocking(`${TEST_TMP}/pq-recording-skip-2.mp3`);

      await Bun.sleep(50);
      writeRecordingState("recording");
      playerMocks[0].resolveExit();
      await Bun.sleep(50);

      const errors = broadcasts.filter(
        (b: any) => b.type === "error" && b.message === SPEAKER_REFUSED,
      );
      const idles = broadcasts.filter(
        (b: any) => b.type === "state" && b.state === "idle",
      );
      expect(errors).toHaveLength(1);
      expect(idles).toHaveLength(0);
      expect(playerMocks).toHaveLength(1);
    } finally {
      writeRecordingState("idle");
      if (originalRecordingStatePath === undefined) {
        delete process.env.QA_VOICE_RECORDING_STATE_PATH;
      } else {
        process.env.QA_VOICE_RECORDING_STATE_PATH = originalRecordingStatePath;
      }
      cleanupRecordingState();
    }
  });

  it("does not emit idle or spawn when recording starts after the queue gate", async () => {
    const { playAudioNonBlocking } = await import("../tts");
    let stateCalls = 0;
    const stateSpy = spyOn(
      recordingState,
      "getEffectiveRecordingState",
    ).mockImplementation(() => {
      stateCalls += 1;
      return stateCalls <= 2 ? "idle" : "recording";
    });

    try {
      playAudioNonBlocking(`${TEST_TMP}/pq-replay-late-recording.mp3`, {
        text: "Replay",
        voice: "TestVoice",
      });
      await Bun.sleep(50);

      const idles = broadcasts.filter(
        (b: any) => b.type === "state" && b.state === "idle",
      );
      const errors = broadcasts.filter(
        (b: any) => b.type === "error" && b.message === SPEAKER_REFUSED,
      );
      expect(idles).toHaveLength(0);
      expect(errors).toHaveLength(1);
      expect(playerMocks).toHaveLength(0);
    } finally {
      stateSpy.mockRestore();
    }
  });
});

describe("awaitCurrentPlayback — P0-2 queue awareness", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;
  let recordingStateSpy: ReturnType<typeof spyOn>;
  let playerMocks: MockPlayer[];
  const originalSpawn = Bun.spawn;
  const originalSpawnSync = Bun.spawnSync;

  beforeEach(async () => {
    try {
      const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
      stopPlayback();
      await awaitCurrentPlayback();
    } catch {}

    playerMocks = [];
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      () => {},
    );
    recordingStateSpy = spyOn(
      recordingState,
      "getEffectiveRecordingState",
    ).mockReturnValue("idle");

    // @ts-ignore
    Bun.spawnSync = (cmd: string[]) => {
      if (cmd[0] === "which" && ["ffmpeg", "ffprobe"].includes(cmd[1])) return {exitCode: 0, stdout: Buffer.from(`${cmd[1]}\n`), stderr: Buffer.alloc(0)};
      if (cmd[1] === "-version") return {exitCode: ["ffmpeg", "ffprobe"].includes(cmd[0]) ? 0 : 1, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0)};
      if (Array.isArray(cmd) && cmd[0] === "which") {
        return {
          exitCode: 1,
          stdout: new Uint8Array(0),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSync(cmd);
    };

    // @ts-ignore
    Bun.spawn = (cmd: string[], _opts?: unknown) => {
      if (cmd[0] === "which" && cmd[1] === "ffmpeg") return {pid: 89990, exited: Promise.resolve(0), stdout: new Blob(["ffmpeg\n"]).stream(), kill() {}};
      if (cmd[1] === "-version") return {pid: 89991, exited: Promise.resolve(cmd[0] === "ffmpeg" ? 0 : 1), kill() {}};
      let resolveExit!: () => void;
      const exited = new Promise<number>((r) => {
        resolveExit = () => r(0);
      });
      playerMocks.push({
        cmd: [...(Array.isArray(cmd) ? cmd : [String(cmd)])],
        resolveExit,
      });
      return { exited, pid: 99000 + playerMocks.length, kill: () => {} };
    };
  });

  afterEach(async () => {
    for (let i = 0; i < playerMocks.length; i++) {
      try {
        playerMocks[i].resolveExit();
      } catch {}
    }
    await Bun.sleep(100);
    for (let i = 0; i < playerMocks.length; i++) {
      try {
        playerMocks[i].resolveExit();
      } catch {}
    }
    await Bun.sleep(50);
    try {
      const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
      stopPlayback();
      await awaitCurrentPlayback();
    } catch {}

    broadcastSpy.mockRestore();
    recordingStateSpy.mockRestore();
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
  });

  it("awaitCurrentPlayback waits for full queue, not just current item", async () => {
    const { playAudioNonBlocking, awaitCurrentPlayback } =
      await import("../tts");

    playAudioNonBlocking(`${TEST_TMP}/pq-aw1.mp3`);
    playAudioNonBlocking(`${TEST_TMP}/pq-aw2.mp3`);

    let awaited = false;
    awaitCurrentPlayback().then(() => {
      awaited = true;
    });

    await Bun.sleep(50);
    expect(awaited).toBe(false);

    // Finish first — queue still has second pending
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    // Should NOT resolve yet — second item still queued
    expect(awaited).toBe(false);

    // Finish second — queue fully drained
    playerMocks[1].resolveExit();
    await Bun.sleep(50);

    // NOW it should resolve
    expect(awaited).toBe(true);
  });

  it("awaitCurrentPlayback resolves immediately if queue is empty", async () => {
    const { awaitCurrentPlayback } = await import("../tts");

    let awaited = false;
    awaitCurrentPlayback().then(() => {
      awaited = true;
    });

    await Bun.sleep(50);
    expect(awaited).toBe(true);
  });
});
