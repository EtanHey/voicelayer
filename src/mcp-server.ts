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
import {
  startSocketServer,
  stopSocketServer,
  onCommand,
} from "./socket-server";
import { getToolDefinitions } from "./mcp-tools";
import { handleSocketCommand } from "./socket-handlers";
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

// --- Server setup ---

const server = new Server(
  {
    name: "voicelayer",
    version: "2.0.0",
  },
  {
    capabilities: { tools: {} },
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

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      // Consolidated tools
      case "voice_speak":
        return await handleVoiceSpeak(args);
      case "voice_ask":
        return await handleVoiceAsk(args);
      // Backward-compat aliases
      case "qa_voice_announce":
        return await handleAnnounce(args);
      case "qa_voice_brief":
        return await handleBrief(args);
      case "qa_voice_consult":
        return await handleConsult(args);
      case "qa_voice_converse":
        return await handleConverse(args);
      case "qa_voice_think":
        return await handleThink(args);
      case "qa_voice_replay":
        return await handleReplay(args);
      case "qa_voice_toggle":
        return await handleToggle(args);
      // Aliases
      case "qa_voice_say":
        return await handleAnnounce(args);
      case "qa_voice_ask":
        return await handleConverse(args);
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
  startSocketServer();

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(
    "[voicelayer] MCP server v2.0 running — modes: announce, brief, consult, converse, replay, toggle",
  );
  console.error("[voicelayer] Connected to Voice Bar as client");
}

// --- Graceful shutdown ---

process.on("SIGTERM", () => {
  stopSocketServer();
});
process.on("SIGINT", () => {
  stopSocketServer();
});

main().catch((err) => {
  console.error("[voicelayer] Fatal:", err);
  stopSocketServer();
  process.exit(1);
});
