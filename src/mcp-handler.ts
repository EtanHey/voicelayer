/**
 * MCP JSON-RPC request handler.
 *
 * Processes MCP protocol messages (initialize, tools/list, tools/call)
 * and returns JSON-RPC responses. Pure logic — no I/O or socket concerns.
 */

import type { SpeechControl } from "./speech-control";
import type { AskDeliveryHooks, AskDeliverySession } from "./ask-delivery";

import { getToolDefinitions } from "./mcp-tools";
import { formatError } from "./format-response";
import { PACKAGE_VERSION } from "./version";
import { MODERN_PROTOCOL, PROTOCOL_META, TASKS_EXTENSION } from "./mcp-protocol";
import {
  createVoiceToolContext,
  isMcpLoggingLevel,
  type McpNotification,
  type McpLoggingLevel,
  type VoiceToolContext,
} from "./mcp-notifications";

/** Known tool names from the server dispatch tables. */
const KNOWN_TOOLS = new Set(["voice_speak", "voice_ask", "voice_ask_results"]);

/** Tool execution context — injected by caller to decouple from actual handlers. */
export interface ToolExecutor {
  executeTool: (
    name: string,
    args: Record<string, unknown>,
    context: VoiceToolContext,
  ) => Promise<{
    content: Array<{ type: string; text: string }>;
    isError?: boolean;
  }>;
}

export interface McpRequestContext {
  connection?: VoiceToolContext["connection"];
  delivery?: AskDeliverySession;
  askDelivery?: AskDeliveryHooks;
  disconnectSignal?: AbortSignal;
  sendNotification(notification: McpNotification): void | Promise<void>;
  setLoggingLevel?(level: McpLoggingLevel): void;
}

/** MCP JSON-RPC request shape. */
export interface McpRequest {
  jsonrpc: string;
  id?: number | string;
  method: string;
  params?: Record<string, unknown>;
}

/** MCP JSON-RPC response shape. */
export interface McpResponse {
  jsonrpc: string;
  id: number | string;
  result?: Record<string, unknown>;
  error?: { code: number; message: string; data?: unknown };
}

/**
 * Handle an MCP JSON-RPC request and return the response.
 * Returns null for notifications (requests without an id).
 */
export async function handleMcpRequest(
  request: McpRequest,
  executor?: ToolExecutor,
  requestContext?: McpRequestContext,
  speechControl?: SpeechControl,
): Promise<McpResponse | null> {
  if (requestContext?.delivery) {
    const { delivery, ...rest } = requestContext;
    return delivery.run(request, (hooks, forward = request) =>
      handleMcpRequest(forward, executor, { ...rest, askDelivery: hooks }, speechControl));
  }
  // Notifications (no id) don't get responses
  if (request.id === undefined || request.id === null) {
    return null;
  }

  if (request.method === "voicelayer/speech" && speechControl) {
    try {
      return { jsonrpc: "2.0", id: request.id, result: await speechControl(request.params ?? {}) };
    } catch (error) {
      return { jsonrpc: "2.0", id: request.id, error: { code: -32000, message: error instanceof Error ? error.message : String(error) } };
    }
  }

  switch (request.method) {
    case "server/discover": {
      const meta = request.params?._meta;
      const requested = meta && typeof meta === "object" ? (meta as Record<string, unknown>)[PROTOCOL_META] : undefined;
      // Without a modern version this is not a modern probe: keep today's unknown-method answer.
      if (requested === undefined) {
        return { jsonrpc: "2.0", id: request.id, error: { code: -32601, message: `Method not found: ${request.method}` } };
      }
      if (requested !== MODERN_PROTOCOL) {
        return { jsonrpc: "2.0", id: request.id, error: { code: -32022, message: "Unsupported protocol version",
          data: { supported: [MODERN_PROTOCOL], requested } } };
      }
      return {
        jsonrpc: "2.0",
        id: request.id,
        result: {
          resultType: "complete",
          supportedVersions: [MODERN_PROTOCOL],
          capabilities: { tools: {}, logging: {}, extensions: { [TASKS_EXTENSION]: {} } },
          _meta: { "io.modelcontextprotocol/serverInfo": { name: "voicelayer", version: PACKAGE_VERSION } },
        },
      };
    }

    case "initialize":
      return {
        jsonrpc: "2.0",
        id: request.id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {}, logging: {} },
          serverInfo: {
            name: "voicelayer",
            version: PACKAGE_VERSION,
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

    case "logging/setLevel": {
      const level = request.params?.level;
      if (!isMcpLoggingLevel(level)) {
        return {
          jsonrpc: "2.0",
          id: request.id,
          error: {
            code: -32602,
            message: `Invalid logging level: ${String(level)}`,
          },
        };
      }

      requestContext?.setLoggingLevel?.(level);
      return {
        jsonrpc: "2.0",
        id: request.id,
        result: {},
      };
    }

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
        const requestMeta = params as {
          _meta?: { progressToken?: string | number };
        };
        const hooks = requestContext?.askDelivery;
        const send = requestContext?.sendNotification;
        const context = createVoiceToolContext(
          requestMeta._meta?.progressToken,
          // A call answered with a task has no live request: its progress token must not be used again.
          send && hooks?.notificationOpen ? notification => hooks.notificationOpen!(notification) ? send(notification) : undefined : send,
          requestContext?.connection,
        );
        const signals = [requestContext?.disconnectSignal, hooks?.signal].filter((signal): signal is AbortSignal => !!signal);
        // tasks/cancel ends the Ask through the same abort path a client disconnect uses.
        context.disconnectSignal = signals.length > 1 ? AbortSignal.any(signals) : signals[0];
        context.askDelivery = hooks;
        const result = await executor.executeTool(
          params.name,
          params.arguments ?? {},
          context,
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
