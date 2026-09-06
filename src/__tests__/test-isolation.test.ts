/**
 * R-014 — test isolation on a live host.
 *
 * These are the two assertions that would have caught the 2026-09-06 incident:
 * three of Etan's live dictations cancelled seconds after a `bun test` run,
 * because the suite wrote stop/cancel signals and deleted ring-buffer audio at
 * the exact paths the resident VoiceBar was reading.
 */

import { describe, expect, it } from "bun:test";
import { mkdirSync, rmSync } from "fs";
import { join } from "path";
import {
  CANCEL_FILE,
  LOCK_FILE,
  MCP_SOCKET_PATH,
  MIC_DISABLED_FILE,
  SOCKET_PATH,
  STATE_DIR,
  STOP_FILE,
  TMP_ROOT,
  TTS_DISABLED_FILE,
  TTS_HISTORY_FILE,
  VOICE_DISABLED_FILE,
  defaultStateDir,
  getMcpSocketPath,
  getStateDir,
  getTmpRoot,
  getVoiceBarSocketPath,
  getVoiceDisabledFilePath,
  recordingHoldFilePath,
  recordingStateFilePath,
  retainedRecordingFilePath,
  ttsFilePath,
  ttsHistoryFilePath,
  recordingFilePath,
} from "../paths";
import {
  LIVE_HOST_SKIP_REASON,
  isBoundSocket,
  liveHostSkipReason,
} from "./setup/live-host-guard";
import {
  isFakeRecorderActive,
  resolveRecorderBinary,
} from "../recorder-binary";

const ISOLATION_ROOT = join(process.cwd(), ".test-tmp");

describe("R-014 preload isolates every VoiceLayer path", () => {
  it("declares itself isolated", () => {
    expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  });

  it("resolves every module-level signal, lock and socket path under .test-tmp/", () => {
    const paths: Record<string, string> = {
      TMP_ROOT,
      STATE_DIR,
      STOP_FILE,
      CANCEL_FILE,
      LOCK_FILE,
      SOCKET_PATH,
      MCP_SOCKET_PATH,
      TTS_HISTORY_FILE,
      TTS_DISABLED_FILE,
      MIC_DISABLED_FILE,
      VOICE_DISABLED_FILE,
    };
    for (const [name, value] of Object.entries(paths)) {
      expect(`${name}=${value}`).toStartWith(`${name}=${ISOLATION_ROOT}/`);
    }
  });

  it("resolves every path-producing helper under .test-tmp/ too", () => {
    const paths: Record<string, string> = {
      getTmpRoot: getTmpRoot(),
      getStateDir: getStateDir(),
      getVoiceBarSocketPath: getVoiceBarSocketPath(),
      getMcpSocketPath: getMcpSocketPath(),
      getVoiceDisabledFilePath: getVoiceDisabledFilePath(),
      recordingStateFilePath: recordingStateFilePath(),
      recordingHoldFilePath: recordingHoldFilePath(),
      retainedRecordingFilePath: retainedRecordingFilePath(),
      ttsFilePath: ttsFilePath(process.pid, 0),
      ttsHistoryFilePath: ttsHistoryFilePath(0),
      recordingFilePath: recordingFilePath(process.pid, 0),
    };
    for (const [name, value] of Object.entries(paths)) {
      expect(`${name}=${value}`).toStartWith(`${name}=${ISOLATION_ROOT}/`);
    }
  });

  it("keeps the recordings archive out of the real ~/.local/share tree", () => {
    const dir = process.env.QA_VOICE_RECORDINGS_DIR;
    expect(dir).toBeDefined();
    expect(dir as string).toStartWith(`${ISOLATION_ROOT}/`);
  });

  it("serves recorder spawns from the silence stub, not the microphone", () => {
    expect(isFakeRecorderActive()).toBe(true);
    expect(resolveRecorderBinary()).toBe(
      process.env.VOICELAYER_TEST_FAKE_REC_BIN as string,
    );
  });

  it("serves a whole capture from the stub — silence PCM, device never opened", async () => {
    const { startMicChunkStream } = await import("../input");
    const {
      detectNativeInputFormat,
      resetNativeInputFormatCache,
    } = await import("../audio-utils");

    // The device probe itself goes through the stub: `rec -n trim 0 0` used to
    // open the microphone on a cold cache — 160-220 ms with the mic live.
    resetNativeInputFormatCache();
    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 16000,
      channels: 1,
    });

    let bytes = 0;
    const handle = startMicChunkStream({
      onChunk: async (chunk) => {
        bytes += chunk.byteLength;
        return bytes < 4096 ? undefined : false;
      },
    });
    try {
      await Promise.race([handle.exited, Bun.sleep(3000)]);
    } finally {
      handle.stop();
      await handle.exited.catch(() => undefined);
    }

    expect(bytes).toBeGreaterThan(0);
  }, 10_000);

  it("opens the real device only when a test opts in by name", () => {
    const optedIn = { ...process.env, VOICELAYER_TEST_REAL_MIC: "1" };
    expect(isFakeRecorderActive(optedIn)).toBe(false);
  });

  it("refuses PATH rec when the stub is selected but has no binary", () => {
    expect(
      resolveRecorderBinary({
        VOICELAYER_TEST_FAKE_REC: "1",
      } as NodeJS.ProcessEnv),
    ).toBeNull();
  });

  it("env-taking helpers read the passed env's roots, not the frozen module consts", () => {
    expect(getVoiceBarSocketPath({} as NodeJS.ProcessEnv)).toBe(
      "/tmp/voicelayer.sock",
    );
    expect(
      getVoiceBarSocketPath({
        VOICELAYER_TMP_ROOT: "/isolated-root",
      } as NodeJS.ProcessEnv),
    ).toBe("/isolated-root/voicelayer.sock");
    expect(recordingStateFilePath({} as NodeJS.ProcessEnv)).toBe(
      join(defaultStateDir(), "recording-state.json"),
    );
    expect(SOCKET_PATH.startsWith(ISOLATION_ROOT)).toBe(true);
  });
});

describe("R-014 live-host guard", () => {
  it("skips loudly when a VoiceBar socket is bound at the default path and nothing is overridden", () => {
    const bareEnv: NodeJS.ProcessEnv = {};
    expect(
      liveHostSkipReason(bareEnv, {
        defaultSocketPath: "/tmp/voicelayer.sock",
        isBound: () => true,
      }),
    ).toBe(LIVE_HOST_SKIP_REASON);
  });

  it("recognises a real bound socket, not merely an existing file", async () => {
    const dir = join(ISOLATION_ROOT, `guard-${process.pid}`);
    mkdirSync(dir, { recursive: true });
    const socketPath = join(dir, "g.sock");
    const plainFile = join(dir, "not-a-socket");
    await Bun.write(plainFile, "");

    const server = Bun.listen({
      unix: socketPath,
      socket: { data() {} },
    });
    try {
      expect(isBoundSocket(socketPath)).toBe(true);
      expect(isBoundSocket(plainFile)).toBe(false);
      expect(
        liveHostSkipReason({}, { defaultSocketPath: socketPath }),
      ).toBe(LIVE_HOST_SKIP_REASON);
      expect(
        liveHostSkipReason({}, { defaultSocketPath: plainFile }),
      ).toBeNull();
    } finally {
      server.stop(true);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("does not skip once any isolation signal is present", () => {
    const live = {
      defaultSocketPath: "/tmp/voicelayer.sock",
      isBound: () => true,
    };
    expect(
      liveHostSkipReason({ VOICELAYER_TEST_ISOLATED: "1" }, live),
    ).toBeNull();
    expect(
      liveHostSkipReason({ VOICELAYER_SOCKET_PATH: "/x/v.sock" }, live),
    ).toBeNull();
    expect(
      liveHostSkipReason({ QA_VOICE_SOCKET_PATH: "/x/v.sock" }, live),
    ).toBeNull();
    expect(liveHostSkipReason({ VOICELAYER_TMP_ROOT: "/x" }, live)).toBeNull();
  });

  it("does not skip on a host with no VoiceBar listening", () => {
    expect(
      liveHostSkipReason({}, {
        defaultSocketPath: "/tmp/voicelayer.sock",
        isBound: () => false,
      }),
    ).toBeNull();
  });

  it("is inert under the preload — this very run is already isolated", () => {
    expect(liveHostSkipReason()).toBeNull();
  });
});
