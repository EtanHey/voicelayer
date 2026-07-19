/**
 * Tests for MCP tool response formatting.
 *
 * Verifies that tool responses use Unicode box-drawing for clean,
 * readable output in Claude Code's tool result display.
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

describe("formatSpeak", () => {
  it("formats announce mode with box border", () => {
    const out = formatSpeak("announce", "Hello world");
    expect(out).toContain("┌");
    expect(out).toContain("└");
    expect(out).toContain("announce");
    expect(out).toContain("Hello world");
  });

  it("formats brief mode", () => {
    const out = formatSpeak("brief", "Long explanation here");
    expect(out).toContain("brief");
    expect(out).toContain("Long explanation here");
  });

  it("formats consult mode with hint", () => {
    const out = formatSpeak("consult", "Should I proceed?");
    expect(out).toContain("consult");
    expect(out).toContain("Should I proceed?");
    expect(out).toContain("voice_ask");
  });

  it("includes warning when present", () => {
    const out = formatSpeak("announce", "Hello", "TTS fallback used");
    expect(out).toContain("TTS fallback used");
    expect(out).toContain("⚠");
  });

  it("omits warning line when absent", () => {
    const out = formatSpeak("announce", "Hello");
    expect(out).not.toContain("⚠");
  });

  it("includes the playback id used to correlate follow-up telemetry", () => {
    const out = formatSpeak(
      "announce",
      "Hello",
      undefined,
      "playback-123",
    );
    expect(out).toContain("playback-123");
  });
});

describe("formatAsk — success", () => {
  it("formats transcribed response", () => {
    const out = formatAsk("I think we should refactor");
    expect(out).toContain("┌");
    expect(out).toContain("I think we should refactor");
  });

  it("includes interrupted prompt position in the blocking result", () => {
    const out = formatAsk("I heard enough", {
      promptPlayback: {
        type: "playback_outcome",
        playback_id: "playback-ask",
        status: "interrupted",
        reason: "stopped",
        stopped_at_ms: 550,
        duration_ms: 1_000,
        progress: 0.55,
        word_index: 1,
        word_count: 3,
      },
    } as any);

    expect(out).toContain("Prompt interrupted");
    expect(out).toContain("word 2/3");
    expect(out).toContain("55%");
  });
});

describe("formatAsk — timeout", () => {
  it("formats timeout with seconds", () => {
    const out = formatAsk(null, { timeoutSeconds: 30, pressToTalk: false });
    expect(out).toContain("30s");
    expect(out).toContain("timeout");
  });

  it("formats PTT timeout differently", () => {
    const out = formatAsk(null, { timeoutSeconds: 60, pressToTalk: true });
    expect(out).toContain("PTT");
    expect(out).toContain("60s");
  });

  it("reports no speech promptly without claiming the configured timeout elapsed", () => {
    const out = formatAsk(null, {
      timeoutSeconds: 180,
      pressToTalk: false,
      outcome: "no-speech",
    } as any);

    expect(out).toContain("No speech detected");
    expect(out).not.toContain("180s");
    expect(out).not.toContain("timeout");
  });
});

describe("formatThink", () => {
  it("formats thought with category icon", () => {
    const out = formatThink("insight", "This needs refactoring");
    expect(out).toContain("insight");
    expect(out).toContain("This needs refactoring");
  });

  it("uses red-flag icon", () => {
    const out = formatThink("red-flag", "Security issue found");
    expect(out).toContain("red-flag");
    expect(out).toContain("Security issue found");
  });
});

describe("formatReplay", () => {
  it("formats replay with index", () => {
    const out = formatReplay(0, "Previous message text");
    expect(out).toContain("0");
    expect(out).toContain("Previous message text");
  });

  it("formats replay with non-zero index", () => {
    const out = formatReplay(3, "Older message");
    expect(out).toContain("3");
    expect(out).toContain("Older message");
  });
});

describe("formatToggle", () => {
  it("formats single action", () => {
    const out = formatToggle(["TTS enabled"]);
    expect(out).toContain("TTS enabled");
  });

  it("formats multiple actions", () => {
    const out = formatToggle(["TTS disabled", "mic disabled"]);
    expect(out).toContain("TTS disabled");
    expect(out).toContain("mic disabled");
  });
});

describe("formatError", () => {
  it("formats error with tool context", () => {
    const out = formatError("voice_speak", "Missing message parameter");
    expect(out).toContain("voice_speak");
    expect(out).toContain("Missing message parameter");
    expect(out).toContain("✗");
  });
});

describe("formatBusy", () => {
  it("formats busy state with session info", () => {
    const out = formatBusy("abc-123", 4567, "2026-03-29T10:00:00Z");
    expect(out).toContain("abc-123");
    expect(out).toContain("4567");
    expect(out).toContain("busy");
  });
});
