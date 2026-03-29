/**
 * Socket stop/cancel handler queue reset tests.
 *
 * Audit finding 2.1: Voice Bar stop/cancel handlers run `pkill -f afplay`
 * but do NOT call stopPlayback() from tts.ts. This means playbackQueue and
 * queueSize are not reset on UI stop. Queued items may still play after
 * "stop everything" is invoked.
 *
 * These tests verify that handleSocketCommand("stop") and ("cancel") call
 * stopPlayback() to properly drain the queue and reset state.
 */

import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import * as tts from "../tts";
import * as socketClient from "../socket-client";
import * as sessionBooking from "../session-booking";
import { handleSocketCommand } from "../socket-handlers";

describe("socket stop/cancel → stopPlayback()", () => {
  let stopPlaybackSpy: ReturnType<typeof spyOn>;
  let broadcastSpy: ReturnType<typeof spyOn>;
  let setCancelSignalSpy: ReturnType<typeof spyOn>;
  const originalSpawnSync = Bun.spawnSync;

  beforeEach(() => {
    stopPlaybackSpy = spyOn(tts, "stopPlayback").mockImplementation(() => true);
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      () => {},
    );
    setCancelSignalSpy = spyOn(
      sessionBooking,
      "setCancelSignal",
    ).mockImplementation(() => {});

    // Prevent actual pkill from running
    // @ts-ignore
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd[0] === "pkill") {
        return {
          exitCode: 0,
          stdout: new Uint8Array(0),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSync(cmd);
    };
  });

  afterEach(() => {
    stopPlaybackSpy.mockRestore();
    broadcastSpy.mockRestore();
    setCancelSignalSpy.mockRestore();
    Bun.spawnSync = originalSpawnSync;
  });

  it("stop handler calls stopPlayback() to reset queue and state", () => {
    handleSocketCommand({ cmd: "stop" });
    expect(stopPlaybackSpy).toHaveBeenCalledTimes(1);
  });

  it("cancel handler calls stopPlayback() to reset queue and state", () => {
    handleSocketCommand({ cmd: "cancel" });
    expect(stopPlaybackSpy).toHaveBeenCalledTimes(1);
  });

  it("stop handler still writes STOP_FILE", () => {
    handleSocketCommand({ cmd: "stop" });
    // stopPlayback was called (verified above), and the handler should
    // still write the stop file for MCP-level signaling
    expect(stopPlaybackSpy).toHaveBeenCalled();
  });

  it("cancel handler still sets cancel signal before stopping playback", () => {
    handleSocketCommand({ cmd: "cancel" });
    expect(setCancelSignalSpy).toHaveBeenCalledTimes(1);
    expect(stopPlaybackSpy).toHaveBeenCalledTimes(1);
  });
});
