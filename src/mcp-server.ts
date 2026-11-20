#!/usr/bin/env bun
import { initializeVoiceGate } from "./update-gate-admission";
import { flushSpeechArchives, interruptLiveSpeech } from "./speech-archive-live";
import { stopPlayback, awaitCurrentPlayback } from "./tts";
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
  type LoggingMessageNotification,
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
  handleVoiceAskResults,
} from "./handlers";
import { AskDeliverySession, AskDeliveryStore, CALLER_META } from "./ask-delivery";
import { randomBytes } from "node:crypto";
import { handleMcpRequest } from "./mcp-handler";

// --- Server setup ---

const clientLifetime = new AbortController();
const callerCapability = randomBytes(32).toString("hex");
let outbox: AskDeliveryStore | undefined;
const delivery = new AskDeliverySession(() => outbox ??= new AskDeliveryStore());
const server = new Server(
  {
    name: "voicelayer",
    version: PACKAGE_VERSION,
  },
  {
    capabilities: { tools: {}, logging: {} },
    instructions:
      "Voice I/O layer for Claude Code. 3 tools:\n" +
      "- voice_ask_results: read retained Ask answers, newest or by archive_id; never opens the microphone.\n" +
      "- voice_speak(message): TTS. mode is auto-detected (announce=short update, brief=long explanation, consult=checkpoint question, think=silent log). Override with mode param.\n" +
      `- voice_ask(message): BLOCKING. Waits for any playing voice_speak audio to finish, then speaks question, records mic, returns transcription. Session booking prevents mic conflicts. Stop: touch ${STOP_FILE} OR 2.5s silence (thoughtful default).\n` +
      "  Captured audio is always kept. If a result includes an archive path, use VoiceBar History → Re-transcribe and do not ask the user to repeat.\n" +
      'Auto-mode detection: ends with ? → consult. length > 280 → brief. starts with "insight:" → think. default → announce.\n' +
      "voice_speak returns immediately (non-blocking). Audio plays in background. voice_ask auto-waits for it to finish before speaking.\n" +
      "Voice is disabled by default; user enables via /mcp or voice_speak's enabled parameter.",
  },
);

// --- Tool registration ---

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: getToolDefinitions(),
}));

// --- Tool dispatch ---

server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
  const onCancel = () => delivery.cancel(extra.requestId);
  extra.signal.addEventListener("abort", onCancel, { once: true });
  if (extra.signal.aborted) onCancel();
  try {
    const response = await handleMcpRequest({ ...request, jsonrpc: "2.0", id: extra.requestId,
      params: { ...request.params, _meta: { ...request.params._meta, [CALLER_META]: callerCapability } } }, {
      async executeTool(name, args, context) {
        if (name === "voice_ask") return handleVoiceAsk(args, context);
        if (name === "voice_speak") return handleVoiceSpeak(args, context);
        return handleVoiceAskResults(args);
      },
    }, {
      delivery, connection: "stdio", disconnectSignal: clientLifetime.signal,
      sendNotification(notification) {
        if (notification.method === "notifications/message") return server.sendLoggingMessage(notification.params as LoggingMessageNotification["params"], extra.sessionId);
        return extra.sendNotification(notification);
      },
    });
    if (!response?.result) throw new Error("Voice call interrupted; retained delivery remains recoverable on the next call.");
    return response.result;
  } finally { extra.signal.removeEventListener("abort", onCancel); }
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
  const send = transport.send.bind(transport);
  transport.send = async message => {
    if ("id" in message && !("method" in message)) delivery.writeAttempt(message.id);
    return send(message);
  };
  await server.connect(transport);

  // Bootstrap only after connection setup; even its first lock attempt stays off the pre-connect path.
  void Promise.resolve().then(() => initializeVoiceGate()).catch(() => {
    console.error("[update-gate] startup gate fault; continuing voice service; updates REFUSED");
  });

  console.error(
    `[voicelayer] MCP server v${PACKAGE_VERSION} running — modes: announce, brief, consult, converse, replay, toggle`,
  );
  console.error("[voicelayer] Connected to Voice Bar as client");
}

// --- Graceful shutdown ---

let shuttingDown = false;
async function shutdown(code: number): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  clientLifetime.abort();
  delivery.disconnect();
  stopPlayback();
  try { await awaitCurrentPlayback(); }
  catch { console.error("[speech] shutdown playback settlement incomplete"); }
  interruptLiveSpeech();
  await flushSpeechArchives();
  disconnectFromBar();
  process.exit(code);
}
process.on("SIGTERM", () => { void shutdown(0); });
process.on("SIGINT", () => { void shutdown(0); });
process.stdin.on("end", () => { void shutdown(0); });

main().catch(async (err) => {
  console.error("[voicelayer] Fatal:", err);
  await shutdown(1);
});
