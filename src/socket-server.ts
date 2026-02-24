/**
 * Unix domain socket server for VoiceLayer ↔ Flow Bar communication.
 *
 * Creates a socket at /tmp/voicelayer.sock, broadcasts NDJSON state events
 * to all connected clients, and receives commands.
 *
 * AIDEV-NOTE: This runs alongside MCP StdioServerTransport on the same Bun
 * event loop. All logging goes to stderr (console.error) — stdout is reserved
 * for MCP JSON-RPC messages.
 *
 * Reference: docs.local/logs/research-3-bun-unix-socket.md
 */

import { existsSync, unlinkSync } from "fs";
import type { Socket } from "bun";
import { SOCKET_PATH } from "./paths";
import {
  serializeEvent,
  parseCommand,
  type SocketEvent,
  type SocketCommand,
} from "./socket-protocol";

// --- Per-socket state for NDJSON framing ---
type ClientData = {
  id: string;
  /** Accumulates partial TCP chunks for NDJSON line splitting. */
  buffer: string;
  /** Stores data waiting for drain when backpressure occurs. */
  pendingWrite: string | null;
};

// --- Client tracking ---
const clients = new Set<Socket<ClientData>>();

// --- Command handler callback ---
let commandHandler: ((command: SocketCommand) => void) | null = null;

// --- Server instance ---
// AIDEV-NOTE: Bun.listen() is lazy-initialized via startSocketServer().
// The server variable is null until start is called.
let server: ReturnType<typeof Bun.listen<ClientData>> | null = null;

/**
 * Start the Unix domain socket server.
 * Safe to call multiple times — subsequent calls are no-ops.
 */
export function startSocketServer(): void {
  if (server) return;

  // Clean up stale socket file from a previous crash
  if (existsSync(SOCKET_PATH)) {
    try {
      unlinkSync(SOCKET_PATH);
    } catch {
      // If we can't remove it, another process may own it
      console.error(
        `[socket] Warning: could not remove stale socket at ${SOCKET_PATH}`,
      );
    }
  }

  server = Bun.listen<ClientData>({
    unix: SOCKET_PATH,
    socket: {
      open(socket) {
        socket.data = {
          id: crypto.randomUUID(),
          buffer: "",
          pendingWrite: null,
        };
        clients.add(socket);
        console.error(
          `[socket] Client connected: ${socket.data.id} (${clients.size} total)`,
        );
      },

      data(socket, raw) {
        // Accumulate chunks and split on newlines for NDJSON framing
        socket.data.buffer += raw.toString("utf-8");
        const lines = socket.data.buffer.split("\n");
        // Last element is either "" (complete line) or a partial chunk
        socket.data.buffer = lines.pop() ?? "";

        for (const line of lines) {
          if (line.trim().length === 0) continue;
          const command = parseCommand(line);
          if (command) {
            console.error(
              `[socket] Command from ${socket.data.id}: ${JSON.stringify(command)}`,
            );
            if (commandHandler) {
              commandHandler(command);
            }
          } else {
            console.error(
              `[socket] Invalid command from ${socket.data.id}: ${line}`,
            );
          }
        }
      },

      drain(socket) {
        // Resume sending any data queued during backpressure
        if (socket.data.pendingWrite) {
          const wrote = socket.write(socket.data.pendingWrite);
          if (wrote === -1) {
            // Socket died while we were waiting
            socket.data.pendingWrite = null;
            return;
          }
          if (wrote >= socket.data.pendingWrite.length) {
            socket.data.pendingWrite = null;
          } else {
            socket.data.pendingWrite = socket.data.pendingWrite.slice(wrote);
          }
        }
      },

      close(socket, error) {
        clients.delete(socket);
        console.error(
          `[socket] Client disconnected: ${socket.data?.id ?? "unknown"}${error ? ` (${error.message})` : ""} (${clients.size} remaining)`,
        );
      },

      error(socket, error) {
        console.error(
          `[socket] Error on ${socket.data?.id ?? "unknown"}: ${error.message}`,
        );
        clients.delete(socket);
      },
    },
  });

  console.error(`[socket] Listening on ${SOCKET_PATH}`);
}

/**
 * Stop the socket server and clean up the socket file.
 */
export function stopSocketServer(): void {
  if (!server) return;
  server.stop(true); // true = close all active connections
  server = null;
  clients.clear();
  try {
    unlinkSync(SOCKET_PATH);
  } catch {}
  console.error("[socket] Server stopped");
}

/**
 * Broadcast an event to ALL connected Flow Bar clients.
 * No-op if no clients are connected or server isn't running.
 */
export function broadcast(event: SocketEvent): void {
  if (clients.size === 0) return;
  const payload = serializeEvent(event);
  for (const client of clients) {
    sendToClient(client, payload);
  }
}

/**
 * Register a handler for commands received from Flow Bar clients.
 * Only one handler is supported — last one wins.
 */
export function onCommand(handler: (command: SocketCommand) => void): void {
  commandHandler = handler;
}

/**
 * Get the number of connected clients.
 */
export function getClientCount(): number {
  return clients.size;
}

/**
 * Check if the socket server is running.
 */
export function isServerRunning(): boolean {
  return server !== null;
}

// --- Internal helpers ---

function sendToClient(client: Socket<ClientData>, payload: string): void {
  // If this client already has pending data, append to its queue
  if (client.data.pendingWrite) {
    client.data.pendingWrite += payload;
    return;
  }

  const wrote = client.write(payload);

  if (wrote === -1) {
    // Socket is dead — the close handler will clean up
    return;
  }

  if (wrote < payload.length) {
    // Backpressure: store the remainder for the drain handler
    client.data.pendingWrite = payload.slice(wrote);
  }
}

// --- Graceful shutdown ---

function cleanup() {
  stopSocketServer();
}

process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);
process.on("exit", () => {
  try {
    unlinkSync(SOCKET_PATH);
  } catch {}
});
