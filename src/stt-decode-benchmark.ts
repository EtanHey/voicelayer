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

export interface TranscriptReferenceComparison {
  source: "archive-baseline";
  text: string;
  normalizedSimilarity: number;
  charDelta: number;
  wordDelta: number;
}

export interface DecodeBenchmarkResult {
  planId: string;
  audio: string;
  latencyMs: number;
  text: string;
  score: TranscriptScore;
  reference?: TranscriptReferenceComparison;
  error?: string;
}

export interface DecodeBenchmarkReport {
  createdAt: string;
  audio: string[];
  results: DecodeBenchmarkResult[];
}

export const DEFAULT_DECODE_BENCHMARK_PLANS: DecodeBenchmarkPlan[] = [
  {
    id: "effort-fast",
    kind: "server",
    description: "Fast VoiceBar effort preset.",
    decodeArgs: ["-bo", "1", "-bs", "1"],
  },
  {
    id: "effort-balanced",
    kind: "server",
    description: "Balanced VoiceBar effort preset.",
    decodeArgs: ["-bo", "3", "-bs", "3"],
  },
  {
    id: "effort-accurate",
    kind: "server",
    description: "Accurate VoiceBar effort preset.",
    decodeArgs: ["-bo", "5", "-bs", "5"],
  },
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

function normalizedSimilarityText(text: string): string {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}']+/gu, " ")
    .trim();
}

function levenshteinDistance(a: string, b: string): number {
  if (a === b) return 0;
  if (!a) return b.length;
  if (!b) return a.length;

  const previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  const current = new Array<number>(b.length + 1);

  for (let i = 1; i <= a.length; i++) {
    current[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const substitutionCost = a[i - 1] === b[j - 1] ? 0 : 1;
      current[j] = Math.min(
        previous[j] + 1,
        current[j - 1] + 1,
        previous[j - 1] + substitutionCost,
      );
    }
    for (let j = 0; j <= b.length; j++) previous[j] = current[j];
  }

  return previous[b.length];
}

export function normalizedTranscriptSimilarity(
  candidate: string,
  reference: string,
): number {
  const left = normalizedSimilarityText(candidate);
  const right = normalizedSimilarityText(reference);
  if (!left && !right) return 1;
  const maxLength = Math.max(left.length, right.length);
  if (maxLength === 0) return 1;
  return 1 - levenshteinDistance(left, right) / maxLength;
}

export function compareTranscriptToReference(
  candidate: string,
  reference: string,
): TranscriptReferenceComparison {
  return {
    source: "archive-baseline",
    text: reference,
    normalizedSimilarity: normalizedTranscriptSimilarity(candidate, reference),
    charDelta: candidate.length - reference.length,
    wordDelta: normalizeWords(candidate).length - normalizeWords(reference).length,
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
    "| Plan | Audio | Latency | Chars | Words | Archive sim | Word delta | Repeated tail | Expected hits | Error |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |",
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
    const similarity =
      result.reference?.normalizedSimilarity === undefined
        ? "n/a"
        : result.reference.normalizedSimilarity.toFixed(3);
    const wordDelta =
      result.reference?.wordDelta === undefined
        ? "n/a"
        : String(result.reference.wordDelta);

    lines.push(
      `| ${result.planId} | \`${result.audio}\` | ${Math.round(
        result.latencyMs,
      )}ms | ${result.score.charCount} | ${result.score.wordCount} | ${similarity} | ${wordDelta} | ${repeated} | ${hits} | ${
        result.error ?? ""
      } |`,
    );
  }

  const references = new Map<string, string>();
  for (const result of report.results) {
    if (result.reference && !references.has(result.audio)) {
      references.set(result.audio, result.reference.text);
    }
  }

  if (references.size > 0) {
    lines.push("", "## Archive Baselines", "");
    for (const [audio, text] of references) {
      lines.push(`### ${audio}`, "", "```text", text.trim(), "```", "");
    }
  }

  lines.push("", "## Raw Effort Decode Samples", "");

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
