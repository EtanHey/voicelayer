/**
 * Unix domain socket client for VoiceLayer → FlowBar communication.
 *
 * Connects to FlowBar's persistent server at /tmp/voicelayer.sock.
 * Broadcasts NDJSON state events, receives commands.
 * Auto-reconnects with exponential backoff if FlowBar restarts.
 *
 * AIDEV-NOTE: This replaces socket-server.ts. The API surface is identical
 * (broadcast, onCommand, isConnected) — only the direction is inverted.
 * MCP servers are now clients; FlowBar is the server.
 */

import {
  serializeEvent,
  parseCommand,
  type SocketEvent,
  type SocketCommand,
} from "./socket-protocol";
import { SOCKET_PATH } from "./paths";

// --- Connection state ---

let connection: ReturnType<typeof Bun.connect> extends Promise<infer T>
  ? T
  : never;
let connected = false;
let intentionallyClosed = false;
let buffer = "";
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectDelay = 1000; // Start at 1s, backoff to 15s max
const MAX_RECONNECT_DELAY = 15000;

// --- Command handler callback ---
let commandHandler: ((command: SocketCommand) => void) | null = null;

// --- Target socket path (overridable for tests) ---
let targetPath: string = SOCKET_PATH;

/**
 * Connect to FlowBar's Unix domain socket server.
 * Auto-reconnects with exponential backoff if the connection drops.
 *
 * @param path Optional socket path override (for testing). Defaults to SOCKET_PATH.
 */
export function connectToFlowBar(path?: string): void {
  if (connected || (connection && !intentionallyClosed)) return;

  intentionallyClosed = false;
  if (path) targetPath = path;

  startConnection();
}

/**
 * Disconnect from FlowBar. Stops auto-reconnect.
 */
export function disconnectFromFlowBar(): void {
  intentionallyClosed = true;
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  if (connection) {
    try {
      connection.end();
    } catch {}
    connection = null as any;
  }
  connected = false;
  buffer = "";
  reconnectDelay = 1000;
}

/**
 * Broadcast an event to FlowBar.
 * No-op if not connected.
 */
export function broadcast(event: SocketEvent): void {
  if (!connected || !connection) return;
  const payload = serializeEvent(event);
  try {
    connection.write(payload);
  } catch {
    // Connection may have died between check and write
  }
}

/**
 * Register a handler for commands received from FlowBar.
 * Only one handler is supported — last one wins.
 */
export function onCommand(handler: (command: SocketCommand) => void): void {
  commandHandler = handler;
}

/**
 * Check if connected to FlowBar.
 */
export function isConnected(): boolean {
  return connected;
}

// --- Internal: establish connection ---

function startConnection(): void {
  Bun.connect<{ buffer: string }>({
    unix: targetPath,
    socket: {
      open(socket) {
        socket.data = { buffer: "" };
        connection = socket as any;
        connected = true;
        buffer = "";
        reconnectDelay = 1000; // Reset backoff on successful connect
        console.error(`[socket-client] Connected to FlowBar at ${targetPath}`);
      },

      data(_socket, raw) {
        buffer += raw.toString("utf-8");
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";

        for (const line of lines) {
          if (line.trim().length === 0) continue;
          const command = parseCommand(line);
          if (command) {
            console.error(
              `[socket-client] Command from FlowBar: ${JSON.stringify(command)}`,
            );
            if (commandHandler) {
              commandHandler(command);
            }
          } else {
            console.error(`[socket-client] Invalid command: ${line}`);
          }
        }
      },

      close() {
        connected = false;
        connection = null as any;
        buffer = "";
        console.error("[socket-client] Disconnected from FlowBar");
        scheduleReconnect();
      },

      error(_socket, error) {
        console.error(`[socket-client] Error: ${error.message}`);
        connected = false;
        connection = null as any;
        buffer = "";
        scheduleReconnect();
      },

      drain() {},

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

// --- Graceful shutdown ---

function cleanup() {
  disconnectFromFlowBar();
}

process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);
