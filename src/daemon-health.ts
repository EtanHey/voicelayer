import type { WhisperModelStatus } from "./model-status";
import { readPolishControlsStatus, type PolishControlsStatus } from "./polish-controls-status";

/**
 * Daemon health tracking — uptime, connection count, ping/pong.
 *
 * The MCP daemon exposes a health check via the socket protocol:
 *   Send: {"type": "ping"}
 *   Recv: {"type": "pong", "uptime_seconds": N, "connections": N}
 *
 * Connection tracking is maintained by the daemon socket server
 * via onConnect/onDisconnect callbacks.
 *
 * THREAD-SAFETY: Assumes single-threaded event loop (Bun/Node.js).
 * onConnect/onDisconnect are called from socket event handlers which
 * are serialized by the event loop.
 */

const startTime = Date.now();

let activeConnections = 0;

/** Increment active connection count. Call on socket open. */
export function onConnect(): void {
  activeConnections++;
}

/** Decrement active connection count. Call on socket close. */
export function onDisconnect(): void {
  if (activeConnections > 0) activeConnections--;
}

/** Get current active connection count. */
export function getConnectionCount(): number {
  return activeConnections;
}

/** Get daemon uptime in seconds. */
export function getUptimeSeconds(): number {
  return Math.floor((Date.now() - startTime) / 1000);
}

/** Build a pong response for a ping request. */
export function buildPongResponse(): {
  type: "pong";
  uptime_seconds: number;
  connections: number;
} {
  return {
    type: "pong",
    uptime_seconds: getUptimeSeconds(),
    connections: getConnectionCount(),
  };
}

export function buildHealthResponse(health: {
  queueDepth: number;
  recordingState: "idle" | "recording" | "transcribing";
  modelStatus: WhisperModelStatus;
}, environment: Record<string, string | undefined> = process.env): {
  type: "health";
  uptime_seconds: number;
  queue_depth: number;
  recording_state: "idle" | "recording" | "transcribing";
  model_status: WhisperModelStatus;
  remote_stt_configured: boolean;
  polish_controls: PolishControlsStatus;
} {
  const preference = (environment.QA_VOICE_STT_BACKEND ?? "auto").toLowerCase();
  return {
    type: "health",
    uptime_seconds: getUptimeSeconds(),
    queue_depth: health.queueDepth,
    recording_state: health.recordingState,
    model_status: health.modelStatus,
    // A Wispr key enables cloud fallback in auto mode. Report configuration
    // from the daemon environment, even when a forced local mode currently
    // prevents selection, so the UI never overclaims local-only processing.
    remote_stt_configured: preference === "wispr" || Boolean(environment.QA_VOICE_WISPR_KEY),
    polish_controls: readPolishControlsStatus(),
  };
}

/** Check if a message is a ping request. */
export function isPingRequest(msg: Record<string, unknown>): boolean {
  return msg.type === "ping";
}

/** Reset health state (for testing). */
export function _resetForTest(): void {
  activeConnections = 0;
}
