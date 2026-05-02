import { describe, expect, it } from "bun:test";
import { parseLsofSocketOwnerPids } from "../mcp-socket-owner";

describe("MCP socket owner detection", () => {
  it("extracts only exact listener owners for the MCP socket", () => {
    const output = [
      "COMMAND   PID USER   FD  TYPE             DEVICE SIZE/OFF NODE NAME",
      "bun      2699 etan   11u unix 0xff2dc30798108f74      0t0      /tmp/voicelayer-mcp.sock",
      "socat   30579 etan    3u unix 0xabc      0t0      ->0xff2dc30798108f74",
      "bun      9999 etan   12u unix 0xdef      0t0      /tmp/other.sock",
      "bun      7777 etan   12u unix 0xdef      0t0      /tmp/voicelayer-mcp.sock.backup",
    ].join("\n");

    expect(parseLsofSocketOwnerPids(output, "/tmp/voicelayer-mcp.sock", 1234)).toEqual([2699]);
  });

  it("deduplicates owners and excludes the current process", () => {
    const output = [
      "bun      2699 etan   11u unix 0xff2dc30798108f74      0t0      /tmp/voicelayer-mcp.sock",
      "bun      2699 etan   12u unix 0xff2dc30798108f75      0t0      /tmp/voicelayer-mcp.sock",
      "bun      1234 etan   13u unix 0xff2dc30798108f76      0t0      /tmp/voicelayer-mcp.sock",
    ].join("\n");

    expect(parseLsofSocketOwnerPids(output, "/tmp/voicelayer-mcp.sock", 1234)).toEqual([2699]);
  });

  it("handles lsof NAME metadata after the socket path", () => {
    const output = [
      "COMMAND   PID USER   FD  TYPE             DEVICE SIZE/OFF NODE NAME",
      "bun      2699 etan   11u unix 0xff2dc30798108f74      0t0      /tmp/voicelayer-mcp.sock (LISTEN)",
      "bun      7777 etan   12u unix 0xdef      0t0      /tmp/voicelayer-mcp.sock.backup (LISTEN)",
    ].join("\n");

    expect(parseLsofSocketOwnerPids(output, "/tmp/voicelayer-mcp.sock", 1234)).toEqual([2699]);
  });
});
