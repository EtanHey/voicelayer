import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdirSync, writeFileSync, rmSync } from "fs";
import { join } from "path";

// --- Profile YAML parsing tests ---

describe("parseProfileYaml", () => {
  it("parses a complete profile.yaml", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `name: theo
engine: qwen3-tts
model_path: ~/.voicelayer/models/qwen3-tts-4bit
reference_clips:
  - path: ~/.voicelayer/voices/theo/samples/clip-003.wav
    text: "and that's the thing about TypeScript"
  - path: ~/.voicelayer/voices/theo/samples/clip-011.wav
    text: "so we built the whole thing in a weekend"
  - path: ~/.voicelayer/voices/theo/samples/clip-007.wav
    text: "the reason I love this stack"
reference_clip: ~/.voicelayer/voices/theo/samples/clip-003.wav
reference_text: "and that's the thing about TypeScript"
fallback: en-US-AndrewNeural
created: 2026-02-23
source: https://youtube.com/@t3dotgg
`;
    const profile = parseProfileYaml(yaml);

    expect(profile.name).toBe("theo");
    expect(profile.engine).toBe("qwen3-tts");
    expect(profile.model_path).toBe("~/.voicelayer/models/qwen3-tts-4bit");
    expect(profile.reference_clips).toHaveLength(3);
    expect(profile.reference_clips[0].path).toBe(
      "~/.voicelayer/voices/theo/samples/clip-003.wav",
    );
    expect(profile.reference_clips[0].text).toBe(
      "and that's the thing about TypeScript",
    );
    expect(profile.reference_clips[1].path).toBe(
      "~/.voicelayer/voices/theo/samples/clip-011.wav",
    );
    expect(profile.reference_clips[2].path).toBe(
      "~/.voicelayer/voices/theo/samples/clip-007.wav",
    );
    expect(profile.reference_clip).toBe(
      "~/.voicelayer/voices/theo/samples/clip-003.wav",
    );
    expect(profile.reference_text).toBe(
      "and that's the thing about TypeScript",
    );
    expect(profile.fallback).toBe("en-US-AndrewNeural");
    expect(profile.created).toBe("2026-02-23");
    expect(profile.source).toBe("https://youtube.com/@t3dotgg");
  });

  it("handles minimal profile (no reference_clips array)", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `name: test
engine: qwen3-tts
reference_clip: ~/test.wav
reference_text: hello world
fallback: en-US-JennyNeural
`;
    const profile = parseProfileYaml(yaml);
    expect(profile.name).toBe("test");
    expect(profile.reference_clips).toHaveLength(0);
    expect(profile.reference_clip).toBe("~/test.wav");
    expect(profile.reference_text).toBe("hello world");
  });

  it("handles empty/missing fields with defaults", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `name: empty`;
    const profile = parseProfileYaml(yaml);

    expect(profile.name).toBe("empty");
    expect(profile.engine).toBe("qwen3-tts");
    expect(profile.fallback).toBe("en-US-JennyNeural");
    expect(profile.reference_clips).toHaveLength(0);
  });

  it("handles comments in YAML", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `# This is a comment
name: test # inline comment
engine: qwen3-tts
fallback: en-US-AndrewNeural # fallback voice
`;
    const profile = parseProfileYaml(yaml);
    expect(profile.name).toBe("test");
    expect(profile.fallback).toBe("en-US-AndrewNeural");
  });

  it("strips quotes from values", async () => {
    const { parseProfileYaml } = await import("../tts/qwen3");
    const yaml = `name: "quoted"
fallback: 'single-quoted'
`;
    const profile = parseProfileYaml(yaml);
    expect(profile.name).toBe("quoted");
    expect(profile.fallback).toBe("single-quoted");
  });
});

// --- Profile loading tests ---

describe("loadProfile + hasClonedProfile", () => {
  const testVoicesDir = join("/tmp", "voicelayer-test-voices");
  const testVoiceDir = join(testVoicesDir, "testvoice");

  beforeEach(() => {
    // Clean up and create test directories
    try {
      rmSync(testVoicesDir, { recursive: true });
    } catch {}
    mkdirSync(testVoiceDir, { recursive: true });
  });

  afterEach(async () => {
    const { clearProfileCache } = await import("../tts/qwen3");
    clearProfileCache();
    try {
      rmSync(testVoicesDir, { recursive: true });
    } catch {}
  });

  it("hasClonedProfile returns false for non-existent voice", async () => {
    const { hasClonedProfile } = await import("../tts/qwen3");
    expect(hasClonedProfile("nonexistent")).toBe(false);
  });

  it("loadProfile returns null for non-existent voice", async () => {
    const { loadProfile } = await import("../tts/qwen3");
    expect(loadProfile("nonexistent")).toBeNull();
  });
});

// --- Daemon communication tests (mocked) ---

describe("isDaemonHealthy", () => {
  it("returns false when daemon is not running", async () => {
    const { isDaemonHealthy } = await import("../tts/qwen3");
    // No daemon running on 8880 in test env
    const result = await isDaemonHealthy();
    expect(result).toBe(false);
  });
});

describe("synthesizeCloned", () => {
  it("returns null when no profile exists", async () => {
    const { synthesizeCloned } = await import("../tts/qwen3");
    const result = await synthesizeCloned("hello", "nonexistent");
    expect(result).toBeNull();
  });
});

// --- Three-tier routing in resolveVoice ---

describe("resolveVoice with cloned voices", () => {
  it("returns edge-tts engine for default (no voice name)", async () => {
    const { resolveVoice } = await import("../tts");
    const result = resolveVoice();
    expect(result.engine).toBe("edge-tts");
    expect(result.voice).toContain("Jenny");
  });

  it("returns edge-tts engine for raw edge-tts voice name", async () => {
    const { resolveVoice } = await import("../tts");
    const result = resolveVoice("en-US-BrianNeural");
    expect(result.engine).toBe("edge-tts");
    expect(result.voice).toBe("en-US-BrianNeural");
  });

  it("returns edge-tts engine for preset profile names", async () => {
    const { resolveVoice } = await import("../tts");
    const result = resolveVoice("andrew");
    expect(result.engine).toBe("edge-tts");
    expect(result.voice).toBe("en-US-AndrewNeural");
  });

  it("returns edge-tts with warning for unknown voice", async () => {
    const { resolveVoice } = await import("../tts");
    const result = resolveVoice("unknown_voice_xyz");
    expect(result.engine).toBe("edge-tts");
    expect(result.warning).toBeDefined();
    expect(result.warning).toContain("Unknown voice");
  });
});
