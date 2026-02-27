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
import { existsSync, writeFileSync, unlinkSync } from "fs";
import { getBackend } from "./stt";
import {
  TTS_DISABLED_FILE,
  MIC_DISABLED_FILE,
  VOICE_DISABLED_FILE,
  STOP_FILE,
  writeDiscoveryFile,
  removeDiscoveryFile,
} from "./paths";
import { getHistoryEntry, playAudioNonBlocking } from "./tts";
import { waitForInput } from "./input";
import {
  startSocketServer,
  stopSocketServer,
  onCommand,
  broadcast,
} from "./socket-server";
import type { SocketCommand } from "./socket-protocol";
import { getToolDefinitions } from "./mcp-tools";
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
      `- voice_ask(message): BLOCKING. Waits for any playing voice_speak audio to finish, then speaks question, records mic, returns transcription. Session booking prevents mic conflicts. Stop: touch ${STOP_FILE} OR 5s silence.\n` +
      'Auto-mode detection: ends with ? → consult. length > 280 → brief. starts with "insight:" → think. default → announce.\n' +
      "voice_speak returns immediately (non-blocking). Audio plays in background. voice_ask auto-waits for it to finish before speaking.\n" +
      "replay=true on voice_ask speaks back last transcription before recording.\n" +
      "noise_floor param (default 0) filters low-confidence STT artifacts.\n" +
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

// --- Socket command handler ---

function handleSocketCommand(command: SocketCommand): void {
  switch (command.cmd) {
    case "stop":
    case "cancel":
      writeFileSync(
        STOP_FILE,
        `${command.cmd} from voice-bar at ${new Date().toISOString()}`,
      );
      try {
        Bun.spawnSync(["pkill", "-f", "afplay"]);
      } catch {}
      break;
    case "replay": {
      const entry = getHistoryEntry(0);
      if (entry && existsSync(entry.file)) {
        broadcast({ type: "state", state: "idle" });
        broadcast({
          type: "state",
          state: "speaking",
          text: entry.text.slice(0, 200),
        });
        playAudioNonBlocking(entry.file);
      }
      break;
    }
    case "record": {
      if (existsSync(MIC_DISABLED_FILE)) {
        broadcast({
          type: "error",
          message: "Mic is disabled",
          recoverable: false,
        });
        break;
      }
      const timeoutMs = (command.timeout_seconds ?? 30) * 1000;
      const silenceMode = command.silence_mode ?? "standard";
      const ptt = command.press_to_talk ?? false;
      waitForInput(timeoutMs, silenceMode, ptt).catch((err) => {
        console.error(
          `[voicelayer] Bar-initiated recording failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        broadcast({ type: "state", state: "idle" });
      });
      break;
    }
    case "toggle": {
      const { scope, enabled } = command;
      const flagFile =
        scope === "tts"
          ? TTS_DISABLED_FILE
          : scope === "mic"
            ? MIC_DISABLED_FILE
            : VOICE_DISABLED_FILE;
      if (enabled) {
        try {
          unlinkSync(flagFile);
        } catch {}
        if (scope === "all") {
          try {
            unlinkSync(TTS_DISABLED_FILE);
          } catch {}
          try {
            unlinkSync(MIC_DISABLED_FILE);
          } catch {}
        }
      } else {
        writeFileSync(
          flagFile,
          `disabled from flow-bar at ${new Date().toISOString()}`,
        );
      }
      break;
    }
  }
}

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

  startSocketServer();
  writeDiscoveryFile();
  onCommand(handleSocketCommand);

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(
    "[voicelayer] MCP server v2.0 running — modes: announce, brief, consult, converse, replay, toggle",
  );
  console.error("[voicelayer] Voice Bar socket server active");
}

// --- Graceful shutdown ---

process.on("SIGTERM", () => {
  removeDiscoveryFile();
  stopSocketServer();
});
process.on("SIGINT", () => {
  removeDiscoveryFile();
  stopSocketServer();
});

main().catch((err) => {
  console.error("[voicelayer] Fatal:", err);
  removeDiscoveryFile();
  stopSocketServer();
  process.exit(1);
});
