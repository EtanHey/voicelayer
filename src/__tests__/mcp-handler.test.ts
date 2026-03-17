/**
 * Tests for MCP JSON-RPC handler logic.
 *
 * The handler processes MCP requests (initialize, tools/list, tools/call)
 * and returns MCP JSON-RPC responses. Pure functions — no I/O.
 *
 * TDD RED: these tests define behavior for src/mcp-handler.ts (doesn't exist yet).
 */
import { describe, it, expect } from "bun:test";
import { handleMcpRequest } from "../mcp-handler";
import { getToolDefinitions } from "../mcp-tools";

describe("mcp-handler", () => {
  describe("initialize", () => {
    it("returns serverInfo and capabilities", async () => {
      const request = {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "test-client", version: "1.0" },
        },
      };

      const response = await handleMcpRequest(request);

      expect(response.jsonrpc).toBe("2.0");
      expect(response.id).toBe(1);
      expect(response.result).toBeDefined();
      expect(response.result.protocolVersion).toBe("2024-11-05");
      expect(response.result.capabilities).toEqual({ tools: {} });
      expect(response.result.serverInfo.name).toBe("voicelayer");
      expect(response.result.serverInfo.version).toBeDefined();
    });

    it("echoes the request id", async () => {
      const response = await handleMcpRequest({
        jsonrpc: "2.0",
        id: 42,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "test", version: "1.0" },
        },
      });
      expect(response.id).toBe(42);
    });

    it("handles string id", async () => {
      const response = await handleMcpRequest({
        jsonrpc: "2.0",
        id: "abc-123",
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "test", version: "1.0" },
        },
      });
      expect(response.id).toBe("abc-123");
    });
  });

  describe("tools/list", () => {
    it("returns all tool definitions", async () => {
      const response = await handleMcpRequest({
        jsonrpc: "2.0",
        id: 2,
        method: "tools/list",
      });

      expect(response.jsonrpc).toBe("2.0");
      expect(response.id).toBe(2);
      expect(response.result).toBeDefined();
      expect(response.result.tools).toBeDefined();
      expect(Array.isArray(response.result.tools)).toBe(true);

      // Should include the same tools as getToolDefinitions()
      const expected = getToolDefinitions();
      expect(response.result.tools).toHaveLength(expected.length);
    });

    it("includes voice_speak and voice_ask", async () => {
      const response = await handleMcpRequest({
        jsonrpc: "2.0",
        id: 3,
        method: "tools/list",
      });

      const toolNames = response.result.tools.map(
        (t: { name: string }) => t.name,
      );
      expect(toolNames).toContain("voice_speak");
      expect(toolNames).toContain("voice_ask");
    });

    it("includes backward-compat aliases", async () => {
      const response = await handleMcpRequest({
        jsonrpc: "2.0",
        id: 4,
        method: "tools/list",
      });

      const toolNames = response.result.tools.map(
        (t: { name: string }) => t.name,
      );
      expect(toolNames).toContain("qa_voice_announce");
      expect(toolNames).toContain("qa_voice_ask");
    });

    it("each tool has name, description, inputSchema", async () => {
      const response = await handleMcpRequest({
        jsonrpc: "2.0",
        id: 5,
        method: "tools/list",
      });

      for (const tool of response.result.tools) {
        expect(tool.name).toBeDefined();
        expect(typeof tool.name).toBe("string");
        expect(tool.description).toBeDefined();
        expect(typeof tool.description).toBe("string");
        expect(tool.inputSchema).toBeDefined();
        expect(tool.inputSchema.type).toBe("object");
      }
    });
  });

  describe("tools/call", () => {
    it("dispatches voice_speak and returns result", async () => {
      const response = await handleMcpRequest(
        {
          jsonrpc: "2.0",
          id: 10,
          method: "tools/call",
          params: {
            name: "voice_speak",
            arguments: { message: "test message", mode: "think" },
          },
        },
        // Provide a mock tool executor
        {
          executeTool: async (name: string, args: Record<string, unknown>) => ({
            content: [{ type: "text" as const, text: `Executed ${name}` }],
          }),
        },
      );

      expect(response.jsonrpc).toBe("2.0");
      expect(response.id).toBe(10);
      expect(response.result).toBeDefined();
      expect(response.result.content).toBeDefined();
      expect(response.result.content[0].text).toBe("Executed voice_speak");
    });

    it("dispatches voice_ask and returns result", async () => {
      const response = await handleMcpRequest(
        {
          jsonrpc: "2.0",
          id: 11,
          method: "tools/call",
          params: {
            name: "voice_ask",
            arguments: { message: "What is your name?" },
          },
        },
        {
          executeTool: async (name: string, args: Record<string, unknown>) => ({
            content: [{ type: "text" as const, text: "My name is Claude" }],
          }),
        },
      );

      expect(response.id).toBe(11);
      expect(response.result.content[0].text).toBe("My name is Claude");
    });

    it("returns error for unknown tool", async () => {
      const response = await handleMcpRequest(
        {
          jsonrpc: "2.0",
          id: 12,
          method: "tools/call",
          params: {
            name: "nonexistent_tool",
            arguments: {},
          },
        },
        {
          executeTool: async () => ({
            content: [{ type: "text" as const, text: "Should not reach" }],
          }),
        },
      );

      expect(response.id).toBe(12);
      expect(response.result.content[0].text).toContain("Unknown tool");
      expect(response.result.isError).toBe(true);
    });

    it("catches tool execution errors", async () => {
      const response = await handleMcpRequest(
        {
          jsonrpc: "2.0",
          id: 13,
          method: "tools/call",
          params: {
            name: "voice_speak",
            arguments: { message: "fail" },
          },
        },
        {
          executeTool: async () => {
            throw new Error("TTS daemon crashed");
          },
        },
      );

      expect(response.id).toBe(13);
      expect(response.result.content[0].text).toContain("TTS daemon crashed");
      expect(response.result.isError).toBe(true);
    });

    it("passes arguments through to executor", async () => {
      let capturedArgs: Record<string, unknown> = {};
      await handleMcpRequest(
        {
          jsonrpc: "2.0",
          id: 14,
          method: "tools/call",
          params: {
            name: "voice_speak",
            arguments: { message: "hello", mode: "announce", rate: "+10%" },
          },
        },
        {
          executeTool: async (_name: string, args: Record<string, unknown>) => {
            capturedArgs = args;
            return { content: [{ type: "text" as const, text: "ok" }] };
          },
        },
      );

      expect(capturedArgs).toEqual({
        message: "hello",
        mode: "announce",
        rate: "+10%",
      });
    });
  });

  describe("unknown method", () => {
    it("returns method not found error", async () => {
      const response = await handleMcpRequest({
        jsonrpc: "2.0",
        id: 99,
        method: "unknown/method",
      });

      expect(response.jsonrpc).toBe("2.0");
      expect(response.id).toBe(99);
      expect(response.error).toBeDefined();
      expect(response.error.code).toBe(-32601); // Method not found
      expect(response.error.message).toContain("not found");
    });
  });

  describe("notifications (no id)", () => {
    it("initialized notification returns null (no response needed)", async () => {
      const response = await handleMcpRequest({
        jsonrpc: "2.0",
        method: "notifications/initialized",
      });

      expect(response).toBeNull();
    });
  });
});
