import { describe, it, expect } from "bun:test";
import {
  VoiceSpeakSchema,
  VoiceAskSchema,
  AnnounceArgsSchema,
  BriefArgsSchema,
  ConsultArgsSchema,
  ConverseArgsSchema,
  ThinkArgsSchema,
  ReplayArgsSchema,
  ToggleArgsSchema,
} from "../schemas/mcp-inputs";

describe("MCP input schemas", () => {
  describe("VoiceSpeakSchema", () => {
    it("accepts valid announce message", () => {
      const result = VoiceSpeakSchema.safeParse({ message: "hello" });
      expect(result.success).toBe(true);
    });

    it("rejects empty message", () => {
      const result = VoiceSpeakSchema.safeParse({ message: "" });
      expect(result.success).toBe(false);
    });

    it("rejects whitespace-only message", () => {
      const result = VoiceSpeakSchema.safeParse({ message: "   " });
      expect(result.success).toBe(false);
    });

    it("trims message whitespace", () => {
      const result = VoiceSpeakSchema.safeParse({ message: "  hello  " });
      expect(result.success).toBe(true);
      if (result.success) {
        expect(result.data.message).toBe("hello");
      }
    });

    it("accepts mode override", () => {
      const result = VoiceSpeakSchema.safeParse({
        message: "hello",
        mode: "brief",
      });
      expect(result.success).toBe(true);
      if (result.success) {
        expect(result.data.mode).toBe("brief");
      }
    });

    it("rejects invalid mode", () => {
      const result = VoiceSpeakSchema.safeParse({
        message: "hello",
        mode: "shout",
      });
      expect(result.success).toBe(false);
    });

    it("accepts toggle params (enabled=true)", () => {
      const result = VoiceSpeakSchema.safeParse({
        message: "ignored",
        enabled: true,
        scope: "tts",
      });
      expect(result.success).toBe(true);
    });

    it("accepts replay_index", () => {
      const result = VoiceSpeakSchema.safeParse({
        message: "ignored",
        replay_index: 5,
      });
      expect(result.success).toBe(true);
      if (result.success) {
        expect(result.data.replay_index).toBe(5);
      }
    });

    it("rejects replay_index > 19", () => {
      const result = VoiceSpeakSchema.safeParse({
        message: "ignored",
        replay_index: 20,
      });
      expect(result.success).toBe(false);
    });

    it("accepts rate pattern", () => {
      const result = VoiceSpeakSchema.safeParse({
        message: "hello",
        rate: "+10%",
      });
      expect(result.success).toBe(true);
    });

    it("rejects invalid rate pattern", () => {
      const result = VoiceSpeakSchema.safeParse({
        message: "hello",
        rate: "fast",
      });
      expect(result.success).toBe(false);
    });
  });

  describe("VoiceAskSchema", () => {
    it("accepts valid message", () => {
      const result = VoiceAskSchema.safeParse({
        message: "What do you think?",
      });
      expect(result.success).toBe(true);
    });

    it("rejects empty message", () => {
      const result = VoiceAskSchema.safeParse({ message: "" });
      expect(result.success).toBe(false);
    });

    it("clamps timeout_seconds to range", () => {
      const result = VoiceAskSchema.safeParse({
        message: "hello",
        timeout_seconds: 5000,
      });
      expect(result.success).toBe(false);
    });

    it("accepts valid silence_mode", () => {
      const result = VoiceAskSchema.safeParse({
        message: "hello",
        silence_mode: "quick",
      });
      expect(result.success).toBe(true);
    });

    it("rejects invalid silence_mode", () => {
      const result = VoiceAskSchema.safeParse({
        message: "hello",
        silence_mode: "instant",
      });
      expect(result.success).toBe(false);
    });

    it("accepts press_to_talk boolean", () => {
      const result = VoiceAskSchema.safeParse({
        message: "hello",
        press_to_talk: true,
      });
      expect(result.success).toBe(true);
    });

    it("defaults timeout_seconds to 300", () => {
      const result = VoiceAskSchema.safeParse({ message: "hello" });
      expect(result.success).toBe(true);
      if (result.success) {
        expect(result.data.timeout_seconds).toBe(300);
      }
    });
  });

  describe("ConverseArgsSchema", () => {
    it("accepts valid converse args", () => {
      const result = ConverseArgsSchema.safeParse({
        message: "How are you?",
        timeout_seconds: 60,
        silence_mode: "standard",
      });
      expect(result.success).toBe(true);
    });

    it("rejects missing message", () => {
      const result = ConverseArgsSchema.safeParse({});
      expect(result.success).toBe(false);
    });
  });

  describe("ThinkArgsSchema", () => {
    it("accepts valid thought", () => {
      const result = ThinkArgsSchema.safeParse({
        thought: "This is interesting",
      });
      expect(result.success).toBe(true);
    });

    it("defaults category to insight", () => {
      const result = ThinkArgsSchema.safeParse({
        thought: "This is interesting",
      });
      expect(result.success).toBe(true);
      if (result.success) {
        expect(result.data.category).toBe("insight");
      }
    });

    it("rejects invalid category", () => {
      const result = ThinkArgsSchema.safeParse({
        thought: "hello",
        category: "random",
      });
      expect(result.success).toBe(false);
    });

    it("rejects empty thought", () => {
      const result = ThinkArgsSchema.safeParse({ thought: "" });
      expect(result.success).toBe(false);
    });
  });

  describe("ReplayArgsSchema", () => {
    it("defaults index to 0", () => {
      const result = ReplayArgsSchema.safeParse({});
      expect(result.success).toBe(true);
      if (result.success) {
        expect(result.data.index).toBe(0);
      }
    });

    it("rejects index > 19", () => {
      const result = ReplayArgsSchema.safeParse({ index: 25 });
      expect(result.success).toBe(false);
    });

    it("accepts valid index", () => {
      const result = ReplayArgsSchema.safeParse({ index: 10 });
      expect(result.success).toBe(true);
    });
  });

  describe("ToggleArgsSchema", () => {
    it("accepts valid toggle", () => {
      const result = ToggleArgsSchema.safeParse({ enabled: true });
      expect(result.success).toBe(true);
    });

    it("defaults scope to all", () => {
      const result = ToggleArgsSchema.safeParse({ enabled: false });
      expect(result.success).toBe(true);
      if (result.success) {
        expect(result.data.scope).toBe("all");
      }
    });

    it("rejects missing enabled", () => {
      const result = ToggleArgsSchema.safeParse({});
      expect(result.success).toBe(false);
    });

    it("rejects invalid scope", () => {
      const result = ToggleArgsSchema.safeParse({
        enabled: true,
        scope: "video",
      });
      expect(result.success).toBe(false);
    });
  });

  describe("AnnounceArgsSchema", () => {
    it("accepts valid message", () => {
      const result = AnnounceArgsSchema.safeParse({ message: "hello" });
      expect(result.success).toBe(true);
    });

    it("rejects empty message", () => {
      const result = AnnounceArgsSchema.safeParse({ message: "" });
      expect(result.success).toBe(false);
    });
  });
});
