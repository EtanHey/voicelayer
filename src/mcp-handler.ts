/**
 * MCP JSON-RPC request handler.
 *
 * Processes MCP protocol messages (initialize, tools/list, tools/call)
 * and returns JSON-RPC responses. Pure logic — no I/O or socket concerns.
 */

import { getToolDefinitions } from "./mcp-tools";
import { formatError } from "./format-response";

/** Known tool names from mcp-server.ts dispatch table. */
const KNOWN_TOOLS = new Set([
  "voice_speak",
  "voice_ask",
  "qa_voice_announce",
  "qa_voice_brief",
  "qa_voice_consult",
  "qa_voice_converse",
  "qa_voice_think",
  "qa_voice_replay",
  "qa_voice_toggle",
  "qa_voice_say",
  "qa_voice_ask",
]);

/** Tool execution context — injected by caller to decouple from actual handlers. */
export interface ToolExecutor {
  executeTool: (
    name: string,
    args: Record<string, unknown>,
  ) => Promise<{
    content: Array<{ type: string; text: string }>;
    isError?: boolean;
  }>;
}

/** MCP JSON-RPC request shape. */
interface McpRequest {
  jsonrpc: string;
  id?: number | string;
  method: string;
  params?: Record<string, unknown>;
}

/** MCP JSON-RPC response shape. */
interface McpResponse {
  jsonrpc: string;
  id: number | string;
  result?: Record<string, unknown>;
  error?: { code: number; message: string };
}

/**
 * Handle an MCP JSON-RPC request and return the response.
 * Returns null for notifications (requests without an id).
 */
export async function handleMcpRequest(
  request: McpRequest,
  executor?: ToolExecutor,
): Promise<McpResponse | null> {
  // Notifications (no id) don't get responses
  if (request.id === undefined || request.id === null) {
    return null;
  }

  switch (request.method) {
    case "initialize":
      return {
        jsonrpc: "2.0",
        id: request.id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: {
            name: "voicelayer",
            version: "2.0.0",
          },
        },
      };

    case "tools/list":
      return {
        jsonrpc: "2.0",
        id: request.id,
        result: {
          tools: getToolDefinitions(),
        },
      };

    case "tools/call": {
      const params = request.params as {
        name: string;
        arguments?: Record<string, unknown>;
      };

      if (!params?.name) {
        return {
          jsonrpc: "2.0",
          id: request.id,
          result: {
            content: [
              {
                type: "text",
                text: formatError("tools/call", "Missing tool name"),
              },
            ],
            isError: true,
          },
        };
      }

      // Check if tool is known
      if (!KNOWN_TOOLS.has(params.name)) {
        return {
          jsonrpc: "2.0",
          id: request.id,
          result: {
            content: [
              {
                type: "text",
                text: formatError(params.name, "Unknown tool"),
              },
            ],
            isError: true,
          },
        };
      }

      // Execute via injected executor
      if (!executor) {
        return {
          jsonrpc: "2.0",
          id: request.id,
          result: {
            content: [
              {
                type: "text",
                text: formatError("mcp", "No tool executor available"),
              },
            ],
            isError: true,
          },
        };
      }

      try {
        const result = await executor.executeTool(
          params.name,
          params.arguments ?? {},
        );
        return {
          jsonrpc: "2.0",
          id: request.id,
          result: result as unknown as Record<string, unknown>,
        };
      } catch (err: unknown) {
        return {
          jsonrpc: "2.0",
          id: request.id,
          result: {
            content: [
              {
                type: "text",
                text: formatError(
                  params.name,
                  err instanceof Error ? err.message : String(err),
                ),
              },
            ],
            isError: true,
          },
        };
      }
    }

    default:
      return {
        jsonrpc: "2.0",
        id: request.id,
        error: {
          code: -32601,
          message: `Method not found: ${request.method}`,
        },
      };
  }
}
