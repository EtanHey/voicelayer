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
  shouldSendMcpNotification,
  type McpLoggingLevel,
  type McpNotification,
} from "./mcp-notifications";
import {
  onConnect,
  onDisconnect,
  isPingRequest,
  buildPongResponse,
} from "./daemon-health";
import { MAX_NDJSON_LINE_BYTES, NDJSONByteFramer } from "./ndjson-byte-framer";
import { SocketOutboundQueue } from "./socket-outbound-queue";

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
  decoder: TextDecoder;
  unknownRaw: Buffer;
  unknownBytes: number;
  unknownHadLeadingWhitespace: boolean;
  ndjsonFramer: NDJSONByteFramer;
  oversized: boolean;
  pendingResponses: Set<Promise<void>>;
  disconnected: boolean;
  loggingLevel?: McpLoggingLevel;
  writer: SocketOutboundQueue;
}

/**
 * Check if an existing socket is actively being listened on.
 * Tries to connect — if connection succeeds, another daemon is alive.
 * Returns true if socket is live (another instance is running).
 */
export async function isSocketLive(socketPath: string): Promise<boolean> {
  if (!existsSync(socketPath)) return false;
  try {
    await Bun.connect({
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
        socket.data = {
          protocol: "unknown", buffer: "", decoder: new TextDecoder(),
          unknownRaw: Buffer.alloc(0), unknownBytes: 0, ndjsonFramer: new NDJSONByteFramer(),
          unknownHadLeadingWhitespace: false,
          oversized: false, pendingResponses: new Set(), disconnected: false,
          writer: new SocketOutboundQueue(socket, "mcp-daemon", undefined, () => {
            if (!socket.data.disconnected) {
              socket.data.disconnected = true;
              onDisconnect();
            }
          }),
        };
        onConnect();
      },

      data(socket, raw) {
        if (socket.data.oversized) return;
        if (socket.data.protocol === "mcp") {
          // Content-Length counts body bytes after streaming UTF-8 decoding.
          socket.data.buffer += socket.data.decoder.decode(raw, { stream: true });
          handleMcpData(socket);
          return;
        }
        if (socket.data.protocol === "ndjson") {
          handleNdjsonBytes(socket, raw);
          return;
        }

        // Keep raw bytes until detection: the first read can also contain part of a
        // UTF-8 NDJSON line. The decoded probe is used only for protocol selection.
        socket.data.buffer += socket.data.decoder.decode(raw, { stream: true });
        // Whitespace-only reads carry no protocol information. Discard their
        // decoded probe text so detection does not rescan a growing prefix.
        if (socket.data.buffer.length > 0 && socket.data.buffer.trimStart().length === 0) {
          socket.data.unknownHadLeadingWhitespace = true;
          socket.data.buffer = "";
        }
        socket.data.protocol = detectProtocol(socket.data.buffer);
        // Content-Length framing requires the header at byte zero. A prior
        // whitespace-only read cannot make a later header valid.
        if (socket.data.unknownHadLeadingWhitespace && socket.data.protocol === "mcp") {
          socket.data.protocol = "unknown";
        }
        if (socket.data.protocol === "unknown") {
          const needed = socket.data.unknownBytes + raw.byteLength;
          if (needed > MAX_NDJSON_LINE_BYTES) {
            closeOversizedClient(socket);
            return;
          }
          if (needed > socket.data.unknownRaw.length) {
            const capacity = Math.min(MAX_NDJSON_LINE_BYTES, Math.max(4096, needed, socket.data.unknownRaw.length * 2));
            const next = Buffer.allocUnsafe(capacity);
            socket.data.unknownRaw.copy(next, 0, 0, socket.data.unknownBytes);
            socket.data.unknownRaw = next;
          }
          socket.data.unknownRaw.set(raw, socket.data.unknownBytes);
          socket.data.unknownBytes = needed;
          return;
        }
        if (socket.data.protocol === "mcp") {
          socket.data.unknownRaw = Buffer.alloc(0);
          socket.data.unknownBytes = 0;
          handleMcpData(socket);
          return;
        }

        const prior = socket.data.unknownRaw.subarray(0, socket.data.unknownBytes);
        socket.data.unknownRaw = Buffer.alloc(0);
        socket.data.unknownBytes = 0;
        socket.data.buffer = "";
        if (prior.length > 0) handleNdjsonBytes(socket, prior);
        if (!socket.data.oversized) handleNdjsonBytes(socket, raw);
      },

      close(socket) {
        socket.data.writer.close();
        if (!socket.data.disconnected) {
          socket.data.disconnected = true;
          onDisconnect();
        }
      },
      error(socket) {
        socket.data.writer.close();
        if (!socket.data.disconnected) {
          socket.data.disconnected = true;
          onDisconnect();
        }
      },
      drain(socket) { socket.data.writer.drain(); },
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
        {
          sendNotification(notification: McpNotification) {
            if (
              !shouldSendMcpNotification(
                notification,
                socket.data.loggingLevel,
              )
            ) {
              return;
            }
            const frame = serializeMcpFrame({
              jsonrpc: "2.0",
              ...notification,
            });
            socket.data.writer.enqueue(frame);
          },
          setLoggingLevel(level: McpLoggingLevel) {
            socket.data.loggingLevel = level;
          },
        },
      )
        .then((response) => {
          if (response) {
            const frame = serializeMcpFrame(
              response as unknown as Record<string, unknown>,
            );
            try {
              socket.data.writer.enqueue(frame);
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
            socket.data.writer.enqueue(errResponse);
          } catch {
            // Client already gone
          }
        });
    }
  }

  function handleNdjsonBytes(socket: {
    data: ClientState;
    write: (data: string) => number;
    end: () => void;
  }, raw: Uint8Array) {
    const { lines, overflow } = socket.data.ndjsonFramer.append(raw);

    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);

        // Health check: ping → pong
        if (isPingRequest(msg)) {
          const pong = buildPongResponse();
          try {
            socket.data.writer.enqueue(JSON.stringify(pong) + "\n");
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
          const pending = handleMcpRequest(
            msg as {
              jsonrpc: string;
              id?: number | string;
              method: string;
              params?: Record<string, unknown>;
            },
            toolExecutor,
            {
              sendNotification(notification: McpNotification) {
                if (
                  !shouldSendMcpNotification(
                    notification,
                    socket.data.loggingLevel,
                  )
                ) {
                  return;
                }
                socket.data.writer.enqueue(
                  `${JSON.stringify({ jsonrpc: "2.0", ...notification })}\n`,
                );
              },
              setLoggingLevel(level: McpLoggingLevel) {
                socket.data.loggingLevel = level;
              },
            },
          )
            .then((response) => {
              if (response) {
                try {
                  socket.data.writer.enqueue(JSON.stringify(response) + "\n");
                } catch {}
              }
            })
            .catch((err) => {
              console.error(`[mcp-daemon] MCP-over-NDJSON error: ${err}`);
              try {
                socket.data.writer.enqueue(
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
            })
            .finally(() => socket.data.pendingResponses.delete(pending));
          socket.data.pendingResponses.add(pending);
          continue;
        }

        onNdjsonMessage?.(msg);
      } catch {
        // Invalid JSON line — skip
      }
    }
    if (overflow) closeOversizedClient(socket);
  }

  function closeOversizedClient(socket: { data: ClientState; end: () => void }) {
    socket.data.oversized = true;
    socket.data.buffer = "";
    socket.data.unknownRaw = Buffer.alloc(0);
    socket.data.unknownBytes = 0;
    console.error("[mcp-daemon] NDJSON message exceeded byte limit; closing client");
    let timer: ReturnType<typeof setTimeout>;
    Promise.race([
      Promise.allSettled([...socket.data.pendingResponses])
        .then(() => socket.data.writer.whenEmpty()),
      new Promise<void>((resolve) => { timer = setTimeout(resolve, 5_000); }),
    ]).finally(() => {
      clearTimeout(timer);
      socket.end();
    });
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
