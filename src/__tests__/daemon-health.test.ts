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

  it("isPingRequest detects ping messages", () => {
    expect(isPingRequest({ type: "ping" })).toBe(true);
    expect(isPingRequest({ type: "pong" })).toBe(false);
    expect(isPingRequest({ type: "state" })).toBe(false);
    expect(isPingRequest({})).toBe(false);
    expect(isPingRequest({ ping: true })).toBe(false);
  });
});
