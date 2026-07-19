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

import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import { existsSync, unlinkSync, writeFileSync } from "fs";
import * as recordingState from "../recording-state";
import * as socketClient from "../socket-client";

// --- Mock helpers ---

interface MockPlayer {
  cmd: string[];
  resolveExit: () => void;
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

const TEST_RECORDING_STATE_FILE = `/tmp/voicelayer-playback-queue-state-${process.pid}.json`;
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
            resolveExit();
          },
        };
      }
      let resolveExit!: () => void;
      const exited = new Promise<number>((r) => {
        resolveExit = () => r(0);
      });
      playerMocks.push({ cmd: cmdArray, resolveExit });
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

    playAudioNonBlocking("/tmp/pq-seq1.mp3");
    playAudioNonBlocking("/tmp/pq-seq2.mp3");

    await Bun.sleep(50);

    // Only first player should be spawned (queue serializes)
    expect(playerMocks.length).toBe(1);
    expect(playerMocks[0].cmd).toContain("/tmp/pq-seq1.mp3");

    // Finish first playback
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    // Now second player should be spawned
    expect(playerMocks.length).toBe(2);
    expect(playerMocks[1].cmd).toContain("/tmp/pq-seq2.mp3");

    // Finish second
    playerMocks[1].resolveExit();
    await Bun.sleep(50);
  });

  it("broadcasts speaking via metadata when playback actually starts, not when queued", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    // Queue two items WITH metadata — this param doesn't exist yet (TDD RED)
    playAudioNonBlocking("/tmp/pq-meta1.mp3", {
      text: "First message",
      voice: "TestVoice",
    });
    playAudioNonBlocking("/tmp/pq-meta2.mp3", {
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

    const playback = playAudioNonBlocking("/tmp/pq-replay-corrupt.mp3", {
      text: "Cached replay",
      voice: "TestVoice",
      preStartIdle: true,
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

  it("returns before asynchronous envelope preparation completes", async () => {
    const { playAudioNonBlocking } = await import("../tts");
    holdDecoderExits = true;

    const playback = playAudioNonBlocking("/tmp/pq-nonblocking.mp3", {
      text: "Nonblocking",
      voice: "TestVoice",
    });

    expect(synchronousDecodeCount).toBe(0);
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
      const playback = playAudioNonBlocking("/tmp/pq-slow-preparation.mp3", {
        text: "Prepared fallback must still play",
        voice: "TestVoice",
      });
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

    const playback = playAudioNonBlocking("/tmp/pq-cancel-preparing.mp3", {
      text: "Cancel preparing",
      voice: "TestVoice",
    });
    let exited = false;
    playback.exited.then(() => {
      exited = true;
    });

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

    playAudioNonBlocking("/tmp/pq-barge-preparing.mp3", {
      text: "Preparing",
      voice: "TestVoice",
    });
    expect(decoderMocks).toHaveLength(1);

    playAudioNonBlocking("/tmp/pq-barge-preparing-critical.mp3", {
      text: "Critical",
      voice: "TestVoice",
      priority: "critical",
    });

    expect(decoderMocks[0].killed).toBe(true);
    expect(decoderMocks).toHaveLength(2);
    stopPlayback();
    expect(decoderMocks[1].killed).toBe(true);
  });

  it("defers envelope decoding for queued audio until that job can start", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    const first = playAudioNonBlocking("/tmp/pq-decode-first.mp3", {
      text: "First",
      voice: "TestVoice",
    });
    const second = playAudioNonBlocking("/tmp/pq-decode-second.mp3", {
      text: "Second",
      voice: "TestVoice",
    });
    await waitFor(() => playerMocks.length === 1, "first prepared player");

    expect(queueEvents.filter((event) => event.startsWith("decode:"))).toEqual([
      "decode:/tmp/pq-decode-first.mp3",
    ]);

    playerMocks[0].resolveExit();
    await first.exited;
    await waitFor(
      () => queueEvents.includes("decode:/tmp/pq-decode-second.mp3"),
      "second decoder start",
    );

    expect(queueEvents.filter((event) => event.startsWith("decode:"))).toEqual([
      "decode:/tmp/pq-decode-first.mp3",
      "decode:/tmp/pq-decode-second.mp3",
    ]);

    await waitFor(() => playerMocks.length === 2, "second prepared player");
    playerMocks[1].resolveExit();
    await second.exited;
  });

  it("interrupts active playback before decoding a critical barge-in", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    const current = playAudioNonBlocking("/tmp/pq-barge-current.mp3", {
      text: "Current",
      voice: "TestVoice",
    });
    await waitFor(() => playerMocks.length === 1, "current player start");
    queueEvents = [];

    const critical = playAudioNonBlocking("/tmp/pq-barge-critical.mp3", {
      text: "Critical",
      voice: "TestVoice",
      priority: "critical",
    });
    await current.exited;
    await waitFor(
      () => playerMocks.length === 2,
      "critical speaking player",
    );

    expect(queueEvents.slice(0, 2)).toEqual([
      "kill:/tmp/pq-barge-current.mp3",
      "decode:/tmp/pq-barge-critical.mp3",
    ]);

    playerMocks[1].resolveExit();
    await critical.exited;
  });

  it("reports the exact stopped-at position when the user interrupts playback", async () => {
    const { playAudioNonBlocking, stopPlayback } = await import("../tts");
    let now = 10_000;
    const nowSpy = spyOn(Date, "now").mockImplementation(() => now);
    const completed: any[] = [];

    try {
      const playback = playAudioNonBlocking(
        "/tmp/pq-interrupted-position.mp3",
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

  it("broadcasts idle only when queue fully drains, not between items", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    playAudioNonBlocking("/tmp/pq-idle1.mp3");
    playAudioNonBlocking("/tmp/pq-idle2.mp3");

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

    playAudioNonBlocking("/tmp/pq-single.mp3");

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

      playAudioNonBlocking("/tmp/pq-recording-skip-1.mp3");
      playAudioNonBlocking("/tmp/pq-recording-skip-2.mp3");

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

  it("does not emit replay pre-start idle or spawn when recording starts after the queue gate", async () => {
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
      playAudioNonBlocking("/tmp/pq-replay-late-recording.mp3", {
        text: "Replay",
        voice: "TestVoice",
        preStartIdle: true,
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

    playAudioNonBlocking("/tmp/pq-aw1.mp3");
    playAudioNonBlocking("/tmp/pq-aw2.mp3");

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
