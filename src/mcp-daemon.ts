/**
 * MCP daemon — a Bun Unix socket server that accepts both MCP (Content-Length)
 * and NDJSON clients on the same socket.
 *
 * Protocol detection: first bytes of each connection determine the protocol.
 * - "Content-Length: " → MCP client (JSON-RPC over Content-Length framing)
 * - "{" or "[" → NDJSON client (existing VoiceBar protocol)
 *
 * This replaces N per-session bun MCP processes with one persistent daemon.
 *
 * Socket hygiene:
 * - Orphan socket detection: probes existing socket before removing
 * - Socket permissions: chmod 600 after creation
 * - Health ping/pong: {"type":"ping"} → {"type":"pong","uptime_seconds":N,"connections":N}
 * - Connection tracking: onConnect/onDisconnect for health reporting
 */

import { unlinkSync, chmodSync, existsSync } from "fs";
import {
  parseMcpFrames,
  serializeMcpFrame,
  detectProtocol,
} from "./mcp-framing";
import { handleMcpRequest, type ToolExecutor } from "./mcp-handler";
import {
  onConnect,
  onDisconnect,
  isPingRequest,
  buildPongResponse,
} from "./daemon-health";

export interface McpDaemonOptions {
  /** Unix socket path to listen on. */
  socketPath: string;
  /** Tool executor for tools/call dispatch. */
  toolExecutor?: ToolExecutor;
  /** Callback for NDJSON messages from non-MCP clients. */
  onNdjsonMessage?: (msg: Record<string, unknown>) => void;
}

interface ClientState {
  protocol: "mcp" | "ndjson" | "unknown";
  buffer: string;
}

/**
 * Check if an existing socket is actively being listened on.
 * Tries to connect — if connection succeeds, another daemon is alive.
 * Returns true if socket is live (another instance is running).
 */
export async function isSocketLive(socketPath: string): Promise<boolean> {
  if (!existsSync(socketPath)) return false;
  try {
    const socket = await Bun.connect({
      unix: socketPath,
      socket: {
        open(s) {
          s.end();
        },
        data() {},
        close() {},
        error() {},
        drain() {},
      },
    });
    // Connection succeeded — another instance is listening
    socket.end();
    return true;
  } catch {
    // Connection refused — orphan socket file
    return false;
  }
}

/**
 * Clean up an orphan socket file after verifying it's stale.
 * Returns true if a stale socket was removed.
 */
export async function cleanOrphanSocket(socketPath: string): Promise<boolean> {
  if (!existsSync(socketPath)) return false;

  const live = await isSocketLive(socketPath);
  if (live) return false; // Another instance is running

  try {
    unlinkSync(socketPath);
    console.error(`[mcp-daemon] Removed orphan socket: ${socketPath}`);
    return true;
  } catch {
    return false;
  }
}

/**
 * Create and start an MCP daemon on a Unix socket.
 * Returns a handle with a stop() method.
 *
 * Performs orphan socket cleanup before starting.
 * Sets socket permissions to 600 (owner only).
 * Tracks connections for health reporting.
 * Handles ping/pong health checks on NDJSON connections.
 */
export async function createMcpDaemon(options: McpDaemonOptions): Promise<{
  stop: () => void;
}> {
  const { socketPath, toolExecutor, onNdjsonMessage } = options;

  // Clean up orphan socket (probe before removing)
  await cleanOrphanSocket(socketPath);

  // If socket still exists after cleanup, another instance is live
  if (existsSync(socketPath)) {
    throw new Error(
      `Another MCP daemon instance is already listening on ${socketPath}`,
    );
  }

  const server = Bun.listen<ClientState>({
    unix: socketPath,
    socket: {
      open(socket) {
        socket.data = { protocol: "unknown", buffer: "" };
        onConnect();
      },

      data(socket, raw) {
        const chunk = raw.toString("utf-8");
        socket.data.buffer += chunk;

        // Detect protocol on first data
        if (socket.data.protocol === "unknown") {
          socket.data.protocol = detectProtocol(socket.data.buffer);
          if (socket.data.protocol === "unknown") {
            return; // Need more data
          }
        }

        if (socket.data.protocol === "mcp") {
          handleMcpData(socket);
        } else if (socket.data.protocol === "ndjson") {
          handleNdjsonData(socket);
        }
      },

      close() {
        onDisconnect();
      },
      error() {
        onDisconnect();
      },
      drain() {},
    },
  });

  // Set socket permissions to owner-only (chmod 600)
  try {
    chmodSync(socketPath, 0o600);
  } catch (err) {
    console.error(
      `[mcp-daemon] Warning: could not set socket permissions: ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  function handleMcpData(socket: {
    data: ClientState;
    write: (data: string) => number;
    end: () => void;
  }) {
    // AIDEV-NOTE: Parse in a loop — on error, parseMcpFrames returns early
    // with a remainder that may still contain valid frames. Re-parse until
    // no more data can be extracted.
    const allMessages: Record<string, unknown>[] = [];
    let keepParsing = true;
    while (keepParsing) {
      const { messages, remainder, error } = parseMcpFrames(socket.data.buffer);
      socket.data.buffer = remainder;
      allMessages.push(...messages);

      if (error) {
        // Malformed frame — log but keep connection alive.
        // Previously this closed the connection, which caused entire MCP
        // sessions to die on a single bad frame (e.g., buffered double
        // Content-Length from socat). Now we skip and continue.
        console.error(`[mcp-daemon] Frame parse error (skipping): ${error}`);
        // There might be valid frames after the error — keep parsing
        // unless buffer is empty
        keepParsing = socket.data.buffer.length > 0;
      } else {
        keepParsing = false;
      }
    }

    for (const msg of allMessages) {
      // Process each MCP request async with proper error handling
      handleMcpRequest(
        msg as {
          jsonrpc: string;
          id?: number | string;
          method: string;
          params?: Record<string, unknown>;
        },
        toolExecutor,
      )
        .then((response) => {
          if (response) {
            const frame = serializeMcpFrame(
              response as unknown as Record<string, unknown>,
            );
            try {
              socket.write(frame);
            } catch {
              // Client may have disconnected
            }
          }
        })
        .catch((err) => {
          console.error(`[mcp-daemon] Unhandled error: ${err}`);
          try {
            const errResponse = serializeMcpFrame({
              jsonrpc: "2.0",
              id: (msg as Record<string, unknown>).id ?? null,
              error: {
                code: -32603,
                message: `Internal error: ${err instanceof Error ? err.message : String(err)}`,
              },
            });
            socket.write(errResponse);
          } catch {
            // Client already gone
          }
        });
    }
  }

  function handleNdjsonData(socket: {
    data: ClientState;
    write: (data: string) => number;
    end: () => void;
  }) {
    const lines = socket.data.buffer.split("\n");
    socket.data.buffer = lines.pop() ?? "";

    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);

        // Health check: ping → pong
        if (isPingRequest(msg)) {
          const pong = buildPongResponse();
          try {
            socket.write(JSON.stringify(pong) + "\n");
          } catch {}
          continue;
        }

        // AIDEV-NOTE: MCP clients via socat sometimes arrive without Content-Length
        // framing, causing protocol detection to classify them as NDJSON.
        // Detect MCP-shaped messages and handle them as MCP requests.
        // Protocol stays "ndjson" so subsequent messages continue through
        // this handler (not handleMcpData which expects Content-Length).
        if (msg.jsonrpc === "2.0" && typeof msg.method === "string") {
          console.error(
            `[mcp-daemon] MCP-over-NDJSON request (method: ${msg.method})`,
          );
          handleMcpRequest(
            msg as {
              jsonrpc: string;
              id?: number | string;
              method: string;
              params?: Record<string, unknown>;
            },
            toolExecutor,
          )
            .then((response) => {
              if (response) {
                try {
                  socket.write(JSON.stringify(response) + "\n");
                } catch {}
              }
            })
            .catch((err) => {
              console.error(`[mcp-daemon] MCP-over-NDJSON error: ${err}`);
              try {
                socket.write(
                  JSON.stringify({
                    jsonrpc: "2.0",
                    id: msg.id ?? null,
                    error: {
                      code: -32603,
                      message: `Internal error: ${err instanceof Error ? err.message : String(err)}`,
                    },
                  }) + "\n",
                );
              } catch {}
            });
          continue;
        }

        onNdjsonMessage?.(msg);
      } catch {
        // Invalid JSON line — skip
      }
    }
  }

  return {
    stop() {
      server.stop(true);
      try {
        unlinkSync(socketPath);
      } catch {}
    },
  };
}
