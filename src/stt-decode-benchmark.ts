export type DecodeBenchmarkPlanKind = "server" | "cli";

export interface DecodeBenchmarkPlan {
  id: string;
  kind: DecodeBenchmarkPlanKind;
  description: string;
  decodeArgs: string[];
}

export interface BuildWhisperServerArgsOptions {
  binary: string;
  model: string;
  port: number;
  decodeArgs?: string[];
  host?: string;
}

export interface BuildWhisperCliArgsOptions {
  binary: string;
  model: string;
  audio: string;
  language: string;
}

export interface RepeatedTail {
  repeated: boolean;
  phrase: string;
  count: number;
}

export interface TranscriptScore {
  charCount: number;
  wordCount: number;
  repeatedTail: RepeatedTail;
  expectedPhraseHits: Record<string, boolean>;
}

export interface DecodeBenchmarkResult {
  planId: string;
  audio: string;
  latencyMs: number;
  text: string;
  score: TranscriptScore;
  error?: string;
}

export interface DecodeBenchmarkReport {
  createdAt: string;
  audio: string[];
  results: DecodeBenchmarkResult[];
}

export const DEFAULT_DECODE_BENCHMARK_PLANS: DecodeBenchmarkPlan[] = [
  {
    id: "server-bo5-bs5",
    kind: "server",
    description: "Resident server with CLI-like best-of/beam defaults.",
    decodeArgs: ["-bo", "5", "-bs", "5"],
  },
  {
    id: "server-bo5-bs3",
    kind: "server",
    description: "Resident server with beam search reduced for latency.",
    decodeArgs: ["-bo", "5", "-bs", "3"],
  },
  {
    id: "server-defaults",
    kind: "server",
    description: "Resident server without explicit decode flags.",
    decodeArgs: [],
  },
  {
    id: "cli",
    kind: "cli",
    description: "whisper-cli one-shot baseline.",
    decodeArgs: [],
  },
];

export function buildWhisperServerArgs(
  options: BuildWhisperServerArgsOptions,
): string[] {
  return [
    options.binary,
    "-m",
    options.model,
    "--port",
    String(options.port),
    "--host",
    options.host ?? "127.0.0.1",
    "-t",
    "4",
    "-nt",
    ...(options.decodeArgs ?? []),
  ];
}

export function buildWhisperCliArgs(options: BuildWhisperCliArgsOptions): string[] {
  return [
    options.binary,
    "-m",
    options.model,
    "-f",
    options.audio,
    "-l",
    options.language,
    "-nt",
    "-np",
  ];
}

export function normalizeWords(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}']+/gu, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean);
}

export function detectRepeatedTail(text: string, maxPhraseWords = 12): RepeatedTail {
  const words = normalizeWords(text);
  const max = Math.min(maxPhraseWords, Math.floor(words.length / 2));

  for (let length = max; length >= 1; length--) {
    const tail = words.slice(-length);
    const previous = words.slice(-length * 2, -length);
    if (tail.length === 0 || previous.length !== tail.length) continue;
    if (tail.every((word, index) => word === previous[index])) {
      let count = 2;
      for (
        let offset = length * 3;
        offset <= words.length &&
        words
          .slice(-offset, -offset + length)
          .every((word, index) => word === tail[index]);
        offset += length
      ) {
        count++;
      }
      return {
        repeated: true,
        phrase: tail.join(" "),
        count,
      };
    }
  }

  return { repeated: false, phrase: "", count: 0 };
}

export function scoreTranscript(
  text: string,
  expectedPhrases: string[] = [],
): TranscriptScore {
  const normalizedText = text.toLowerCase();
  const expectedPhraseHits: Record<string, boolean> = {};
  for (const phrase of expectedPhrases) {
    expectedPhraseHits[phrase] = normalizedText.includes(phrase.toLowerCase());
  }

  return {
    charCount: text.length,
    wordCount: normalizeWords(text).length,
    repeatedTail: detectRepeatedTail(text),
    expectedPhraseHits,
  };
}

export function formatBenchmarkMarkdown(report: DecodeBenchmarkReport): string {
  const expectedPhrases = Array.from(
    new Set(
      report.results.flatMap((result) =>
        Object.keys(result.score.expectedPhraseHits),
      ),
    ),
  );

  const lines = [
    "# STT Decode Benchmark",
    "",
    `Created: ${report.createdAt}`,
    "",
    "## Audio",
    "",
    ...report.audio.map((audio) => `- \`${audio}\``),
    "",
    "## Results",
    "",
    "| Plan | Audio | Latency | Chars | Words | Repeated tail | Expected hits | Error |",
    "| --- | --- | ---: | ---: | ---: | --- | --- | --- |",
  ];

  for (const result of report.results) {
    const repeated = result.score.repeatedTail.repeated
      ? `${result.score.repeatedTail.count}x "${result.score.repeatedTail.phrase}"`
      : "no";
    const hits = expectedPhrases.length
      ? expectedPhrases
          .map((phrase) =>
            result.score.expectedPhraseHits[phrase] ? `yes:${phrase}` : `no:${phrase}`,
          )
          .join("<br>")
      : "n/a";

    lines.push(
      `| ${result.planId} | \`${result.audio}\` | ${Math.round(
        result.latencyMs,
      )}ms | ${result.score.charCount} | ${result.score.wordCount} | ${repeated} | ${hits} | ${
        result.error ?? ""
      } |`,
    );
  }

  lines.push("", "## Transcript Samples", "");

  for (const result of report.results) {
    lines.push(`### ${result.planId} - ${result.audio}`, "");
    if (result.error) {
      lines.push(`Error: ${result.error}`, "");
      continue;
    }
    lines.push("```text", result.text.trim(), "```", "");
  }

  return `${lines.join("\n")}\n`;
}
