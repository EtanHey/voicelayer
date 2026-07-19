#!/usr/bin/env bun
/**
 * VoiceLayer MCP Server — thin orchestrator.
 *
 * Tool definitions live in mcp-tools.ts, handler logic in handlers.ts.
 * This file wires MCP transport, socket server, and shutdown lifecycle.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { getBackend } from "./stt";
import { STOP_FILE } from "./paths";
import { connectToBar, disconnectFromBar, onCommand } from "./socket-client";
import { getToolDefinitions } from "./mcp-tools";
import { handleSocketCommand } from "./socket-handlers";
import { PACKAGE_VERSION } from "./version";
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
import { createVoiceToolContext } from "./mcp-notifications";

// --- Server setup ---

const server = new Server(
  {
    name: "voicelayer",
    version: PACKAGE_VERSION,
  },
  {
    capabilities: { tools: {}, logging: {} },
    instructions:
      "Voice I/O layer for Claude Code. 2 tools:\n" +
      "- voice_speak(message): TTS. mode is auto-detected (announce=short update, brief=long explanation, consult=checkpoint question, think=silent log). Override with mode param.\n" +
      `- voice_ask(message): BLOCKING. Waits for any playing voice_speak audio to finish, then speaks question, records mic, returns transcription. Session booking prevents mic conflicts. Stop: touch ${STOP_FILE} OR 2.5s silence (thoughtful default).\n` +
      'Auto-mode detection: ends with ? → consult. length > 280 → brief. starts with "insight:" → think. default → announce.\n' +
      "voice_speak returns immediately (non-blocking). Audio plays in background. voice_ask auto-waits for it to finish before speaking.\n" +
      "Voice is disabled by default; user enables via /mcp or toggle tool.\n" +
      "All qa_voice_* tool names still work (backward compat aliases).",
  },
);

// --- Tool registration ---

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: getToolDefinitions(),
}));

// --- Tool dispatch ---

server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
  const { name, arguments: args } = request.params;
  const progressToken = request.params._meta?.progressToken;
  const context = createVoiceToolContext(progressToken, (notification) =>
    extra.sendNotification(notification as never),
  );

  try {
    switch (name) {
      // Consolidated tools
      case "voice_speak":
        return await handleVoiceSpeak(args, context);
      case "voice_ask":
        return await handleVoiceAsk(args, context);
      // Backward-compat aliases
      case "qa_voice_announce":
        return await handleAnnounce(args, context);
      case "qa_voice_brief":
        return await handleBrief(args, context);
      case "qa_voice_consult":
        return await handleConsult(args, context);
      case "qa_voice_converse":
        return await handleConverse(args, context);
      case "qa_voice_think":
        return await handleThink(args);
      case "qa_voice_replay":
        return await handleReplay(args);
      case "qa_voice_toggle":
        return await handleToggle(args);
      // Aliases
      case "qa_voice_say":
        return await handleAnnounce(args, context);
      case "qa_voice_ask":
        return await handleConverse(args, context);
      default:
        return {
          content: [{ type: "text" as const, text: `Unknown tool: ${name}` }],
          isError: true,
        };
    }
  } catch (err: unknown) {
    return {
      content: [
        {
          type: "text" as const,
          text: `Error in ${name}: ${err instanceof Error ? err.message : String(err)}`,
        },
      ],
      isError: true,
    };
  }
});

// --- Startup ---

async function main() {
  try {
    await getBackend();
  } catch (err: unknown) {
    console.error(
      `[voicelayer] Warning: no STT backend available — converse mode will fail`,
    );
    console.error(
      `[voicelayer]   ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  onCommand(handleSocketCommand);
  connectToBar(undefined, { role: "mcp-server", acceptsCommands: false });

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(
    `[voicelayer] MCP server v${PACKAGE_VERSION} running — modes: announce, brief, consult, converse, replay, toggle`,
  );
  console.error("[voicelayer] Connected to Voice Bar as client");
}

// --- Graceful shutdown ---

process.on("SIGTERM", () => {
  disconnectFromBar();
  process.exit(0);
});
process.on("SIGINT", () => {
  disconnectFromBar();
  process.exit(0);
});

main().catch((err) => {
  console.error("[voicelayer] Fatal:", err);
  disconnectFromBar();
  process.exit(1);
});
