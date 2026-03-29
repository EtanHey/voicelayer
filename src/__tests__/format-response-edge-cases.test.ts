/**
 * Edge case tests for format-response.ts
 *
 * Tests boundary conditions, special characters, and malformed input.
 */

import { describe, it, expect } from "bun:test";
import {
  formatSpeak,
  formatAsk,
  formatThink,
  formatReplay,
  formatToggle,
  formatError,
  formatBusy,
} from "../format-response";

describe("formatSpeak edge cases", () => {
  it("handles empty message", () => {
    const out = formatSpeak("announce", "");
    expect(out).toContain("┌");
    expect(out).toContain("└");
    expect(out).toContain('""');
  });

  it("handles message with newlines", () => {
    const out = formatSpeak("announce", "Line 1\nLine 2");
    expect(out).toContain("┌");
    expect(out).toContain("└");
    // Each line should be properly boxed
    const lines = out.split("\n");
    expect(lines.length).toBeGreaterThan(3); // header + at least 2 content lines + footer
    // All content lines should start with "│ "
    const contentLines = lines.slice(1, -1);
    contentLines.forEach((line) => {
      expect(line).toMatch(/^│ /);
    });
  });

  it("handles unknown mode with fallback icon", () => {
    const out = formatSpeak("unknown-mode" as any, "Test");
    expect(out).toContain("unknown-mode");
    expect(out).toContain("🔊"); // fallback icon
  });

  it("handles message with box-drawing characters", () => {
    const out = formatSpeak("announce", "Code: ┌─ block ─┐");
    expect(out).toContain("Code: ┌─ block ─┐");
  });

  it("handles very long messages", () => {
    const longMsg = "A".repeat(1000);
    const out = formatSpeak("announce", longMsg);
    expect(out).toContain("┌");
    expect(out).toContain("└");
    expect(out).toContain(longMsg);
  });

  it("handles Unicode and emoji in message", () => {
    const out = formatSpeak("announce", "Hello 世界 🌍");
    expect(out).toContain("Hello 世界 🌍");
  });
});

describe("formatAsk edge cases", () => {
  it("treats empty string transcript as valid (not timeout)", () => {
    const out = formatAsk("");
    // Empty string should be treated as valid transcript, not timeout
    expect(out).toContain('🎤 ""');
    expect(out).not.toContain("timeout");
  });

  it("handles null transcript with default timeout", () => {
    const out = formatAsk(null);
    expect(out).toContain("30s"); // default
  });

  it("handles transcript with quotes", () => {
    const out = formatAsk('He said "hello"');
    expect(out).toContain("He said");
    expect(out).toContain("hello");
  });

  it("handles transcript with newlines", () => {
    const out = formatAsk("Line 1\nLine 2");
    expect(out).toContain("Line 1");
    expect(out).toContain("Line 2");
  });
});

describe("formatThink edge cases", () => {
  it("uses fallback icon for unknown category", () => {
    const out = formatThink("unknown" as any, "Test");
    expect(out).toContain("📝"); // fallback
    expect(out).toContain("unknown");
  });

  it("handles empty thought", () => {
    const out = formatThink("insight", "");
    expect(out).toContain("insight:");
  });

  it("handles thought with newlines", () => {
    const out = formatThink("insight", "Line 1\nLine 2");
    expect(out).toContain("Line 1");
  });
});

describe("formatReplay edge cases", () => {
  it("handles negative index", () => {
    const out = formatReplay(-1, "Test");
    expect(out).toContain("#-1");
  });

  it("handles very large index", () => {
    const out = formatReplay(999999, "Test");
    expect(out).toContain("#999999");
  });

  it("handles text with newlines", () => {
    const out = formatReplay(0, "Line 1\nLine 2");
    expect(out).toContain("Line 1");
  });
});

describe("formatToggle edge cases", () => {
  it("handles empty actions array", () => {
    const out = formatToggle([]);
    expect(out).toContain("┌");
    expect(out).toContain("└");
    expect(out).toContain("(no changes)");
    // Should have header, body with placeholder, and footer
    const lines = out.split("\n");
    expect(lines.length).toBeGreaterThanOrEqual(3);
  });

  it("handles single action", () => {
    const out = formatToggle(["TTS enabled"]);
    expect(out).toContain("TTS enabled");
  });

  it("handles actions with special characters", () => {
    const out = formatToggle(["Action with → arrow"]);
    expect(out).toContain("Action with → arrow");
  });
});

describe("formatError edge cases", () => {
  it("handles empty error message", () => {
    const out = formatError("voice_speak", "");
    expect(out).toContain("voice_speak ✗");
  });

  it("handles very long error message", () => {
    const longErr = "Error: ".repeat(100);
    const out = formatError("voice_speak", longErr);
    expect(out).toContain("Error:");
  });

  it("handles error with newlines", () => {
    const out = formatError("voice_speak", "Error line 1\nError line 2");
    expect(out).toContain("Error line 1");
  });
});

describe("formatBusy edge cases", () => {
  it("handles special characters in session ID", () => {
    const out = formatBusy("abc-<script>", 123, "2026-01-01");
    expect(out).toContain("abc-<script>");
  });

  it("handles very long session ID", () => {
    const longId = "x".repeat(200);
    const out = formatBusy(longId, 123, "2026-01-01");
    expect(out).toContain(longId);
  });

  it("handles zero PID", () => {
    const out = formatBusy("test", 0, "2026-01-01");
    expect(out).toContain("PID 0");
  });
});

describe("Box structure validation", () => {
  it("preserves box structure with multi-line speak message", () => {
    const out = formatSpeak("announce", "Line 1\nLine 2\nLine 3");
    const lines = out.split("\n");
    expect(lines[0]).toMatch(/^┌─/); // header
    expect(lines[lines.length - 1]).toMatch(/^└─/); // footer
    // All content lines should start with "│ "
    const contentLines = lines.slice(1, -1);
    contentLines.forEach((line) => {
      expect(line).toMatch(/^│ /);
    });
  });

  it("preserves box structure with multi-line ask transcript", () => {
    const out = formatAsk("Line 1\nLine 2");
    const lines = out.split("\n");
    expect(lines[0]).toMatch(/^┌─/);
    expect(lines[lines.length - 1]).toMatch(/^└─/);
    const contentLines = lines.slice(1, -1);
    contentLines.forEach((line) => {
      expect(line).toMatch(/^│ /);
    });
  });

  it("preserves box structure with multi-line error", () => {
    const out = formatError("voice_speak", "Error 1\nError 2");
    const lines = out.split("\n");
    expect(lines[0]).toMatch(/^┌─/);
    expect(lines[lines.length - 1]).toMatch(/^└─/);
    const contentLines = lines.slice(1, -1);
    contentLines.forEach((line) => {
      expect(line).toMatch(/^│ /);
    });
  });

  it("all formatters produce valid box structure", () => {
    const outputs = [
      formatSpeak("announce", "test"),
      formatAsk("test"),
      formatThink("insight", "test"),
      formatReplay(0, "test"),
      formatToggle(["action"]),
      formatError("tool", "error"),
      formatBusy("session", 123, "2026-01-01"),
    ];

    outputs.forEach((out) => {
      const lines = out.split("\n");
      expect(lines[0]).toMatch(/^┌─/); // starts with header
      expect(lines[lines.length - 1]).toMatch(/^└─/); // ends with footer
      expect(lines.length).toBeGreaterThanOrEqual(3); // has at least header, body, footer
    });
  });
});
