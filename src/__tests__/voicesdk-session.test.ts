import { mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { createVoiceSdkSessionManager } from "../voicesdk/session";
import type { BargeInMonitorOptions, SoundLayer } from "../soundlayer";
import type { PlaybackScope, QueuedPlaybackHandle } from "../tts/playback-lifecycle";

function fakeSoundLayer(): SoundLayer {
  return {
    micCapture: {
      async recordToBuffer() {
        return null;
      },
      async waitForInput() {
        return "raw answer";
      },
      clear() {},
      getState() {
        return "idle";
      },
    },
    playback: {
      play() {
        return { exited: Promise.resolve() };
      },
      async waitForIdle() {},
      stop() {
        return true;
      },
      getQueueDepth() {
        return 0;
      },
    },
    vad: {
      async processChunk() {
        return 0;
      },
      isSpeech() {
        return false;
      },
      silenceChunksForMode() {
        return 1;
      },
      async reset() {},
    },
    cancellation: {
      stopPlayback() {
        return true;
      },
      consumeRecordingCancel() {
        return false;
      },
    },
    transcriptEvents: {
      emitTranscript() {},
    },
    tts: {
      async speak() {
        return {};
      },
    },
    stt: {
      async getBackend() {
        return {
          name: "fake-stt",
          async isAvailable() {
            return true;
          },
          async transcribe() {
            return {
              text: "raw answer",
              backend: "fake-stt",
              durationMs: 1,
            };
          },
        };
      },
    },
  };
}

function fakeBargeInSoundLayer(options: {
  onsetMs: number;
  stopLatencyMs: number;
  onStop: () => void;
}): SoundLayer {
  const layer = fakeSoundLayer();
  let nowMs = 1_000;
  return {
    ...layer,
    cancellation: {
      cancelPlayback() {
        options.onStop();
        nowMs = 1_000 + options.onsetMs + options.stopLatencyMs;
        return true;
      },
      stopPlayback() { throw new Error("Barge-in must never call global Stop"); },
      consumeRecordingCancel() {
        return false;
      },
    },
    tts: {
      async speak(_text, speakOptions) {
        speakOptions?.onPlaybackQueued?.(promptHandle("sdk-fixture"));
        speakOptions?.onPlaybackStart?.(1_000);
        await Bun.sleep(20);
        return {};
      },
    },
    bargeIn: {
      monitorDuringPlayback(monitorOptions) {
        setTimeout(() => {
          void monitorOptions.onSpeechStart({
            onset_ms: options.onsetMs,
            probability: 0.91,
            speech_chunks: 2,
            captured_at_ms: 1_000 + options.onsetMs,
          });
        }, 1);
        return {
          exited: Promise.resolve(),
          stop() {},
          getMetrics() {
            return {
              processed_chunks: 2,
              false_interrupts: 0,
              confirmed_interrupts: 1,
              false_interrupt_rate: 0,
            };
          },
        };
      },
    },
    clock: {
      nowMs() {
        return nowMs;
      },
    },
  };
}

function promptHandle(id: string, playerExited = Promise.resolve()): QueuedPlaybackHandle {
  return { id, generation: 4,
    exited: Promise.resolve({ type: "playback_outcome", playback_id: id, status: "completed", stopped_at_ms: 0, progress: 1 }),
    playerExited, waitForPlayerExit: () => playerExited };
}

function captureDeadline(budget: number) {
  const native = globalThis.setTimeout;
  let fire: (() => void) | undefined;
  const spy = spyOn(globalThis, "setTimeout").mockImplementation(((fn, ms, ...args) => {
    const timer = native(fn, ms, ...args);
    if (ms === budget) fire = () => { clearTimeout(timer); fn(...args); };
    return timer;
  }) as typeof setTimeout);
  return { get fire() { return fire; }, restore: () => spy.mockRestore() };
}

function ownedPromptFixture(playerExited = Promise.resolve(), monitorExited = Promise.resolve()) {
  const layer = fakeSoundLayer();
  const monitors: BargeInMonitorOptions[] = [];
  const scopes: PlaybackScope[] = [];
  let globalStops = 0;
  let monitorStops = 0;
  let queued = 0;
  let cancelAccepted = true;
  layer.cancellation.stopPlayback = () => { globalStops++; return true; };
  layer.cancellation.cancelPlayback = scope => { scopes.push(scope); return cancelAccepted; };
  layer.bargeIn = { monitorDuringPlayback(options) {
    monitors.push(options);
    return { exited: monitorExited, stop() { monitorStops++; },
      pushAudioChunk: async () => ({ speechStarted: false }),
      getMetrics: () => ({ processed_chunks: 0, false_interrupts: 0, confirmed_interrupts: 0, false_interrupt_rate: 0 }) };
  } };
  layer.tts.speak = async (_text, options) => {
    options?.onPlaybackQueued?.(promptHandle(`owned-sdk-${++queued}`, playerExited));
    options?.onPlaybackStart?.(1000);
    return {};
  };
  return { layer, monitors, scopes, rejectCancel() { cancelAccepted = false; },
    get globalStops() { return globalStops; }, get monitorStops() { return monitorStops; },
    fire(index = monitors.length - 1) {
      void monitors[index]?.onSpeechStart({ onset_ms: 180, probability: 1, speech_chunks: 2, captured_at_ms: 1180 });
    } };
}

describe("VoiceSDK session manager", () => {
  let tempDir: string | null = null;

  afterEach(() => {
    if (tempDir) rmSync(tempDir, { recursive: true, force: true });
    tempDir = null;
  });

  it("emits ordered lifecycle events and appends them to a durable NDJSON log", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-session-"));
    const emitted: string[] = [];
    const manager = createVoiceSdkSessionManager({
      soundLayer: fakeSoundLayer(),
      logDir: tempDir,
      idFactory: () => "session-fixed",
      now: () => new Date("2026-05-28T12:00:00.000Z"),
      onEvent: (event) => emitted.push(event.type),
    });

    const session = await manager.startSession({
      product: "VoiceReview",
      artifact_id: "artifact-1",
    });
    await manager.startSection(session.session_id, {
      section_id: "intro",
      title: "Intro",
      ordinal: 1,
    });
    await manager.speak(session.session_id, {
      text: "Hello VoiceSDK",
      voice_id: "theo",
    });
    await manager.listen(session.session_id, {
      mode: "vad",
      timeout_ms: 250,
    });
    await manager.recordDecision(session.session_id, {
      artifact_ref: "artifact-1",
      summary: "Keep this",
      status: "accepted",
    });
    await manager.endSession(session.session_id, "completed");

    expect(emitted).toEqual([
      "session.started",
      "section.started",
      "speak.started",
      "speak.chunk",
      "speak.stopped",
      "listen.started",
      "transcript.final",
      "answer.final",
      "decision.recorded",
      "session.ended",
    ]);

    const logLines = readFileSync(
      join(tempDir, "session-fixed.ndjson"),
      "utf-8",
    ).trim().split("\n").map((line) => JSON.parse(line));

    expect(logLines.map((line) => line.sequence)).toEqual([
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
    ]);
    expect(logLines[0]).toMatchObject({
      type: "session.started",
      session_id: "session-fixed",
      product: "VoiceReview",
      artifact_id: "artifact-1",
    });
    expect(logLines[6]).toMatchObject({
      type: "transcript.final",
      raw_text: "raw answer",
      cleaned_text: "raw answer",
      stt_backend: "soundlayer.micCapture",
    });
    expect(logLines[9]).toMatchObject({
      type: "session.ended",
      reason: "completed",
      duration_ms: 0,
    });
  });

  it("keeps durable replay separate from live subscribers", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-session-"));
    const manager = createVoiceSdkSessionManager({
      soundLayer: fakeSoundLayer(),
      logDir: tempDir,
      idFactory: () => "session-no-subscriber",
    });

    await manager.startSession({ product: "VoiceReview" });

    expect(
      readFileSync(join(tempDir, "session-no-subscriber.ndjson"), "utf-8"),
    ).toContain('"type":"session.started"');
  });

  it("cancels playback and emits ordered barge-in turn events", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-session-"));
    const events: string[] = [];
    let stopped = false;
    const manager = createVoiceSdkSessionManager({
      soundLayer: fakeBargeInSoundLayer({
        onsetMs: 180,
        stopLatencyMs: 44,
        onStop: () => {
          stopped = true;
        },
      }),
      logDir: tempDir,
      idFactory: () => "session-barge-in",
      onEvent: (event) => events.push(event.type),
    });

    const session = await manager.startSession({ product: "VoiceReview" });
    await manager.speak(session.session_id, {
      text: "Please review this section.",
      voice_id: "theo",
    });

    expect(stopped).toBe(true);
    expect(events).toEqual([
      "session.started",
      "speak.started",
      "speak.chunk",
      "listen.started",
      "user.speech_started",
      "user.interrupted",
      "speak.stopped",
    ]);

    const logLines = readFileSync(
      join(tempDir, "session-barge-in.ndjson"),
      "utf-8",
    ).trim().split("\n").map((line) => JSON.parse(line));
    expect(logLines[4]).toMatchObject({
      type: "user.speech_started",
      onset_ms: 180,
    });
    expect(logLines[5]).toMatchObject({
      type: "user.interrupted",
      stopped_utterance_id: "utt-2",
      onset_to_stop_ms: 44,
    });
    expect(logLines[5].onset_to_stop_ms).toBeLessThan(250);
    expect(logLines[6]).toMatchObject({
      type: "speak.stopped",
      reason: "interrupted",
    });
  });

  it("PLAYER0b cancels only its captured scope and ignores old onsets during a newer prompt", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-scoped-"));
    const fixture = ownedPromptFixture();
    const manager = createVoiceSdkSessionManager({ soundLayer: fixture.layer, logDir: tempDir });
    const session = await manager.startSession({ product: "Fixture" });
    const first = manager.speak(session.session_id, { text: "Owned prompt" });
    fixture.fire(); await first;
    const second = manager.speak(session.session_id, { text: "New prompt" });
    fixture.fire(0); await second; fixture.fire(1);
    expect(fixture.globalStops).toBe(0);
    expect(fixture.scopes).toEqual([{ id: "owned-sdk-1", generation: 4 }]);
    expect(manager.replay(session.session_id).filter(event => event.type === "speak.stopped").map(event => event.reason))
      .toEqual(["interrupted", "completed"]);
  });

  it("PLAYER0b a completed uninterrupted prompt cannot stop a newer prompt", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-late-"));
    const fixture = ownedPromptFixture();
    const manager = createVoiceSdkSessionManager({ soundLayer: fixture.layer, logDir: tempDir });
    const session = await manager.startSession({ product: "Fixture" });
    await manager.speak(session.session_id, { text: "Completed prompt" });
    const next = manager.speak(session.session_id, { text: "New prompt" });
    fixture.fire(0); await next;
    expect(fixture.globalStops).toBe(0);
    expect(fixture.scopes).toEqual([]);
    expect(manager.replay(session.session_id).some(event => event.type === "user.interrupted")).toBe(false);
  });

  for (const missing of ["cancel", "handle"] as const) {
    it(`PLAYER0b leaves legacy ${missing}-less adapters without automatic barge-in`, async () => {
      tempDir = mkdtempSync(join(tmpdir(), "voicesdk-legacy-"));
      const fixture = ownedPromptFixture();
      if (missing === "cancel") delete fixture.layer.cancellation.cancelPlayback;
      else fixture.layer.tts.speak = async (_text, options) => { options?.onPlaybackStart?.(1000); return {}; };
      const manager = createVoiceSdkSessionManager({ soundLayer: fixture.layer, logDir: tempDir });
      const session = await manager.startSession({ product: "Fixture" });
      await manager.speak(session.session_id, { text: "Legacy prompt" });
      expect(fixture.monitors).toHaveLength(0);
      expect(fixture.globalStops).toBe(0);
    });
  }

  it("PLAYER0b a rejected scoped cancel cannot report an interruption", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-stale-"));
    const fixture = ownedPromptFixture(); fixture.rejectCancel();
    const manager = createVoiceSdkSessionManager({ soundLayer: fixture.layer, logDir: tempDir });
    const session = await manager.startSession({ product: "Fixture" });
    const task = manager.speak(session.session_id, { text: "Prompt" }); fixture.fire(); await task;
    expect(fixture.globalStops).toBe(0);
    expect(fixture.scopes).toEqual([{ id: "owned-sdk-1", generation: 4 }]);
    expect(manager.replay(session.session_id).some(event => event.type === "user.interrupted")).toBe(false);
    expect(manager.replay(session.session_id).at(-1)).toMatchObject({ type: "speak.stopped", reason: "completed" });
  });

  it("PLAYER0b a monitor cannot retarget a later queued handle from its backend", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-epoch-"));
    const oldPlayer = Promise.withResolvers<void>();
    const fixture = ownedPromptFixture(); fixture.rejectCancel();
    fixture.layer.tts.speak = async (_text, options) => {
      options?.onPlaybackQueued?.(promptHandle("old-attempt", oldPlayer.promise));
      options?.onPlaybackStart?.(1000);
      options?.onPlaybackQueued?.(promptHandle("new-attempt"));
      return {};
    };
    const manager = createVoiceSdkSessionManager({ soundLayer: fixture.layer, logDir: tempDir });
    const session = await manager.startSession({ product: "Fixture" });
    const task = manager.speak(session.session_id, { text: "Prompt" }); fixture.fire();
    let settled = false; void task.then(() => { settled = true; });
    try {
      await Bun.sleep(0);
      expect(fixture.scopes).toEqual([{ id: "old-attempt", generation: 4 }]);
      expect(fixture.globalStops).toBe(0);
      expect(settled).toBe(false);
    } finally { oldPlayer.resolve(); await task; }
  });

  it("PLAYER0b completion waits for physical exit and rejects late onsets during teardown", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-exit-"));
    const physical = Promise.withResolvers<void>();
    const fixture = ownedPromptFixture(physical.promise);
    const manager = createVoiceSdkSessionManager({ soundLayer: fixture.layer, logDir: tempDir });
    const session = await manager.startSession({ product: "Fixture" });
    const task = manager.speak(session.session_id, { text: "Prompt" });
    let settled = false; void task.then(() => { settled = true; });
    try {
      await Bun.sleep(0); fixture.fire();
      expect(fixture.monitorStops).toBe(1);
      expect(settled).toBe(false);
      expect(manager.replay(session.session_id).some(event => event.type === "speak.stopped")).toBe(false);
      expect(fixture.scopes).toEqual([]);
      expect(fixture.globalStops).toBe(0);
    } finally { physical.resolve(); await task; }
    expect(manager.replay(session.session_id).at(-1)).toMatchObject({ type: "speak.stopped", reason: "completed" });
  });

  for (const failure of [false, true]) {
    it(`BARGEIN-PR3 SDK awaits monitor teardown and reports ${failure ? "failure" : "completion"}`, async () => {
      tempDir = mkdtempSync(join(tmpdir(), "voicesdk-monitor-exit-"));
      const physical = Promise.withResolvers<void>();
      void physical.promise.catch(() => {});
      const fixture = ownedPromptFixture(Promise.resolve(), physical.promise);
      const manager = createVoiceSdkSessionManager({ soundLayer: fixture.layer, logDir: tempDir });
      const session = await manager.startSession({ product: "Fixture" });
      const task = manager.speak(session.session_id, { text: "Prompt" });
      try {
        await Bun.sleep(0);
        expect(fixture.monitorStops).toBe(1);
        expect(manager.replay(session.session_id).some(event => event.type === "speak.stopped")).toBe(false);
      } finally {
        if (failure) physical.reject(new Error("monitor cleanup failed"));
        else physical.resolve();
        await task;
      }
      expect(manager.replay(session.session_id).at(-1)).toMatchObject({
        type: "speak.stopped", reason: failure ? "error" : "completed",
      });
      expect(fixture.globalStops).toBe(0);
    });
  }

  it("PLAYER0b failed physical cleanup reports error even after an accepted interruption", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-exit-error-"));
    const physical = Promise.withResolvers<void>(); void physical.promise.catch(() => {});
    const fixture = ownedPromptFixture(physical.promise);
    const manager = createVoiceSdkSessionManager({ soundLayer: fixture.layer, logDir: tempDir });
    const session = await manager.startSession({ product: "Fixture" });
    const task = manager.speak(session.session_id, { text: "Prompt" }); fixture.fire();
    physical.reject(new Error("Child exit could not be observed")); await task;
    expect(manager.replay(session.session_id).at(-1)).toMatchObject({ type: "speak.stopped", reason: "error" });
    expect(fixture.globalStops).toBe(0);
  });

  for (const physicalOnly of [true, false]) {
    it(`FX-1 SDK bounds ${physicalOnly ? "physical teardown" : "a prompt whose player never completes"}`, async () => {
      tempDir = mkdtempSync(join(tmpdir(), "voicesdk-bounded-"));
      const pending = Promise.withResolvers<void>();
      const fixture = ownedPromptFixture(physicalOnly ? pending.promise : Promise.resolve());
      if (!physicalOnly) {
        const speak = fixture.layer.tts.speak;
        fixture.layer.tts.speak = async (...args) => { await speak(...args); await pending.promise; return {}; };
      }
      const deadline = captureDeadline(physicalOnly ? 5_000 : 180_000);
      const manager = createVoiceSdkSessionManager({ soundLayer: fixture.layer, logDir: tempDir });
      const session = await manager.startSession({ product: "Fixture" });
      const task = manager.speak(session.session_id, { text: "Prompt" });
      try {
        await Bun.sleep(0); expect(deadline.fire).toBeFunction(); deadline.fire?.();
        await task;
        expect(manager.replay(session.session_id).at(-1)).toMatchObject({ type: "speak.stopped", reason: "error" });
        expect(fixture.globalStops).toBe(0);
        expect(fixture.scopes).toEqual([{ id: "owned-sdk-1" }]);
      } finally { pending.resolve(); await task; deadline.restore(); }
    });
  }

  it("FX-1 late SDK synthesis cannot start another player after its deadline", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-late-deadline-"));
    const fixture = ownedPromptFixture(); const synthesis = Promise.withResolvers<void>();
    let queueLate: (() => void) | undefined;
    fixture.layer.tts.speak = async (_text, options) => {
      queueLate = () => { options?.onPlaybackQueued?.(promptHandle("late-sdk")); options?.onPlaybackStart?.(1000); };
      await synthesis.promise; return {};
    };
    const deadline = captureDeadline(180_000);
    const manager = createVoiceSdkSessionManager({ soundLayer: fixture.layer, logDir: tempDir });
    const session = await manager.startSession({ product: "Fixture" });
    const task = manager.speak(session.session_id, { text: "Prompt" });
    try {
      await Bun.sleep(0); deadline.fire?.(); await task; queueLate?.();
      expect(fixture.scopes).toEqual([{ id: "late-sdk" }]);
      expect(fixture.monitors).toHaveLength(0);
      expect(fixture.globalStops).toBe(0);
    } finally { synthesis.resolve(); await task; deadline.restore(); }
  });
});
