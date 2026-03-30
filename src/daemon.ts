#!/usr/bin/env bun
/**
 * VoiceLayer Standalone Daemon — runs voice pipeline without MCP/Claude Code.
 *
 * Connects to Voice Bar on /tmp/voicelayer.sock as a client.
 * Handles commands: record, stop, cancel, replay, toggle.
 * Foundation for standalone dictation mode (replacing Wispr Flow).
 *
 * Usage:
 *   bun src/daemon.ts
 *   voicelayer serve
 *
 * AIDEV-NOTE: This file must NEVER import from @modelcontextprotocol, mcp-daemon,
 * mcp-server, mcp-handler, or mcp-tools. Those are MCP-specific. The daemon
 * reuses the same socket protocol and command handlers but operates independently.
 */

import { getBackend } from "./stt";
import { connectToBar, disconnectFromBar, onCommand } from "./socket-client";
import { handleSocketCommand } from "./socket-handlers";
import { resolvePython3Path } from "./tts-health";
import { acquireProcessLock, releaseProcessLock } from "./process-lock";
import { DAEMON_PID_FILE } from "./paths";

const LOG_PREFIX = "[voicelayer-serve]";

/**
 * Optional test/diagnostic override for the VoiceBar socket path.
 * Normal production usage still connects to the default well-known socket.
 */
export function getServeSocketPath(): string | undefined {
  const override = process.env.QA_VOICE_SOCKET_PATH?.trim();
  return override ? override : undefined;
}

export function createShutdownHandler(deps?: {
  disconnect?: () => void;
  releaseLock?: () => void;
  exit?: (code: number) => never | void;
}) {
  const disconnect = deps?.disconnect ?? disconnectFromBar;
  const releaseLock = deps?.releaseLock ?? (() => releaseProcessLock(DAEMON_PID_FILE));
  const exit = deps?.exit ?? process.exit;
  let shutDown = false;

  return () => {
    if (shutDown) return;
    shutDown = true;
    console.error(`${LOG_PREFIX} Shutting down...`);
    disconnect();
    releaseLock();
    console.error(`${LOG_PREFIX} Shutdown complete.`);
    exit(0);
  };
}

async function main() {
  // 1. Acquire daemon-specific process lock (separate from MCP PID)
  const lockResult = acquireProcessLock(DAEMON_PID_FILE);
  if (lockResult.killedStale) {
    console.error(
      `${LOG_PREFIX} Killed orphan daemon (PID ${lockResult.stalePid})`,
    );
  }

  // 2. Resolve python3 path early — needed for edge-tts
  try {
    const python3 = resolvePython3Path();
    console.error(`${LOG_PREFIX} python3: ${python3}`);
  } catch {
    console.error(`${LOG_PREFIX} Warning: python3 not found — TTS may fail`);
  }

  // 3. Init STT backend (warn but continue if unavailable)
  try {
    await getBackend();
    console.error(`${LOG_PREFIX} STT backend ready`);
  } catch (err: unknown) {
    console.error(
      `${LOG_PREFIX} Warning: no STT backend — recording will fail`,
    );
    console.error(
      `${LOG_PREFIX}   ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  // 4. Connect to Voice Bar for UI state + command handling
  onCommand(handleSocketCommand);
  connectToBar(getServeSocketPath());

  console.error(`${LOG_PREFIX} Standalone daemon ready (PID ${process.pid})`);
  console.error(
    `${LOG_PREFIX} Waiting for commands from Voice Bar on /tmp/voicelayer.sock`,
  );

  // 5. Graceful shutdown
  const shutdown = createShutdownHandler();

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  return shutdown;
}

if (import.meta.main) {
  main()
    .then((shutdown) => {
      // Keep process alive until signal
    })
    .catch((err) => {
      console.error(`${LOG_PREFIX} Fatal:`, err);
      const shutdown = createShutdownHandler();
      shutdown();
    });
}
