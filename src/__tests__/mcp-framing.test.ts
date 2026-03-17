/**
 * Tests for MCP Content-Length framing parser/serializer.
 *
 * MCP uses LSP-style framing: `Content-Length: N\r\n\r\n{json}`
 * This module parses incoming frames and serializes outgoing ones.
 *
 * TDD RED: these tests define behavior for src/mcp-framing.ts (doesn't exist yet).
 */
import { describe, it, expect } from "bun:test";
import {
  parseMcpFrames,
  serializeMcpFrame,
  detectProtocol,
} from "../mcp-framing";

describe("mcp-framing", () => {
  describe("serializeMcpFrame", () => {
    it("wraps JSON object with Content-Length header", () => {
      const body = { jsonrpc: "2.0", id: 1, result: {} };
      const frame = serializeMcpFrame(body);
      const json = JSON.stringify(body);
      expect(frame).toBe(`Content-Length: ${json.length}\r\n\r\n${json}`);
    });

    it("calculates byte length not char length for unicode", () => {
      const body = { text: "héllo wörld" };
      const frame = serializeMcpFrame(body);
      const json = JSON.stringify(body);
      const byteLen = Buffer.byteLength(json, "utf-8");
      expect(frame).toStartWith(`Content-Length: ${byteLen}\r\n\r\n`);
    });

    it("produces valid frame that can be round-tripped", () => {
      const body = {
        jsonrpc: "2.0",
        id: 42,
        result: { protocolVersion: "2024-11-05" },
      };
      const frame = serializeMcpFrame(body);
      const { messages, remainder } = parseMcpFrames(frame);
      expect(messages).toHaveLength(1);
      expect(messages[0]).toEqual(body);
      expect(remainder).toBe("");
    });
  });

  describe("parseMcpFrames", () => {
    it("parses a single complete frame", () => {
      const json = '{"jsonrpc":"2.0","id":1,"method":"initialize"}';
      const frame = `Content-Length: ${json.length}\r\n\r\n${json}`;
      const { messages, remainder } = parseMcpFrames(frame);
      expect(messages).toHaveLength(1);
      expect(messages[0]).toEqual({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
      });
      expect(remainder).toBe("");
    });

    it("parses multiple frames in one chunk", () => {
      const json1 = '{"jsonrpc":"2.0","id":1,"method":"initialize"}';
      const json2 = '{"jsonrpc":"2.0","id":2,"method":"tools/list"}';
      const data =
        `Content-Length: ${json1.length}\r\n\r\n${json1}` +
        `Content-Length: ${json2.length}\r\n\r\n${json2}`;
      const { messages, remainder } = parseMcpFrames(data);
      expect(messages).toHaveLength(2);
      expect(messages[0].method).toBe("initialize");
      expect(messages[1].method).toBe("tools/list");
      expect(remainder).toBe("");
    });

    it("returns remainder for incomplete header", () => {
      const { messages, remainder } = parseMcpFrames("Content-Len");
      expect(messages).toHaveLength(0);
      expect(remainder).toBe("Content-Len");
    });

    it("returns remainder for incomplete body", () => {
      const json = '{"jsonrpc":"2.0","id":1,"method":"initialize"}';
      const frame = `Content-Length: ${json.length}\r\n\r\n${json.slice(0, 10)}`;
      const { messages, remainder } = parseMcpFrames(frame);
      expect(messages).toHaveLength(0);
      expect(remainder).toBe(frame);
    });

    it("handles frame split across two chunks", () => {
      const json = '{"jsonrpc":"2.0","id":1,"method":"initialize"}';
      const frame = `Content-Length: ${json.length}\r\n\r\n${json}`;
      const mid = Math.floor(frame.length / 2);

      // First chunk — incomplete
      const { messages: m1, remainder: r1 } = parseMcpFrames(
        frame.slice(0, mid),
      );
      expect(m1).toHaveLength(0);

      // Second chunk — completes the frame
      const { messages: m2, remainder: r2 } = parseMcpFrames(
        r1 + frame.slice(mid),
      );
      expect(m2).toHaveLength(1);
      expect(m2[0].method).toBe("initialize");
      expect(r2).toBe("");
    });

    it("handles unicode body correctly by byte length", () => {
      const json = '{"text":"héllo"}';
      const byteLen = Buffer.byteLength(json, "utf-8");
      const frame = `Content-Length: ${byteLen}\r\n\r\n${json}`;
      const { messages, remainder } = parseMcpFrames(frame);
      expect(messages).toHaveLength(1);
      expect(messages[0].text).toBe("héllo");
      expect(remainder).toBe("");
    });

    it("returns empty for empty input", () => {
      const { messages, remainder } = parseMcpFrames("");
      expect(messages).toHaveLength(0);
      expect(remainder).toBe("");
    });

    it("parses one complete + one incomplete frame", () => {
      const json1 = '{"id":1}';
      const json2 = '{"id":2}';
      const data =
        `Content-Length: ${json1.length}\r\n\r\n${json1}` +
        `Content-Length: ${json2.length}\r\n\r\n${json2.slice(0, 3)}`;
      const { messages, remainder } = parseMcpFrames(data);
      expect(messages).toHaveLength(1);
      expect(messages[0].id).toBe(1);
      expect(remainder.length).toBeGreaterThan(0);
    });
  });

  describe("detectProtocol", () => {
    it("detects MCP Content-Length framing", () => {
      const data = "Content-Length: 42\r\n\r\n";
      expect(detectProtocol(data)).toBe("mcp");
    });

    it("detects NDJSON from leading brace", () => {
      expect(detectProtocol('{"type":"state"}\n')).toBe("ndjson");
    });

    it("detects NDJSON from leading bracket", () => {
      expect(detectProtocol("[1,2,3]\n")).toBe("ndjson");
    });

    it("returns unknown for insufficient data", () => {
      expect(detectProtocol("")).toBe("unknown");
      expect(detectProtocol("C")).toBe("unknown");
    });

    it("returns unknown for unrecognized data", () => {
      expect(detectProtocol("HTTP/1.1 200")).toBe("unknown");
      expect(detectProtocol("hello")).toBe("unknown");
    });

    it("handles whitespace before JSON", () => {
      expect(detectProtocol(' {"cmd":"stop"}\n')).toBe("ndjson");
    });
  });
});
