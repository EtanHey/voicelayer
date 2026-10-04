/**
 * Unix domain socket client for VoiceLayer → VoiceBar communication.
 *
 * Connects to VoiceBar's persistent server at /tmp/voicelayer.sock.
 * Broadcasts NDJSON state events, receives commands.
 * Auto-reconnects with exponential backoff if VoiceBar restarts.
 *
 * AIDEV-NOTE: This replaces socket-server.ts. The API surface is identical
 * (broadcast, onCommand, isConnected) — only the direction is inverted.
 * MCP servers are now clients; VoiceBar is the server.
 */

import {
  serializeEvent,
  parseCommand,
  type SocketEvent,
  type SocketCommand,
  type SocketResponse,
} from "./socket-protocol";
import { existsSync } from "fs";
import { SOCKET_PATH, getMcpSocketOverridePath } from "./paths";
import { NDJSONByteFramer } from "./ndjson-byte-framer";
import { SocketOutboundQueue } from "./socket-outbound-queue";

// --- Connection state ---

let connection: ReturnType<typeof Bun.connect> extends Promise<infer T>
  ? T
  : never;
let connected = false;
let outbound: SocketOutboundQueue | null = null;
let intentionallyClosed = false;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectDelay = 1000; // Start at 1s, backoff to 15s max
const MAX_RECONNECT_DELAY = 15000;
let keepaliveTimer: ReturnType<typeof setInterval> | null = null;
const KEEPALIVE_INTERVAL_MS = 30_000;
let connectionOptions: VoiceBarConnectionOptions = {};

export interface VoiceBarConnectionOptions {
  role?: "mcp-server" | "mcp-daemon" | "standalone-daemon" | "test";
  acceptsCommands?: boolean;
  onConnected?: () => void;
}

// A History AVAudioPlayer lives in VoiceBar, outside the daemon queue. Ask must
// request its synchronous stop receipt, without making Ask depend on the app.
const historyGates = new Map<string, {
  busy: boolean; announced?: boolean; ready?: () => void; unavailable?: (reason: string) => void;
}>();

export async function withHistoryPlaybackSuspended<T>(work: () => Promise<T>): Promise<T> {
  const id = crypto.randomUUID();
  const gate: { busy: boolean; announced?: boolean; ready?: () => void; unavailable?: (reason: string) => void } = { busy: true };
  historyGates.set(id, gate);
  try {
    if (!connected) {
      console.warn("[socket-client] History stop unavailable: VoiceBar disconnected; proceeding with Ask");
    } else {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
          gate.unavailable?.("VoiceBar did not confirm History playback stopped");
        }, 1000);
        const clear = () => {
          clearTimeout(timer);
          gate.ready = undefined;
          gate.unavailable = undefined;
        };
        gate.ready = () => { clear(); resolve(); };
        gate.unavailable = reason => {
          console.warn(`[socket-client] History stop unavailable: ${reason}; proceeding with Ask`);
          clear(); resolve();
        };
        gate.announced = true;
        broadcast({ type: "history_playback_gate", id, busy: true });
      });
    }
    return await work();
  } finally {
    gate.busy = false;
    if (!gate.announced) historyGates.delete(id);
    else if (connected) broadcast({ type: "history_playback_gate", id, busy: false });
    // Keep release receipts until acknowledged, including across reconnect.
    else if (!existsSync(targetPath)) historyGates.delete(id);
  }
}

function releaseHistoryGateWaiters(): void {
  for (const gate of historyGates.values()) {
    gate.unavailable?.("VoiceBar disconnected before History playback stopped");
  }
}

// --- Command handler callback ---
let commandHandler:
  | ((
      command: SocketCommand,
    ) => void | SocketResponse | Promise<void | SocketResponse>)
  | null = null;

// --- Target socket path (overridable for tests) ---
let targetPath: string = SOCKET_PATH;

/**
 * Connect to VoiceBar's Unix domain socket server.
 * Auto-reconnects with exponential backoff if the connection drops.
 *
 * @param path Optional socket path override (for testing). Defaults to SOCKET_PATH.
 */
export function connectToBar(
  path?: string,
  options: VoiceBarConnectionOptions = {},
): void {
  if (connected || (connection && !intentionallyClosed)) return;

  intentionallyClosed = false;
  if (path) targetPath = path;
  connectionOptions = options;

  startConnection();
}

/**
 * Disconnect from VoiceBar. Stops auto-reconnect.
 */
export function disconnectFromBar(): void {
  intentionallyClosed = true;
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  if (connection) {
    outbound?.close();
    outbound = null;
    try {
      connection.end();
    } catch {}
    connection = null as any;
  }
  connected = false;
  releaseHistoryGateWaiters();
  reconnectDelay = 1000;
}

/**
 * Broadcast an event to VoiceBar.
 * No-op if not connected.
 */
export function broadcast(event: SocketEvent): void {
  if (!connected || !outbound) return;
  const payload = serializeEvent(event);
  outbound.enqueue(payload);
}

/**
 * Register a handler for commands received from VoiceBar.
 * Only one handler is supported — last one wins.
 */
export function onCommand(
  handler: (
    command: SocketCommand,
  ) => void | SocketResponse | Promise<void | SocketResponse>,
): void {
  commandHandler = handler;
}

/**
 * Check if connected to VoiceBar.
 */
export function isConnected(): boolean {
  return connected;
}

// --- Internal: establish connection ---

function startConnection(): void {
  Bun.connect<{
    framer: NDJSONByteFramer;
    pendingResponses: Set<Promise<void>>;
    overflowed: boolean;
    writer: SocketOutboundQueue;
  }>({
    unix: targetPath,
    socket: {
      open(socket) {
        socket.data = {
          framer: new NDJSONByteFramer(), pendingResponses: new Set(), overflowed: false,
          writer: new SocketOutboundQueue(socket, "socket-client", undefined, () => {
            if (outbound !== socket.data.writer) return;
            outbound = null;
            connected = false;
            connection = null as any;
            releaseHistoryGateWaiters();
            stopKeepalive();
            scheduleReconnect();
          }),
        };
        connection = socket as any;
        outbound = socket.data.writer;
        connected = true;
        reconnectDelay = 1000; // Reset backoff on successful connect
        startKeepalive();
        writeClientHello(socket.data.writer);
        for (const [id, gate] of historyGates) {
          gate.announced = true;
          broadcast({ type: "history_playback_gate", id, busy: gate.busy });
        }
        connectionOptions.onConnected?.();
        console.error(`[socket-client] Connected to VoiceBar at ${targetPath}`);
      },

      data(socket, raw) {
        if (socket.data.overflowed) return;
        const { lines, overflow } = socket.data.framer.append(raw);

        for (const line of lines) {
          if (line.trim().length === 0) continue;
          const command = parseCommand(line);
          if (command?.cmd === "history_playback_ready") {
            const gate = historyGates.get(command.id);
            if (gate?.busy) gate.ready?.();
            else historyGates.delete(command.id);
            continue;
          }
          if (command) {
            console.error(
              `[socket-client] Command from VoiceBar: ${JSON.stringify(command)}`,
            );
            if (commandHandler) {
              const responsePromise = commandHandler(command);
              const reloadsModel =
                (command.cmd === "set_whisper_residency" && command.action === "load") ||
                command.cmd === "set_whisper_effort";
              if (reloadsModel && responsePromise instanceof Promise &&
                  connection && connected) {
                try {
                  socket.data.writer.enqueue(JSON.stringify({
                    type: "ack", command: command.cmd, id: command.id,
                    outcome: "loading",
                  }) + "\n");
                } catch (error) {
                  console.error(`[socket-client] Residency loading ack failed: ${String(error)}`);
                }
              }
              const pending = Promise.resolve(responsePromise)
                .then((response) => {
                  if (!response || !connection || !connected) {
                    if (command.cmd === "set_whisper_residency") {
                      console.error(`[socket-client] Residency response ${command.id} dropped: disconnected`);
                    }
                    return;
                  }
                  try {
                    socket.data.writer.enqueue(JSON.stringify(response) + "\n");
                    if (command.cmd === "set_whisper_residency" && response.type === "ack") {
                      console.error(
                        `[socket-client] Residency response ${command.id} written outcome=${response.outcome}`,
                      );
                    }
                  } catch (err) {
                    console.error(
                      `[socket-client] Failed to write response: ${err instanceof Error ? err.message : String(err)}`,
                    );
                  }
                })
                .catch((error) => {
                  console.error(
                    `[socket-client] Command handler failed: ${
                      error instanceof Error ? error.message : String(error)
                    }`,
                  );
                })
                .finally(() => socket.data.pendingResponses.delete(pending));
              socket.data.pendingResponses.add(pending);
            }
          } else {
            console.error(`[socket-client] Invalid command: ${line}`);
          }
        }
        if (overflow) {
          socket.data.overflowed = true;
          console.error("[socket-client] NDJSON command exceeded byte limit; closing connection");
          // Allow dispatched replies to enter and leave the queue before closing.
          let timer: ReturnType<typeof setTimeout>;
          Promise.race([
            Promise.allSettled([...socket.data.pendingResponses])
              .then(() => socket.data.writer.whenEmpty()),
            new Promise<void>((resolve) => { timer = setTimeout(resolve, 5_000); }),
          ]).finally(() => {
            clearTimeout(timer);
            socket.end(); // close() runs the existing reconnect path
          });
        }
      },

      close(socket) {
        socket.data.writer.close();
        if (outbound === socket.data.writer) {
          outbound = null;
          connected = false;
          connection = null as any;
          releaseHistoryGateWaiters();
          stopKeepalive();
          scheduleReconnect();
        }
        console.error("[socket-client] Disconnected from VoiceBar");
      },

      error(socket, error) {
        socket.data?.writer?.close();
        if (outbound === socket.data?.writer) {
          outbound = null;
          connected = false;
          connection = null as any;
          releaseHistoryGateWaiters();
          stopKeepalive();
          scheduleReconnect();
        }
        console.error(`[socket-client] Error: ${error.message}`);
      },

      drain(socket) { socket.data.writer.drain(); },

      connectError(_socket, error) {
        console.error(`[socket-client] Connect failed: ${error.message}`);
        connected = false;
        connection = null as any;
        scheduleReconnect();
      },
    },
  }).catch(() => {
    // Bun.connect throws if socket file doesn't exist
    scheduleReconnect();
  });
}

function writeClientHello(target: SocketOutboundQueue): void {
  const hello = {
    type: "client_hello",
    pid: process.pid,
    role: connectionOptions.role ?? "mcp-server",
    accepts_commands: connectionOptions.acceptsCommands === true,
    mcp_socket_path: getMcpSocketOverridePath(),
    voicebar_socket_path: targetPath,
  };
  try {
    target.enqueue(JSON.stringify(hello) + "\n");
  } catch {}
}

// --- Internal: reconnection with backoff ---

function scheduleReconnect(): void {
  if (intentionallyClosed) return;
  if (reconnectTimer) return; // Already scheduled

  const delay = reconnectDelay;
  reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY);

  console.error(
    `[socket-client] Reconnecting in ${delay}ms (next: ${reconnectDelay}ms)`,
  );

  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    if (!intentionallyClosed) {
      startConnection();
    }
  }, delay);
}

// --- Keepalive: periodic ping to detect dead connections ---

function startKeepalive(): void {
  stopKeepalive();
  keepaliveTimer = setInterval(() => {
    if (!connected || !outbound) {
      stopKeepalive();
      return;
    }
    try {
      // Send lightweight ping event — VoiceBar ignores unknown event types
      outbound.enqueue('{"type":"ping"}\n');
    } catch {
      // Write failed — connection is dead, trigger reconnect
      console.error("[socket-client] Keepalive write failed — connection dead");
      connected = false;
      connection = null as any;
      stopKeepalive();
      scheduleReconnect();
    }
  }, KEEPALIVE_INTERVAL_MS);
}

function stopKeepalive(): void {
  if (keepaliveTimer) {
    clearInterval(keepaliveTimer);
    keepaliveTimer = null;
  }
}

// --- Graceful shutdown ---

function cleanup() {
  stopKeepalive();
  disconnectFromBar();
}

process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);
