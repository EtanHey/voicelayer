/**
 * Daemon health tracking — uptime, connection count, ping/pong.
 *
 * The MCP daemon exposes a health check via the socket protocol:
 *   Send: {"type": "ping"}
 *   Recv: {"type": "pong", "uptime_seconds": N, "connections": N}
 *
 * Connection tracking is maintained by the daemon socket server
 * via onConnect/onDisconnect callbacks.
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
}): {
  type: "health";
  uptime_seconds: number;
  queue_depth: number;
  recording_state: "idle" | "recording" | "transcribing";
} {
  return {
    type: "health",
    uptime_seconds: getUptimeSeconds(),
    queue_depth: health.queueDepth,
    recording_state: health.recordingState,
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
