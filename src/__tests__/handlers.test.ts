/**
 * Handler-level tests — Phase 1 MCP Sweep.
 *
 * Tests MCP tool handlers (handleToggle, handleReplay, handleThink, etc.)
 * directly, without going through the MCP server transport.
 */

import { describe, it, expect, spyOn, beforeEach, afterEach } from "bun:test";
import { existsSync, unlinkSync, readFileSync } from "fs";
import * as socketServer from "../socket-server";
import {
  TTS_DISABLED_FILE,
  MIC_DISABLED_FILE,
  VOICE_DISABLED_FILE,
} from "../paths";
import { handleToggle, handleReplay, handleThink } from "../handlers";

// Helper to clean flag files
function cleanFlags() {
  for (const f of [TTS_DISABLED_FILE, MIC_DISABLED_FILE, VOICE_DISABLED_FILE]) {
    try {
      if (existsSync(f)) unlinkSync(f);
    } catch {}
  }
}

describe("handleToggle", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    cleanFlags();
    broadcastSpy = spyOn(socketServer, "broadcast").mockImplementation(
      () => {},
    );
  });

  afterEach(() => {
    cleanFlags();
    broadcastSpy.mockRestore();
  });

  it("returns error for missing enabled parameter", async () => {
    const result = await handleToggle({});
    expect(result.isError).toBe(true);
  });

  it("returns error for invalid args (no enabled)", async () => {
    const result = await handleToggle({ scope: "tts" });
    expect(result.isError).toBe(true);
  });

  it("disables TTS when scope is tts", async () => {
    const result = await handleToggle({ enabled: false, scope: "tts" });
    expect(result.isError).toBeUndefined();
    expect(existsSync(TTS_DISABLED_FILE)).toBe(true);
    expect(existsSync(MIC_DISABLED_FILE)).toBe(false);
  });

  it("disables mic when scope is mic", async () => {
    const result = await handleToggle({ enabled: false, scope: "mic" });
    expect(result.isError).toBeUndefined();
    expect(existsSync(MIC_DISABLED_FILE)).toBe(true);
    expect(existsSync(TTS_DISABLED_FILE)).toBe(false);
  });

  it("disables all (tts + mic + combined) when scope is all", async () => {
    const result = await handleToggle({ enabled: false, scope: "all" });
    expect(result.isError).toBeUndefined();
    expect(existsSync(TTS_DISABLED_FILE)).toBe(true);
    expect(existsSync(MIC_DISABLED_FILE)).toBe(true);
    expect(existsSync(VOICE_DISABLED_FILE)).toBe(true);
  });

  it("defaults scope to all when not provided", async () => {
    const result = await handleToggle({ enabled: false });
    expect(result.isError).toBeUndefined();
    expect(existsSync(TTS_DISABLED_FILE)).toBe(true);
    expect(existsSync(MIC_DISABLED_FILE)).toBe(true);
    expect(existsSync(VOICE_DISABLED_FILE)).toBe(true);
  });

  it("enables all removes all flag files", async () => {
    // First disable
    await handleToggle({ enabled: false, scope: "all" });
    // Then enable
    const result = await handleToggle({ enabled: true, scope: "all" });
    expect(result.isError).toBeUndefined();
    expect(existsSync(TTS_DISABLED_FILE)).toBe(false);
    expect(existsSync(MIC_DISABLED_FILE)).toBe(false);
    expect(existsSync(VOICE_DISABLED_FILE)).toBe(false);
  });

  it("returns descriptive action text", async () => {
    const result = await handleToggle({ enabled: false, scope: "tts" });
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("TTS disabled");
  });
});

describe("handleReplay", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    broadcastSpy = spyOn(socketServer, "broadcast").mockImplementation(
      () => {},
    );
  });

  afterEach(() => {
    broadcastSpy.mockRestore();
  });

  it("returns error when no audio in history", async () => {
    const result = await handleReplay({});
    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("No audio in history");
  });

  it("returns error for out-of-range index (clamps to 0)", async () => {
    // Index > 19 fails Zod validation, defaults to 0
    const result = await handleReplay({ index: 999 });
    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("No audio in history");
  });
});

describe("handleThink", () => {
  const THINK_FILE =
    process.env.QA_VOICE_THINK_FILE || "/tmp/voicelayer-thinking.md";

  afterEach(() => {
    try {
      if (existsSync(THINK_FILE)) unlinkSync(THINK_FILE);
    } catch {}
  });

  it("returns error for missing thought", async () => {
    const result = await handleThink({});
    expect(result.isError).toBe(true);
  });

  it("returns error for empty thought", async () => {
    const result = await handleThink({ thought: "" });
    expect(result.isError).toBe(true);
  });

  it("writes thought to thinking log", async () => {
    const result = await handleThink({ thought: "Test insight" });
    expect(result.isError).toBeUndefined();
    expect(existsSync(THINK_FILE)).toBe(true);
    const content = readFileSync(THINK_FILE, "utf-8");
    expect(content).toContain("Test insight");
  });

  it("includes category in output", async () => {
    const result = await handleThink({
      thought: "Test insight",
      category: "insight",
    });
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("insight");
  });
});
