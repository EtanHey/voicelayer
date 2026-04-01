/**
 * Security hardening tests — B3/B4/B5 from overnight sprint.
 *
 * B3: ToolAnnotations on all MCP tools
 * B4: Stop signal moved from /tmp to ~/.local/state/voicelayer/
 * B5: SSML injection sanitization in TTS text
 */

import { describe, it, expect } from "bun:test";
import { getToolDefinitions } from "../mcp-tools";
import { sanitizeTtsText } from "../sanitize";
import { STOP_FILE, CANCEL_FILE, STATE_DIR } from "../paths";
import { homedir } from "os";
import { join } from "path";

// --- B3: ToolAnnotations ---

describe("B3: ToolAnnotations on all MCP tools", () => {
  const tools = getToolDefinitions();

  it("all tools have annotations", () => {
    for (const tool of tools) {
      expect(tool).toHaveProperty("annotations");
      expect(tool.annotations).toBeDefined();
    }
  });

  it("all tools have readOnlyHint", () => {
    for (const tool of tools) {
      expect(typeof tool.annotations?.readOnlyHint).toBe("boolean");
    }
  });

  it("all tools have destructiveHint", () => {
    for (const tool of tools) {
      expect(typeof tool.annotations?.destructiveHint).toBe("boolean");
    }
  });

  it("all tools have idempotentHint", () => {
    for (const tool of tools) {
      expect(typeof tool.annotations?.idempotentHint).toBe("boolean");
    }
  });

  it("no tool is marked destructive (VoiceLayer has no destructive ops)", () => {
    for (const tool of tools) {
      expect(tool.annotations?.destructiveHint).toBe(false);
    }
  });

  it("voice_speak is not readOnly (produces audio output)", () => {
    const speak = tools.find((t) => t.name === "voice_speak");
    expect(speak?.annotations?.readOnlyHint).toBe(false);
  });

  it("voice_ask is not readOnly (records mic + produces audio)", () => {
    const ask = tools.find((t) => t.name === "voice_ask");
    expect(ask?.annotations?.readOnlyHint).toBe(false);
  });

  it("voice_ask is not idempotent (each recording is unique)", () => {
    const ask = tools.find((t) => t.name === "voice_ask");
    expect(ask?.annotations?.idempotentHint).toBe(false);
  });

  it("toggle tools are idempotent", () => {
    const toggle = tools.find((t) => t.name === "qa_voice_toggle");
    expect(toggle?.annotations?.idempotentHint).toBe(true);
  });

  it("replay tools are idempotent", () => {
    const replay = tools.find((t) => t.name === "qa_voice_replay");
    expect(replay?.annotations?.idempotentHint).toBe(true);
  });
});

// --- B4: Stop signal path ---

describe("B4: Stop signal path uses ~/.local/state/voicelayer/", () => {
  it("STATE_DIR is under home directory", () => {
    const home = homedir();
    expect(STATE_DIR.startsWith(home)).toBe(true);
  });

  it("STATE_DIR is ~/.local/state/voicelayer", () => {
    const expected = join(homedir(), ".local", "state", "voicelayer");
    expect(STATE_DIR).toBe(expected);
  });

  it("STOP_FILE is under STATE_DIR, not /tmp", () => {
    expect(STOP_FILE.startsWith("/tmp")).toBe(false);
    expect(STOP_FILE.startsWith(STATE_DIR)).toBe(true);
  });

  it("CANCEL_FILE is under STATE_DIR, not /tmp", () => {
    expect(CANCEL_FILE.startsWith("/tmp")).toBe(false);
    expect(CANCEL_FILE.startsWith(STATE_DIR)).toBe(true);
  });

  it("STOP_FILE contains session token", () => {
    expect(STOP_FILE).toContain("stop-");
    // Should have random hex suffix
    const basename = STOP_FILE.split("/").pop()!;
    expect(/^stop-[0-9a-f]{16,}$/.test(basename)).toBe(true);
  });
});

// --- B5: SSML injection sanitization ---

describe("B5: SSML injection sanitization", () => {
  it("strips angle brackets from text", () => {
    expect(sanitizeTtsText("<speak>hello</speak>")).toBe("hello");
  });

  it("strips nested SSML tags", () => {
    expect(sanitizeTtsText('<voice name="en-US">hello</voice>')).toBe("hello");
  });

  it("strips self-closing tags", () => {
    expect(sanitizeTtsText('hello <break time="500ms"/> world')).toBe(
      "hello world",
    );
  });

  it("preserves normal text", () => {
    expect(sanitizeTtsText("Hello, how are you today?")).toBe(
      "Hello, how are you today?",
    );
  });

  it("preserves mathematical comparisons as text", () => {
    // After stripping tags, this becomes "x  5 and y  3"
    // which is acceptable — we're protecting against injection, not preserving math
    const result = sanitizeTtsText("x < 5 and y > 3");
    expect(result).not.toContain("<");
    expect(result).not.toContain(">");
  });

  it("handles empty string", () => {
    expect(sanitizeTtsText("")).toBe("");
  });

  it("strips control characters", () => {
    expect(sanitizeTtsText("hello\x00world\x01test")).toBe("hello world test");
  });

  it("strips multiple SSML injection attempts", () => {
    const malicious =
      '<speak><prosody rate="x-slow"><emphasis level="strong">HACKED</emphasis></prosody></speak>';
    const result = sanitizeTtsText(malicious);
    expect(result).not.toContain("<");
    expect(result).not.toContain(">");
    expect(result).toContain("HACKED");
  });
});
