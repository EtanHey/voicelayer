import { describe, expect, it } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { basename, join } from "path";
import {
  analyzeTranscriptCandidate,
  buildCleanupPairsFromRecordings,
  buildSTTQualityMiningReport,
  formatSTTQualityMiningMarkdown,
  loadCorrectionPairsFromJsonl,
  loadFreshDecodesFromBenchmarkReports,
  loadPolishPairsFromJsonl,
  loadVoiceBarRecordings,
} from "../stt-quality-mining";

function makeRecording(
  root: string,
  input: {
    day: string;
    id: string;
    createdAt: string;
    transcript: string;
    durationMs?: number;
    source?: "voicebar" | "voice_ask";
  },
): string {
  const dir = join(root, input.day, input.id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "audio.wav"), "fake wav");
  writeFileSync(join(dir, "voicelayer-transcript.txt"), input.transcript);
  writeFileSync(
    join(dir, "metadata.json"),
    `${JSON.stringify({
      id: input.id,
      created_at: input.createdAt,
      source: input.source ?? "voicebar",
      mode: "vad",
      silence_mode: "vad",
      duration_ms: input.durationMs ?? 1200,
      sample_rate: 16000,
      channels: 1,
      backend: "whisper-server",
      language_mode: "auto",
      voicelayer_transcript_chars: input.transcript.length,
      audio_sha256: "abc123",
      app_version: null,
      schema_version: 1,
    })}\n`,
  );
  return dir;
}

describe("stt-quality-mining", () => {
  it("loads VoiceBar recordings from a date-windowed archive without touching Wispr data", () => {
    const root = mkdtempSync(join(tmpdir(), "voicelayer-mining-"));
    try {
      makeRecording(root, {
        day: "2026-05-14",
        id: "old",
        createdAt: "2026-05-14T08:00:00.000Z",
        transcript: "old transcript",
      });
      makeRecording(root, {
        day: "2026-05-20",
        id: "current",
        createdAt: "2026-05-20T08:00:00.000Z",
        transcript: "VisionPro showed up in PR 222 s notes.",
      });

      const recordings = loadVoiceBarRecordings({
        archiveRoot: root,
        since: new Date("2026-05-19T00:00:00.000Z"),
        until: new Date("2026-05-21T00:00:00.000Z"),
      });

      expect(recordings.map((recording) => recording.id)).toEqual(["current"]);
      expect(recordings[0].source).toBe("voicebar");
      expect(basename(recordings[0].audioPath)).toBe("audio.wav");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("skips incomplete archives that do not have audio for review or re-decode", () => {
    const root = mkdtempSync(join(tmpdir(), "voicelayer-mining-missing-audio-"));
    try {
      const dir = makeRecording(root, {
        day: "2026-05-20",
        id: "missing-audio",
        createdAt: "2026-05-20T08:00:00.000Z",
        transcript: "Transcript without audio should not enter mining.",
      });
      unlinkSync(join(dir, "audio.wav"));

      const recordings = loadVoiceBarRecordings({
        archiveRoot: root,
        since: new Date("2026-05-19T00:00:00.000Z"),
        until: new Date("2026-05-21T00:00:00.000Z"),
      });

      expect(recordings).toEqual([]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("excludes paired voice_ask rounds from VoiceBar quality mining", () => {
    const root = mkdtempSync(join(tmpdir(), "voicelayer-mining-source-"));
    try {
      makeRecording(root, {
        day: "2026-05-20",
        id: "voicebar-round",
        createdAt: "2026-05-20T08:00:00.000Z",
        transcript: "VoiceBar recording stays in the mining population.",
      });
      makeRecording(root, {
        day: "2026-05-20",
        id: "voice-ask-round",
        createdAt: "2026-05-20T09:00:00.000Z",
        transcript: "Voice ask reply must not enter VoiceBar mining.",
        source: "voice_ask",
      });

      const recordings = loadVoiceBarRecordings({
        archiveRoot: root,
        since: new Date("2026-05-19T00:00:00.000Z"),
        until: new Date("2026-05-21T00:00:00.000Z"),
      });

      expect(recordings.map((recording) => recording.id)).toEqual([
        "voicebar-round",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("tags deterministic failure categories in a single transcript candidate", () => {
    const candidate = analyzeTranscriptCandidate({
      id: "sample",
      source: "archived",
      text: "VisionPro shipped in PR 222 s notes, period comma. I don't know. I don't know.",
    });

    expect(candidate.findings.map((finding) => finding.category)).toEqual([
      "duplicated_phrase",
      "possessive_phrase_errors",
      "punctuation_artifacts",
      "product_code_term_spacing",
    ]);
    expect(candidate.findings.some((finding) => finding.pattern === "VisionPro")).toBe(
      true,
    );
  });

  it("does not classify ordinary duration words as possessive phrase errors", () => {
    const candidate = analyzeTranscriptCandidate({
      id: "duration",
      source: "archived",
      text: "This took 30 seconds and the next step took two seconds.",
    });

    expect(
      candidate.findings.some(
        (finding) => finding.category === "possessive_phrase_errors",
      ),
    ).toBe(false);
  });

  it("does not classify canonical second-S as a possessive phrase error", () => {
    const candidate = analyzeTranscriptCandidate({
      id: "canonical-second-s",
      source: "cleanup",
      text: "The second-S possessive issue is already normalized.",
    });

    expect(
      candidate.findings.some(
        (finding) => finding.category === "possessive_phrase_errors",
      ),
    ).toBe(false);
  });

  it("filters polish shadow rows to the requested window", () => {
    const root = mkdtempSync(join(tmpdir(), "voicelayer-polish-window-"));
    const polishPath = join(root, "polish-shadow.jsonl");
    try {
      writeFileSync(
        polishPath,
        [
          JSON.stringify({
            created_at: "2026-05-14T08:00:00.000Z",
            cleaned_text: "Old VisionPro row.",
            polished_text: "Old Vision Pro row.",
            status: "shadowed",
          }),
          JSON.stringify({
            created_at: "2026-05-20T08:00:00.000Z",
            cleaned_text: "Current VisionPro row.",
            polished_text: "Current Vision Pro row.",
            status: "shadowed",
          }),
          JSON.stringify({
            cleaned_text: "Undated VisionPro row.",
            polished_text: "Undated Vision Pro row.",
            status: "shadowed",
          }),
        ].join("\n"),
      );

      const pairs = loadPolishPairsFromJsonl(polishPath, {
        since: new Date("2026-05-19T00:00:00.000Z"),
        until: new Date("2026-05-21T00:00:00.000Z"),
      });

      expect(pairs.map((pair) => pair.cleanedText)).toEqual([
        "Current VisionPro row.",
      ]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("skips malformed fresh decode benchmark rows without throwing", () => {
    const root = mkdtempSync(join(tmpdir(), "voicelayer-benchmark-json-"));
    const benchmarkPath = join(root, "benchmark.json");
    try {
      writeFileSync(
        benchmarkPath,
        JSON.stringify({
          createdAt: "2026-05-21T08:00:00.000Z",
          audio: ["/tmp/audio.wav"],
          results: [
            { planId: "missing-text", audio: "/tmp/audio.wav", latencyMs: 10 },
            {
              planId: "valid",
              audio: "/tmp/audio.wav",
              latencyMs: 20,
              text: "Valid transcript.",
              score: {},
            },
          ],
        }),
      );

      const freshDecodes = loadFreshDecodesFromBenchmarkReports([benchmarkPath]);

      expect(freshDecodes.map((decode) => decode.variant)).toEqual(["valid"]);
      expect(freshDecodes[0].text).toBe("Valid transcript.");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("compares archive, fresh decode, cleanup, and polish candidates into pass-based findings", () => {
    const report = buildSTTQualityMiningReport({
      createdAt: "2026-05-21T12:00:00.000Z",
      recordings: [
        {
          id: "rec-1",
          createdAt: "2026-05-21T08:00:00.000Z",
          directory: "/tmp/rec-1",
          audioPath: "/tmp/rec-1/audio.wav",
          transcriptPath: "/tmp/rec-1/voicelayer-transcript.txt",
          transcript: "Start with the full request and keep the real tail.",
          durationMs: 1000,
          backend: "whisper-server",
          languageMode: "auto",
          source: "voicebar",
        },
      ],
      freshDecodes: [
        {
          id: "fresh-1",
          recordingId: "rec-1",
          source: "fresh_decode",
          variant: "cli",
          audioPath: "/tmp/rec-1/audio.wav",
          text: "With the full request and keep the",
        },
      ],
      cleanupPairs: [
        {
          id: "cleanup-1",
          rawText: "um use VisionPro in PR 222 s notes",
          cleanedText: "Use VisionPro in PR 222 s notes",
        },
      ],
      polishPairs: [
        {
          id: "polish-1",
          cleanedText: "Use VisionPro in PR 222 s notes",
          polishedText: "Use Vision Pro in PR 222's notes",
          status: "shadowed",
        },
      ],
      correctionPairs: [],
    });

    expect(report.summary.recordings).toBe(1);
    expect(report.summary.findingsByCategory.missing_head_tail).toBe(1);
    expect(report.summary.findingsByCategory.filler_disfluency_handling).toBe(1);
    expect(report.summary.findingsByCategory.product_code_term_spacing).toBe(2);
    expect(report.passes.map((pass) => pass.name)).toEqual([
      "archive-intrinsic",
      "fresh-decode-comparison",
      "cleanup-shadow",
      "polish-shadow",
      "user-correction-comparison",
    ]);
  });

  it("flags shorter fresh decodes that drop only head or tail boundary words", () => {
    const report = buildSTTQualityMiningReport({
      createdAt: "2026-05-21T12:00:00.000Z",
      recordings: [
        {
          id: "rec-boundary",
          createdAt: "2026-05-21T08:00:00.000Z",
          directory: "/tmp/rec-boundary",
          audioPath: "/tmp/rec-boundary/audio.wav",
          transcriptPath: "/tmp/rec-boundary/voicelayer-transcript.txt",
          transcript: "Start with the full request and keep the real tail.",
          durationMs: 1000,
          backend: "whisper-server",
          languageMode: "auto",
          source: "voicebar",
        },
      ],
      freshDecodes: [
        {
          id: "fresh-head",
          recordingId: "rec-boundary",
          source: "fresh_decode",
          variant: "cli",
          audioPath: "/tmp/rec-boundary/audio.wav",
          text: "With the full request and keep the real tail.",
        },
        {
          id: "fresh-tail",
          recordingId: "rec-boundary",
          source: "fresh_decode",
          variant: "cli",
          audioPath: "/tmp/rec-boundary/audio.wav",
          text: "Start with the full request and keep the real.",
        },
      ],
      cleanupPairs: [],
      polishPairs: [],
      correctionPairs: [],
    });

    const missingBoundaryFindings = report.passes
      .find((pass) => pass.name === "fresh-decode-comparison")
      ?.findings.filter(
        (finding) => finding.category === "missing_head_tail",
      );

    expect(missingBoundaryFindings?.map((finding) => finding.candidateId)).toEqual([
      "fresh-head",
      "fresh-tail",
    ]);
  });

  it("does not report cleanup rewrites as missing head/tail or semantic drift", () => {
    const report = buildSTTQualityMiningReport({
      createdAt: "2026-05-21T12:00:00.000Z",
      recordings: [],
      freshDecodes: [],
      cleanupPairs: [
        {
          id: "cleanup-rewrite",
          rawText:
            "um maybe we should use VisionPro in PR 222 s notes because the product spacing is wrong",
          cleanedText: "Use Vision Pro in PR 222's notes.",
        },
      ],
      polishPairs: [],
      correctionPairs: [],
    });

    const cleanupFindings =
      report.passes.find((pass) => pass.name === "cleanup-shadow")?.findings ?? [];
    expect(
      cleanupFindings.some(
        (finding) =>
          finding.category === "missing_head_tail" ||
          finding.category === "semantic_substitutions",
      ),
    ).toBe(false);
  });

  it("formats a privacy-preserving markdown report with skill recommendation", () => {
    const report = buildSTTQualityMiningReport({
      createdAt: "2026-05-21T12:00:00.000Z",
      recordings: [],
      freshDecodes: [],
      cleanupPairs: [],
      polishPairs: [],
      correctionPairs: [],
    });

    const markdown = formatSTTQualityMiningMarkdown(report);

    expect(markdown).toContain("# VoiceLayer STT Quality Mining Report");
    expect(markdown).toContain("## Recommendation");
    expect(markdown).toContain("general `$stt-quality-mining` skill");
    expect(markdown).not.toContain("```text");
  });

  it("builds cleanup pairs only when current cleanup changes archived text", () => {
    const pairs = buildCleanupPairsFromRecordings([
      {
        id: "unchanged",
        createdAt: "2026-05-21T08:00:00.000Z",
        directory: "/tmp/unchanged",
        audioPath: "/tmp/unchanged/audio.wav",
        transcriptPath: "/tmp/unchanged/voicelayer-transcript.txt",
        transcript: "This is already clean.",
        durationMs: 1000,
        backend: "whisper-server",
        languageMode: "auto",
        source: "voicebar",
      },
      {
        id: "changed",
        createdAt: "2026-05-21T08:01:00.000Z",
        directory: "/tmp/changed",
        audioPath: "/tmp/changed/audio.wav",
        transcriptPath: "/tmp/changed/voicelayer-transcript.txt",
        transcript: "um brain layer",
        durationMs: 1000,
        backend: "whisper-server",
        languageMode: "auto",
        source: "voicebar",
      },
    ]);

    expect(pairs).toEqual([
      {
        id: "changed",
        rawText: "um brain layer",
        cleanedText: "BrainLayer",
      },
    ]);
  });

  it("loads user correction pairs and classifies subtle semantic/punctuation drift", () => {
    const root = mkdtempSync(join(tmpdir(), "voicelayer-corrections-"));
    const correctionsPath = join(root, "corrections.jsonl");
    try {
      writeFileSync(
        correctionsPath,
        `${JSON.stringify({
          id: "latest",
          observed_text:
            "or should I not change it, or just relay everything that we're about to do to code? Coach Claude, or I'll just remember that we're doing something and I'll just still present what I have in the lecture.",
          expected_text:
            "or should I not change it, or just relay everything that we're about to do to Coach Claude? or I'll just remember that we're doing something and I'll just still present what I have in the lecture?",
        })}\n`,
      );

      const correctionPairs = loadCorrectionPairsFromJsonl(correctionsPath);
      const report = buildSTTQualityMiningReport({
        createdAt: "2026-05-21T12:00:00.000Z",
        recordings: [],
        freshDecodes: [],
        cleanupPairs: [],
        polishPairs: [],
        correctionPairs,
      });

      expect(correctionPairs).toHaveLength(1);
      expect(report.summary.correctionPairs).toBe(1);
      expect(report.summary.findingsByCategory.entity_boundary_errors).toBe(1);
      expect(report.summary.findingsByCategory.semantic_substitutions).toBe(1);
      expect(report.summary.findingsByCategory.punctuation_artifacts).toBe(1);
      expect(report.passes.map((pass) => pass.name)).toContain(
        "user-correction-comparison",
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("runs the CLI with a corrections JSONL and writes a report", async () => {
    const root = mkdtempSync(join(tmpdir(), "voicelayer-cli-corrections-"));
    const archiveRoot = join(root, "recordings");
    const outputDir = join(root, "reports");
    const correctionsPath = join(root, "corrections.jsonl");
    try {
      makeRecording(archiveRoot, {
        day: "2026-05-20",
        id: "sample",
        createdAt: "2026-05-20T08:00:00.000Z",
        transcript: "This is already clean.",
      });
      writeFileSync(
        correctionsPath,
        `${JSON.stringify({
          id: "cli-correction",
          observed: "Send this to code? Coach Claude, then continue.",
          expected: "Send this to Coach Claude? then continue.",
        })}\n`,
      );

      const proc = Bun.spawn([
        "bun",
        "run",
        "scripts/mine-stt-quality.ts",
        "--archive-root",
        archiveRoot,
        "--since",
        "2026-05-19T00:00:00.000Z",
        "--until",
        "2026-05-21T00:00:00.000Z",
        "--corrections-jsonl",
        correctionsPath,
        "--output-dir",
        outputDir,
      ], {
        cwd: process.cwd(),
        stdout: "pipe",
        stderr: "pipe",
      });

      const [stdout, stderr, exitCode] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
      expect(stderr).toBe("");
      expect(exitCode).toBe(0);
      expect(stdout).toContain("User correction pairs: 1");

      const match = stdout.match(/Wrote (.*stt-quality-mining-.*\.json)/);
      expect(match?.[1]).toBeTruthy();
      const report = JSON.parse(readFileSync(match![1], "utf8"));
      expect(report.summary.correctionPairs).toBe(1);
      expect(report.summary.findingsByCategory.entity_boundary_errors).toBe(1);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("fails the CLI when an explicit polish log path is missing", async () => {
    const root = mkdtempSync(join(tmpdir(), "voicelayer-cli-polish-missing-"));
    try {
      const proc = Bun.spawn([
        "bun",
        "run",
        "scripts/mine-stt-quality.ts",
        "--archive-root",
        join(root, "recordings"),
        "--polish-log",
        join(root, "missing-polish.jsonl"),
        "--output-dir",
        join(root, "reports"),
      ], {
        cwd: process.cwd(),
        stdout: "pipe",
        stderr: "pipe",
      });

      const [stderr, exitCode] = await Promise.all([
        new Response(proc.stderr).text(),
        proc.exited,
      ]);

      expect(exitCode).toBe(1);
      expect(stderr).toContain("Polish shadow JSONL not found:");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
