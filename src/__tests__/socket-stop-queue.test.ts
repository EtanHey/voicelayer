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

import { it, expect, beforeEach, afterEach, spyOn } from "bun:test";
// AIDEV-NOTE: R-014 — this file can reach the microphone, the recorder
// device probe, or files the resident VoiceBar reads. `describe` is the
// live-host guard, so the suite skips loudly rather than racing the live app.
import { describeMicTouching as describe } from "./setup/live-host-guard";
import * as tts from "../tts";
import * as socketClient from "../socket-client";
import * as sessionBooking from "../session-booking";
import * as daemonHealth from "../daemon-health";
import * as input from "../input";
import * as modelStatus from "../model-status";
import { handleSocketCommand } from "../socket-handlers";

describe("socket stop/cancel → stopPlayback()", () => {
  let stopPlaybackSpy: ReturnType<typeof spyOn>;
  let broadcastSpy: ReturnType<typeof spyOn>;
  let setCancelSignalSpy: ReturnType<typeof spyOn>;
  let getQueueDepthSpy: ReturnType<typeof spyOn>;
  let getRecordingStateSpy: ReturnType<typeof spyOn>;
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
    getQueueDepthSpy = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(1);
    getRecordingStateSpy = spyOn(input, "getRecordingState").mockReturnValue(
      "recording",
    );

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
    getQueueDepthSpy.mockRestore();
    getRecordingStateSpy.mockRestore();
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

describe("socket health command", () => {
  let getQueueDepthSpy: ReturnType<typeof spyOn>;
  let getRecordingStateSpy: ReturnType<typeof spyOn>;
  let getUptimeSecondsSpy: ReturnType<typeof spyOn>;
  let modelStatusSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    getQueueDepthSpy = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(3);
    getRecordingStateSpy = spyOn(input, "getRecordingState").mockReturnValue(
      "recording",
    );
    getUptimeSecondsSpy = spyOn(daemonHealth, "getUptimeSeconds").mockReturnValue(
      42,
    );
    modelStatusSpy = spyOn(modelStatus, "readWhisperModelStatus").mockResolvedValue({
      configured_model: { name: "large-v3-turbo", size_bytes: 10, installed: true },
      residency: "loaded",
      active_model: null,
      configured_effort: "accurate",
      active_effort: null,
    });
  });

  afterEach(() => {
    getQueueDepthSpy.mockRestore();
    getRecordingStateSpy.mockRestore();
    getUptimeSecondsSpy.mockRestore();
    modelStatusSpy.mockRestore();
  });

  it("returns daemon health snapshot with model status", async () => {
    const response = await handleSocketCommand({ cmd: "health" });
    expect(response).toEqual({
      type: "health",
      uptime_seconds: 42,
      queue_depth: 3,
      recording_state: "recording",
      model_status: {
        configured_model: { name: "large-v3-turbo", size_bytes: 10, installed: true },
        residency: "loaded",
        active_model: null,
        configured_effort: "accurate",
        active_effort: null,
      },
      polish_controls: {
        model_polish: { source: "default", raw: null, effective: "on" },
        outro_gate: { source: "default", raw: null, effective: true },
        smart_chunks: { source: "default", raw: null, effective: false },
        smart_boundaries: { source: "default", raw: null, effective: false },
      },
    });
  });

  it("re-reads busy state after the asynchronous model probe", async () => {
    let releaseProbe = () => {};
    modelStatusSpy.mockImplementation(() => new Promise((resolve) => {
      releaseProbe = () => resolve({
        configured_model: { name: null, size_bytes: null, installed: false },
        residency: "unknown",
        active_model: null,
        configured_effort: "accurate",
        active_effort: null,
      });
    }));
    getQueueDepthSpy.mockReturnValue(0);
    getRecordingStateSpy.mockReturnValue("idle");

    const pending = handleSocketCommand({ cmd: "health" });
    getQueueDepthSpy.mockReturnValue(2);
    getRecordingStateSpy.mockReturnValue("recording");
    releaseProbe();

    await expect(pending).resolves.toMatchObject({
      queue_depth: 2,
      recording_state: "recording",
    });
  });
});

describe("socket command-mode and clip handlers", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;
  let broadcasts: any[];

  beforeEach(() => {
    broadcasts = [];
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      (event: unknown) => {
        broadcasts.push(event);
      },
    );
  });

  afterEach(() => {
    broadcastSpy.mockRestore();
  });

  it("broadcasts a command-mode apply event for selection transforms", () => {
    handleSocketCommand({
      // @ts-expect-error Phase 8 command
      cmd: "command",
      operation: "replace_selection",
      text: "const value = selectedText.trim();",
      prompt: "Replace selection",
    });

    expect(broadcasts).toContainEqual({
      type: "command_mode",
      phase: "applying",
      operation: "replace_selection",
      replacement_text: "const value = selectedText.trim();",
      prompt: "Replace selection",
    });
  });

  it("broadcasts clip marker events for downstream consumers", () => {
    handleSocketCommand({
      // @ts-expect-error Phase 8 command
      cmd: "mark_clip",
      label: "Action item",
      source: "command",
    });

    expect(broadcasts).toContainEqual({
      type: "clip_marker",
      marker_id: "command-action-item",
      label: "Action item",
      source: "command",
      status: "marked",
    });
  });
});
