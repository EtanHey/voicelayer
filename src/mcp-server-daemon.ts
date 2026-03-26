#!/usr/bin/env bun
/**
 * VoiceLayer MCP Daemon — persistent singleton replacing per-session MCP processes.
 *
 * Listens on /tmp/voicelayer-mcp.sock for MCP clients (via socat).
 * Connects to Voice Bar on /tmp/voicelayer.sock for UI state.
 *
 * Resilience features:
 * - Orphan socket detection (probe before remove)
 * - Startup validation (refuse if another instance holds socket)
 * - Socket permissions (chmod 600)
 * - Health ping/pong endpoint
 * - Log rotation at 10MB
 * - Graceful shutdown (SIGTERM → flush, close, remove socket, release PID lock)
 *
 * Usage:
 *   bun src/mcp-server-daemon.ts
 *
 * MCP client config (.mcp.json):
 *   "voicelayer": { "command": "socat", "args": ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"] }
 */

import { getBackend } from "./stt";
import { MCP_SOCKET_PATH } from "./paths";
import { connectToBar, disconnectFromBar, onCommand } from "./socket-client";
import { handleSocketCommand } from "./socket-handlers";
import { createMcpDaemon, isSocketLive } from "./mcp-daemon";
import { resolvePython3Path } from "./tts-health";
import { acquireProcessLock, releaseProcessLock } from "./process-lock";
import { startLogRotation, stopLogRotation } from "./log-rotation";
import {
  handleVoiceSpeak,
  handleVoiceAsk,
  handleAnnounce,
  handleBrief,
  handleConsult,
  handleConverse,
  handleThink,
  handleReplay,
  handleToggle,
} from "./handlers";

// --- Tool dispatch table ---

const toolDispatch: Record<
  string,
  (args: Record<string, unknown>) => Promise<{
    content: Array<{ type: string; text: string }>;
    isError?: boolean;
  }>
> = {
  voice_speak: handleVoiceSpeak,
  voice_ask: handleVoiceAsk,
  qa_voice_announce: handleAnnounce,
  qa_voice_brief: handleBrief,
  qa_voice_consult: handleConsult,
  qa_voice_converse: handleConverse,
  qa_voice_think: handleThink,
  qa_voice_replay: handleReplay,
  qa_voice_toggle: handleToggle,
  qa_voice_say: handleAnnounce,
  qa_voice_ask: handleConverse,
};

// --- Startup ---

async function main() {
  // Acquire process lock (kills orphans)
  const lockResult = acquireProcessLock();
  if (lockResult.killedStale) {
    console.error(
      `[voicelayer-daemon] Killed orphan MCP server (PID ${lockResult.stalePid})`,
    );
  }

  // Startup validation: refuse if another instance is actively listening
  if (await isSocketLive(MCP_SOCKET_PATH)) {
    console.error(
      `[voicelayer-daemon] FATAL: Another daemon is already listening on ${MCP_SOCKET_PATH}`,
    );
    console.error(
      `[voicelayer-daemon] If this is stale, remove the socket: rm ${MCP_SOCKET_PATH}`,
    );
    releaseProcessLock();
    process.exit(1);
  }

  // Start log rotation (10MB threshold, 60s interval)
  startLogRotation();

  // Resolve python3 path early — LaunchAgent PATH may not include it
  const python3 = resolvePython3Path();
  console.error(`[voicelayer-daemon] python3: ${python3}`);

  try {
    await getBackend();
  } catch (err: unknown) {
    console.error(
      `[voicelayer-daemon] Warning: no STT backend — converse mode will fail`,
    );
    console.error(
      `[voicelayer-daemon]   ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  // Connect to Voice Bar for UI state
  onCommand(handleSocketCommand);
  connectToBar();

  // Start MCP daemon (includes orphan socket cleanup and chmod 600)
  const daemon = await createMcpDaemon({
    socketPath: MCP_SOCKET_PATH,
    toolExecutor: {
      executeTool: async (name, args) => {
        const handler = toolDispatch[name];
        if (!handler) {
          return {
            content: [{ type: "text", text: `Unknown tool: ${name}` }],
            isError: true,
          };
        }
        return await handler(args);
      },
    },
    onNdjsonMessage: (msg) => {
      console.error(
        `[voicelayer-daemon] NDJSON message: ${JSON.stringify(msg)}`,
      );
    },
  });

  console.error(
    `[voicelayer-daemon] MCP daemon listening on ${MCP_SOCKET_PATH}`,
  );
  console.error(
    `[voicelayer-daemon] socat config: socat STDIO UNIX-CONNECT:${MCP_SOCKET_PATH}`,
  );

  // Graceful shutdown: flush, close, remove socket, release PID lock
  const shutdown = () => {
    console.error("[voicelayer-daemon] Shutting down...");
    stopLogRotation();
    daemon.stop();
    disconnectFromBar();
    releaseProcessLock();
    console.error("[voicelayer-daemon] Shutdown complete.");
    process.exit(0);
  };

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  console.error("[voicelayer-daemon] Fatal:", err);
  stopLogRotation();
  disconnectFromBar();
  releaseProcessLock();
  process.exit(1);
});
