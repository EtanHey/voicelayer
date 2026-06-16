import { describe, expect, it } from "bun:test";
import {
  DEFAULT_DECODE_BENCHMARK_PLANS,
  buildWhisperCliArgs,
  buildWhisperServerArgs,
  compareTranscriptToReference,
  detectRepeatedTail,
  formatBenchmarkMarkdown,
  normalizedTranscriptSimilarity,
  scoreTranscript,
} from "../stt-decode-benchmark";

describe("stt-decode-benchmark", () => {
  it("includes effort presets, legacy server variants, and CLI", () => {
    expect(DEFAULT_DECODE_BENCHMARK_PLANS.map((plan) => plan.id)).toEqual([
      "effort-fast",
      "effort-balanced",
      "effort-accurate",
      "server-bo5-bs5",
      "server-bo5-bs3",
      "server-defaults",
      "cli",
    ]);
  });

  it("builds resident server args with the selected decode flags", () => {
    const args = buildWhisperServerArgs({
      binary: "/opt/homebrew/bin/whisper-server",
      model: "/models/ggml-large-v3-turbo.bin",
      port: 18892,
      decodeArgs: ["-bo", "5", "-bs", "3"],
    });

    expect(args).toEqual([
      "/opt/homebrew/bin/whisper-server",
      "-m",
      "/models/ggml-large-v3-turbo.bin",
      "--port",
      "18892",
      "--host",
      "127.0.0.1",
      "-t",
      "4",
      "-nt",
      "-bo",
      "5",
      "-bs",
      "3",
    ]);
  });

  it("builds CLI args with no timestamps and no progress output", () => {
    const args = buildWhisperCliArgs({
      binary: "/opt/homebrew/bin/whisper-cli",
      model: "/models/ggml-large-v3-turbo.bin",
      audio: "/tmp/sample.wav",
      language: "auto",
    });

    expect(args).toEqual([
      "/opt/homebrew/bin/whisper-cli",
      "-m",
      "/models/ggml-large-v3-turbo.bin",
      "-f",
      "/tmp/sample.wav",
      "-l",
      "auto",
      "-nt",
      "-np",
    ]);
  });

  it("detects repeated transcript endings", () => {
    const repeated = detectRepeatedTail(
      "This is useful now. I don't know. I don't know.",
    );

    expect(repeated.repeated).toBe(true);
    expect(repeated.phrase).toBe("i don't know");
    expect(repeated.count).toBe(2);
  });

  it("scores expected phrase hits and repeated tails", () => {
    const score = scoreTranscript(
      "The socket path is /tmp/VoiceLayer.socket. I don't know. I don't know.",
      ["/tmp/VoiceLayer.socket", "missing tail"],
    );

    expect(score.charCount).toBeGreaterThan(40);
    expect(score.wordCount).toBeGreaterThan(6);
    expect(score.expectedPhraseHits).toEqual({
      "/tmp/VoiceLayer.socket": true,
      "missing tail": false,
    });
    expect(score.repeatedTail.repeated).toBe(true);
  });

  it("compares raw effort output against an archive baseline", () => {
    const comparison = compareTranscriptToReference(
      "AgentHTMLRebuild ran with one cursor worker.",
      "agent.htmlrebuild ran with one cursor worker.",
    );

    expect(comparison.source).toBe("archive-baseline");
    expect(comparison.normalizedSimilarity).toBeGreaterThan(0.9);
    expect(comparison.charDelta).toBe(-1);
    expect(comparison.wordDelta).toBe(-1);
    expect(normalizedTranscriptSimilarity("hello, world", "Hello world.")).toBe(1);
  });

  it("formats a compact markdown table for benchmark runs", () => {
    const markdown = formatBenchmarkMarkdown({
      createdAt: "2026-05-17T10:30:00.000Z",
      audio: ["/tmp/sample.wav"],
      results: [
        {
          planId: "server-bo5-bs5",
          audio: "/tmp/sample.wav",
          latencyMs: 1234,
          text: "hello world",
          score: scoreTranscript("hello world", ["hello"]),
          reference: compareTranscriptToReference("hello world", "hello world"),
        },
      ],
    });

    expect(markdown).toContain("# STT Decode Benchmark");
    expect(markdown).toContain("| server-bo5-bs5 |");
    expect(markdown).toContain("Archive sim");
    expect(markdown).toContain("## Archive Baselines");
    expect(markdown).toContain("## Raw Effort Decode Samples");
    expect(markdown).toContain("hello");
  });
});
