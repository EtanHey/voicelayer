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
  type HealthResponse,
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
let commandHandler:
  | ((command: SocketCommand) => void | HealthResponse | Promise<void | HealthResponse>)
  | null = null;

// --- Target socket path (overridable for tests) ---
let targetPath: string = SOCKET_PATH;

/**
 * Connect to VoiceBar's Unix domain socket server.
 * Auto-reconnects with exponential backoff if the connection drops.
 *
 * @param path Optional socket path override (for testing). Defaults to SOCKET_PATH.
 */
export function connectToBar(path?: string): void {
  if (connected || (connection && !intentionallyClosed)) return;

  intentionallyClosed = false;
  if (path) targetPath = path;

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
 * Broadcast an event to VoiceBar.
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
 * Register a handler for commands received from VoiceBar.
 * Only one handler is supported — last one wins.
 */
export function onCommand(
  handler: (
    command: SocketCommand,
  ) => void | HealthResponse | Promise<void | HealthResponse>,
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
  Bun.connect<{ buffer: string }>({
    unix: targetPath,
    socket: {
      open(socket) {
        socket.data = { buffer: "" };
        connection = socket as any;
        connected = true;
        buffer = "";
        reconnectDelay = 1000; // Reset backoff on successful connect
        console.error(`[socket-client] Connected to VoiceBar at ${targetPath}`);
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
              `[socket-client] Command from VoiceBar: ${JSON.stringify(command)}`,
            );
            if (commandHandler) {
              Promise.resolve(commandHandler(command))
                .then((response) => {
                  if (!response || !connection || !connected) return;
                  try {
                    connection.write(JSON.stringify(response) + "\n");
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
                });
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
        console.error("[socket-client] Disconnected from VoiceBar");
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
  disconnectFromBar();
}

process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);
