/**
 * Tests for daemon health tracking — uptime, connections, ping/pong.
 */
import { describe, it, expect, beforeEach } from "bun:test";
import {
  onConnect,
  onDisconnect,
  getConnectionCount,
  getUptimeSeconds,
  buildPongResponse,
  buildHealthResponse,
  isPingRequest,
  _resetForTest,
} from "../daemon-health";

describe("daemon-health", () => {
  beforeEach(() => {
    _resetForTest();
  });

  it("tracks connection count", () => {
    expect(getConnectionCount()).toBe(0);
    onConnect();
    expect(getConnectionCount()).toBe(1);
    onConnect();
    expect(getConnectionCount()).toBe(2);
    onDisconnect();
    expect(getConnectionCount()).toBe(1);
    onDisconnect();
    expect(getConnectionCount()).toBe(0);
  });

  it("does not go below zero on extra disconnects", () => {
    onDisconnect();
    onDisconnect();
    expect(getConnectionCount()).toBe(0);
  });

  it("reports uptime in seconds", () => {
    const uptime = getUptimeSeconds();
    expect(typeof uptime).toBe("number");
    expect(uptime).toBeGreaterThanOrEqual(0);
  });

  it("builds pong response with correct shape", () => {
    onConnect();
    onConnect();
    const pong = buildPongResponse();
    expect(pong.type).toBe("pong");
    expect(typeof pong.uptime_seconds).toBe("number");
    expect(pong.connections).toBe(2);
  });

  it("reports remote STT configuration from the running daemon", () => {
    const base = {
      queueDepth: 0,
      recordingState: "idle" as const,
      modelStatus: {} as Parameters<typeof buildHealthResponse>[0]["modelStatus"],
    };
    expect(buildHealthResponse(base, { QA_VOICE_STT_BACKEND: "whisper" }).remote_stt_configured).toBe(false);
    expect(buildHealthResponse(base, { QA_VOICE_STT_BACKEND: "whisper", QA_VOICE_WISPR_KEY: "test-key" }).remote_stt_configured).toBe(true);
    expect(buildHealthResponse(base, { QA_VOICE_STT_BACKEND: "wispr" }).remote_stt_configured).toBe(true);
    expect(buildHealthResponse(base, { QA_VOICE_STT_BACKEND: "auto", QA_VOICE_WISPR_KEY: "test-key" }).remote_stt_configured).toBe(true);
    expect(buildHealthResponse(base, { QA_VOICE_STT_BACKEND: "auto" }).remote_stt_configured).toBe(false);
  });

  it("adds authoritative polish controls to the health payload", () => {
    const health = buildHealthResponse({
      queueDepth: 0,
      recordingState: "idle",
      modelStatus: {} as Parameters<typeof buildHealthResponse>[0]["modelStatus"],
    });
    expect(health.polish_controls.model_polish.effective).toBe("on");
    expect(health.polish_controls.outro_gate.effective).toBe(true);
    expect(health.polish_controls.smart_chunks.effective).toBe(false);
    expect(health.polish_controls.smart_boundaries.effective).toBe(false);
  });

  it("isPingRequest detects ping messages", () => {
    expect(isPingRequest({ type: "ping" })).toBe(true);
    expect(isPingRequest({ type: "pong" })).toBe(false);
    expect(isPingRequest({ type: "state" })).toBe(false);
    expect(isPingRequest({})).toBe(false);
    expect(isPingRequest({ ping: true })).toBe(false);
  });
});
