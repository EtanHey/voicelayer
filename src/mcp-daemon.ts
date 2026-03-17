/**
 * MCP daemon — a Bun Unix socket server that accepts both MCP (Content-Length)
 * and NDJSON clients on the same socket.
 *
 * Protocol detection: first bytes of each connection determine the protocol.
 * - "Content-Length:" → MCP client (JSON-RPC over Content-Length framing)
 * - "{" or "[" → NDJSON client (existing VoiceBar protocol)
 *
 * This replaces N per-session bun MCP processes with one persistent daemon.
 */

import {
  parseMcpFrames,
  serializeMcpFrame,
  detectProtocol,
} from "./mcp-framing";
import { handleMcpRequest, type ToolExecutor } from "./mcp-handler";

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
 * Create and start an MCP daemon on a Unix socket.
 * Returns a handle with a stop() method.
 */
export function createMcpDaemon(options: McpDaemonOptions): {
  stop: () => void;
} {
  const { socketPath, toolExecutor, onNdjsonMessage } = options;

  // Clean up stale socket
  try {
    const { unlinkSync } = require("fs");
    unlinkSync(socketPath);
  } catch {}

  const server = Bun.listen<ClientState>({
    unix: socketPath,
    socket: {
      open(socket) {
        socket.data = { protocol: "unknown", buffer: "" };
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

      close() {},
      error() {},
      drain() {},
    },
  });

  function handleMcpData(socket: {
    data: ClientState;
    write: (data: string) => number;
  }) {
    const { messages, remainder } = parseMcpFrames(socket.data.buffer);
    socket.data.buffer = remainder;

    for (const msg of messages) {
      // Process each MCP request async
      handleMcpRequest(
        msg as {
          jsonrpc: string;
          id?: number | string;
          method: string;
          params?: Record<string, unknown>;
        },
        toolExecutor,
      ).then((response) => {
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
      });
    }
  }

  function handleNdjsonData(socket: { data: ClientState }) {
    const lines = socket.data.buffer.split("\n");
    socket.data.buffer = lines.pop() ?? "";

    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);
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
        const { unlinkSync } = require("fs");
        unlinkSync(socketPath);
      } catch {}
    },
  };
}
