import { test, expect } from "bun:test";
import { mkdirSync, writeFileSync, unlinkSync } from "fs";
import { testTmp } from "./setup/test-tmp";
import { registerParakeetDaemonOwner } from "../parakeet-server";
import { isCurrentProcessLockOwner } from "../process-lock";

test("resident registration requires both the admitted parent and private daemon PID ownership", () => {
  const root = testTmp("parakeet-owner"); mkdirSync(root, { recursive: true });
  const path = root + "/mcp.pid";
  const saved = { parent: process.env.VOICEBAR_PARENT_PID, path: process.env.QA_VOICE_MCP_PID_PATH };
  try {
    process.env.QA_VOICE_MCP_PID_PATH = path;
    process.env.VOICEBAR_PARENT_PID = String(process.ppid);
    expect(isCurrentProcessLockOwner()).toBe(false);
    expect(registerParakeetDaemonOwner()).toBe(false);
    // Fixture records exercise the read boundary without signalling a process.
    writeFileSync(path, JSON.stringify({ pid: process.pid + 1, startedAt: "fixture" }));
    expect(registerParakeetDaemonOwner()).toBe(false);
    writeFileSync(path, JSON.stringify({ pid: process.pid, startedAt: "fixture" }));
    for (const parent of ["", "1", String(process.ppid + 1)]) {
      process.env.VOICEBAR_PARENT_PID = parent;
      expect(registerParakeetDaemonOwner()).toBe(false);
    }
    process.env.VOICEBAR_PARENT_PID = String(process.ppid);
    expect(registerParakeetDaemonOwner()).toBe(true);
    unlinkSync(path);
    expect(isCurrentProcessLockOwner()).toBe(false);
  } finally {
    if (saved.parent === undefined) delete process.env.VOICEBAR_PARENT_PID; else process.env.VOICEBAR_PARENT_PID = saved.parent;
    if (saved.path === undefined) delete process.env.QA_VOICE_MCP_PID_PATH; else process.env.QA_VOICE_MCP_PID_PATH = saved.path;
  }
});
