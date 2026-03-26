#!/usr/bin/env bun
/**
 * VoiceLayer MCP Daemon — persistent singleton replacing per-session MCP processes.
 *
 * Listens on /tmp/voicelayer-mcp.sock for MCP clients (via socat).
 * Connects to Voice Bar on /tmp/voicelayer.sock for UI state.
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
import { createMcpDaemon } from "./mcp-daemon";
import { resolvePython3Path } from "./tts-health";
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

  // Start MCP daemon
  const daemon = createMcpDaemon({
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

  // Graceful shutdown
  const shutdown = () => {
    console.error("[voicelayer-daemon] Shutting down...");
    daemon.stop();
    disconnectFromBar();
    process.exit(0);
  };

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  console.error("[voicelayer-daemon] Fatal:", err);
  disconnectFromBar();
  process.exit(1);
});
