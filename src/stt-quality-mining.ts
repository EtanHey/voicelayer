import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "fs";
import { homedir } from "os";
import { basename, join, resolve } from "path";
import { cleanupTranscriptionText } from "./stt-cleanup";
import {
  detectRepeatedTail,
  normalizeWords,
  type DecodeBenchmarkReport,
} from "./stt-decode-benchmark";

export type STTQualityCandidateSource =
  | "archived"
  | "fresh_decode"
  | "cleanup"
  | "polish"
  | "user_correction";

export type STTQualityFindingCategory =
  | "missing_head_tail"
  | "duplicated_phrase"
  | "possessive_phrase_errors"
  | "punctuation_artifacts"
  | "product_code_term_spacing"
  | "entity_boundary_errors"
  | "semantic_substitutions"
  | "filler_disfluency_handling";

export interface VoiceBarRecordingForMining {
  id: string;
  createdAt: string;
  directory: string;
  audioPath: string;
  transcriptPath: string;
  transcript: string;
  durationMs: number | null;
  backend: string | null;
  languageMode: string | null;
  source: "voicebar";
}

export interface LoadVoiceBarRecordingsOptions {
  archiveRoot?: string;
  since: Date;
  until: Date;
  limit?: number;
}

export interface STTFreshDecodeCandidate {
  id: string;
  recordingId?: string;
  source: "fresh_decode";
  variant: string;
  audioPath: string;
  text: string;
  latencyMs?: number;
  error?: string;
}

export interface STTCleanupPair {
  id: string;
  rawText: string;
  cleanedText: string;
}

export interface STTPolishPair {
  id: string;
  createdAt?: string;
  cleanedText: string;
  polishedText: string;
  status?: string;
  error?: string;
}

export interface STTCorrectionPair {
  id: string;
  observedText: string;
  expectedText: string;
  note?: string;
}

export interface STTQualityFinding {
  category: STTQualityFindingCategory;
  pass: string;
  candidateId: string;
  recordingId?: string;
  source: STTQualityCandidateSource;
  variant?: string;
  pattern: string;
  detail: string;
  severity: "low" | "medium" | "high";
}

export interface AnalyzedTranscriptCandidate {
  id: string;
  recordingId?: string;
  source: STTQualityCandidateSource;
  variant?: string;
  wordCount: number;
  charCount: number;
  findings: STTQualityFinding[];
}

export interface STTQualityMiningInput {
  createdAt?: string;
  recordings: VoiceBarRecordingForMining[];
  freshDecodes: STTFreshDecodeCandidate[];
  cleanupPairs: STTCleanupPair[];
  polishPairs: STTPolishPair[];
  correctionPairs?: STTCorrectionPair[];
}

export interface STTQualityMiningPass {
  name: string;
  description: string;
  findings: STTQualityFinding[];
}

export interface STTQualityMiningReport {
  createdAt: string;
  recommendation: string;
  summary: {
    recordings: number;
    freshDecodes: number;
    cleanupPairs: number;
    polishPairs: number;
    correctionPairs: number;
    findings: number;
    findingsByCategory: Record<STTQualityFindingCategory, number>;
  };
  passes: STTQualityMiningPass[];
  recurringPatterns: Array<{
    category: STTQualityFindingCategory;
    pattern: string;
    count: number;
    severity: "low" | "medium" | "high";
  }>;
}

const CATEGORY_ORDER: STTQualityFindingCategory[] = [
  "missing_head_tail",
  "duplicated_phrase",
  "possessive_phrase_errors",
  "punctuation_artifacts",
  "product_code_term_spacing",
  "entity_boundary_errors",
  "semantic_substitutions",
  "filler_disfluency_handling",
];

const PRODUCT_SPACING_PATTERNS: Array<[RegExp, string]> = [
  [/\bVisionPro\b/g, "VisionPro"],
  [/\bWisprFlow\b/g, "WisprFlow"],
  [/\bWhisperFlow\b/g, "WhisperFlow"],
  [/\bCursorBugbot\b/g, "CursorBugbot"],
  [/\bPullRequest\b/g, "PullRequest"],
];

const FILLER_PATTERN =
  /\b(?:um+|uh+|erm|er|ah+|like like|you know you know)\b|(?:\bכאילו\b\s*){2,}/giu;

const ENTITY_BOUNDARY_PHRASES = [
  "Coach Claude",
  "YashClaude",
  "SkillCreatorClaude",
  "orcClaude",
  "Codex",
  "VoiceLayer",
  "VoiceBar",
  "BrainLayer",
];

function defaultRecordingsRoot(): string {
  return join(homedir(), ".local", "share", "voicelayer", "recordings");
}

function readJson(path: string): Record<string, unknown> | null {
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return parsed && typeof parsed === "object"
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function dateInWindow(iso: string, since: Date, until: Date): boolean {
  const time = new Date(iso).getTime();
  return (
    Number.isFinite(time) &&
    time >= since.getTime() &&
    time < until.getTime()
  );
}

export function loadVoiceBarRecordings(
  options: LoadVoiceBarRecordingsOptions,
): VoiceBarRecordingForMining[] {
  const archiveRoot = resolve(options.archiveRoot ?? defaultRecordingsRoot());
  if (!existsSync(archiveRoot)) return [];

  const recordings: VoiceBarRecordingForMining[] = [];
  for (const dayEntry of readdirSync(archiveRoot).sort()) {
    const dayDir = join(archiveRoot, dayEntry);
    if (!statSync(dayDir).isDirectory()) continue;

    for (const recordingEntry of readdirSync(dayDir).sort()) {
      if (recordingEntry.startsWith(".")) continue;
      const directory = join(dayDir, recordingEntry);
      if (!statSync(directory).isDirectory()) continue;

      const metadataPath = join(directory, "metadata.json");
      const transcriptPath = join(directory, "voicelayer-transcript.txt");
      const audioPath = join(directory, "audio.wav");
      if (!existsSync(metadataPath) || !existsSync(transcriptPath) || !existsSync(audioPath)) continue;

      const metadata = readJson(metadataPath);
      const createdAt =
        stringValue(metadata?.created_at) ?? `${dayEntry}T00:00:00.000Z`;
      if (!dateInWindow(createdAt, options.since, options.until)) continue;

      const transcript = readFileSync(transcriptPath, "utf8").trim();
      if (!transcript) continue;

      recordings.push({
        id: stringValue(metadata?.id) ?? recordingEntry,
        createdAt,
        directory,
        audioPath,
        transcriptPath,
        transcript,
        durationMs: numberValue(metadata?.duration_ms),
        backend: stringValue(metadata?.backend),
        languageMode: stringValue(metadata?.language_mode),
        source: "voicebar",
      });
    }
  }

  recordings.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  return options.limit ? recordings.slice(-options.limit) : recordings;
}

function makeFinding(input: {
  category: STTQualityFindingCategory;
  pass: string;
  candidateId: string;
  recordingId?: string;
  source: STTQualityCandidateSource;
  variant?: string;
  pattern: string;
  detail: string;
  severity?: "low" | "medium" | "high";
}): STTQualityFinding {
  return {
    category: input.category,
    pass: input.pass,
    candidateId: input.candidateId,
    recordingId: input.recordingId,
    source: input.source,
    variant: input.variant,
    pattern: input.pattern,
    detail: input.detail,
    severity: input.severity ?? "medium",
  };
}

export function analyzeTranscriptCandidate(input: {
  id: string;
  recordingId?: string;
  source: STTQualityCandidateSource;
  variant?: string;
  text: string;
  pass?: string;
}): AnalyzedTranscriptCandidate {
  const pass = input.pass ?? "archive-intrinsic";
  const findings: STTQualityFinding[] = [];
  const repeatedTail = detectRepeatedTail(input.text);

  if (repeatedTail.repeated) {
    findings.push(
      makeFinding({
        category: "duplicated_phrase",
        pass,
        candidateId: input.id,
        recordingId: input.recordingId,
        source: input.source,
        variant: input.variant,
        pattern: repeatedTail.phrase,
        detail: `Repeated tail detected ${repeatedTail.count}x.`,
        severity: repeatedTail.count >= 3 ? "high" : "medium",
      }),
    );
  }

  for (const match of input.text.matchAll(
    /\b(?:PR|pull request)\s*#?\s*\d+\s+['’]?[sS]\b|\bsecond(?:\s+-\s*|\s+)[sS]\b/giu,
  )) {
    findings.push(
      makeFinding({
        category: "possessive_phrase_errors",
        pass,
        candidateId: input.id,
        recordingId: input.recordingId,
        source: input.source,
        variant: input.variant,
        pattern: match[0],
        detail: "Possessive marker appears separated from the owner phrase.",
        severity: "high",
      }),
    );
  }

  for (const match of input.text.matchAll(
    /\b(?:period|comma|quote|colon|semicolon)\s+(?:period|comma|quote|colon|semicolon)\b|[.?!],|,[.?!]|["'“”‘’]\s+[,.?!]/giu,
  )) {
    findings.push(
      makeFinding({
        category: "punctuation_artifacts",
        pass,
        candidateId: input.id,
        recordingId: input.recordingId,
        source: input.source,
        variant: input.variant,
        pattern: match[0],
        detail: "Likely spoken or malformed punctuation artifact.",
      }),
    );
  }

  for (const [pattern, label] of PRODUCT_SPACING_PATTERNS) {
    for (const match of input.text.matchAll(pattern)) {
      findings.push(
        makeFinding({
          category: "product_code_term_spacing",
          pass,
          candidateId: input.id,
          recordingId: input.recordingId,
          source: input.source,
          variant: input.variant,
          pattern: match[0] || label,
          detail: `Known product/code term spacing candidate: ${label}.`,
        }),
      );
    }
  }

  for (const match of input.text.matchAll(FILLER_PATTERN)) {
    findings.push(
      makeFinding({
        category: "filler_disfluency_handling",
        pass,
        candidateId: input.id,
        recordingId: input.recordingId,
        source: input.source,
        variant: input.variant,
        pattern: match[0].trim(),
        detail: "Residual filler/disfluency candidate after cleanup.",
        severity: "low",
      }),
    );
  }

  findings.sort(
    (a, b) =>
      CATEGORY_ORDER.indexOf(a.category) - CATEGORY_ORDER.indexOf(b.category),
  );

  return {
    id: input.id,
    recordingId: input.recordingId,
    source: input.source,
    variant: input.variant,
    wordCount: normalizeWords(input.text).length,
    charCount: input.text.length,
    findings,
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

function normalizedSimilarity(left: string, right: string): number {
  const a = normalizedSimilarityText(left);
  const b = normalizedSimilarityText(right);
  if (!a && !b) return 1;
  const maxLength = Math.max(a.length, b.length);
  if (maxLength === 0) return 1;
  return 1 - levenshteinDistance(a, b) / maxLength;
}

function firstWordsMissing(reference: string[], candidate: string[]): boolean {
  const head = contentWords(reference.slice(0, Math.min(5, reference.length)));
  if (head.length < 2) return false;
  const candidateHead = contentWords(
    candidate.slice(0, Math.max(6, head.length + 2)),
  );
  if (candidateHead.length === 0) return true;
  return candidateHead[0] !== head[0];
}

function lastWordsMissing(reference: string[], candidate: string[]): boolean {
  const tail = contentWords(reference.slice(-Math.min(5, reference.length)));
  if (tail.length < 2) return false;
  const candidateTail = contentWords(
    candidate.slice(-Math.max(6, tail.length + 2)),
  );
  if (candidateTail.length === 0) return true;
  return candidateTail[candidateTail.length - 1] !== tail[tail.length - 1];
}

const BOUNDARY_STOPWORDS = new Set([
  "a",
  "an",
  "and",
  "the",
  "to",
  "of",
  "in",
  "on",
  "for",
  "with",
]);

function contentWords(words: string[]): string[] {
  return words.filter((word) => !BOUNDARY_STOPWORDS.has(word));
}

function compareTranscriptPair(input: {
  pass: string;
  candidateId: string;
  recordingId?: string;
  source: STTQualityCandidateSource;
  variant?: string;
  referenceText: string;
  candidateText: string;
}): STTQualityFinding[] {
  const referenceWords = normalizeWords(input.referenceText);
  const candidateWords = normalizeWords(input.candidateText);
  const findings: STTQualityFinding[] = [];

  if (
    referenceWords.length >= 6 &&
    candidateWords.length < referenceWords.length &&
    (firstWordsMissing(referenceWords, candidateWords) ||
      lastWordsMissing(referenceWords, candidateWords))
  ) {
    findings.push(
      makeFinding({
        category: "missing_head_tail",
        pass: input.pass,
        candidateId: input.candidateId,
        recordingId: input.recordingId,
        source: input.source,
        variant: input.variant,
        pattern: "candidate-shorter-boundary-mismatch",
        detail: "Candidate is materially shorter and appears to miss head/tail words.",
        severity: "high",
      }),
    );
  }

  const similarity = normalizedSimilarity(input.referenceText, input.candidateText);
  if (
    referenceWords.length >= 8 &&
    candidateWords.length >= 8 &&
    similarity < 0.72 &&
    findings.length === 0
  ) {
    findings.push(
      makeFinding({
        category: "semantic_substitutions",
        pass: input.pass,
        candidateId: input.candidateId,
        recordingId: input.recordingId,
        source: input.source,
        variant: input.variant,
        pattern: `similarity:${similarity.toFixed(2)}`,
        detail: "Candidate diverges enough to require human/local-review classification.",
        severity: "high",
      }),
    );
  }

  return findings;
}

function punctuationSkeleton(text: string): string {
  return text.normalize("NFKC").replace(/[\p{L}\p{N}\s]+/gu, "");
}

function correctionTokenSequenceChanged(
  observedText: string,
  expectedText: string,
): boolean {
  return normalizeWords(observedText).join(" ") !== normalizeWords(expectedText).join(" ");
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function normalizedBoundaryText(text: string): string {
  return text
    .normalize("NFKC")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function entityBoundaryFindings(pair: STTCorrectionPair): STTQualityFinding[] {
  const observed = normalizedBoundaryText(pair.observedText);
  const expected = normalizedBoundaryText(pair.expectedText);
  const findings: STTQualityFinding[] = [];

  for (const entity of ENTITY_BOUNDARY_PHRASES) {
    const normalizedEntity = normalizedBoundaryText(entity);
    const escapedEntity = escapeRegExp(normalizedEntity).replace(/\s+/g, "\\s+");
    const expectedRoutingPattern = new RegExp(
      `\\b(?:to|ask|tell|message|send\\s+this\\s+to|send\\s+to)\\s+${escapedEntity}\\b`,
      "u",
    );
    const observedSplitPattern = new RegExp(
      `\\b(?:to|ask|tell|message|send\\s+this\\s+to|send\\s+to)\\s+(?:code|codex|claude)\\s+${escapedEntity}\\b`,
      "u",
    );

    if (
      expectedRoutingPattern.test(expected) &&
      observedSplitPattern.test(observed)
    ) {
      findings.push(
        makeFinding({
          category: "entity_boundary_errors",
          pass: "user-correction-comparison",
          candidateId: pair.id,
          source: "user_correction",
          pattern: `entity-boundary:${entity}`,
          detail:
            "User correction moved a known assistant/entity name back into the routed phrase boundary.",
          severity: "high",
        }),
      );
    }
  }

  return findings;
}

function compareCorrectionPair(pair: STTCorrectionPair): STTQualityFinding[] {
  const findings: STTQualityFinding[] = entityBoundaryFindings(pair);
  const pass = "user-correction-comparison";

  if (correctionTokenSequenceChanged(pair.observedText, pair.expectedText)) {
    findings.push(
      makeFinding({
        category: "semantic_substitutions",
        pass,
        candidateId: pair.id,
        source: "user_correction",
        pattern: "user-correction-token-drift",
        detail:
          "User correction changed the word sequence; review local audio/context before creating rules.",
        severity: "high",
      }),
    );
  }

  if (punctuationSkeleton(pair.observedText) !== punctuationSkeleton(pair.expectedText)) {
    findings.push(
      makeFinding({
        category: "punctuation_artifacts",
        pass,
        candidateId: pair.id,
        source: "user_correction",
        pattern: "user-correction-punctuation-drift",
        detail: "User correction changed sentence-boundary or punctuation structure.",
        severity: "medium",
      }),
    );
  }

  return findings;
}

function initCategoryCounts(): Record<STTQualityFindingCategory, number> {
  return Object.fromEntries(CATEGORY_ORDER.map((category) => [category, 0])) as Record<
    STTQualityFindingCategory,
    number
  >;
}

function makePass(
  name: string,
  description: string,
  findings: STTQualityFinding[],
): STTQualityMiningPass {
  findings.sort(
    (a, b) =>
      CATEGORY_ORDER.indexOf(a.category) - CATEGORY_ORDER.indexOf(b.category) ||
      a.pattern.localeCompare(b.pattern),
  );
  return { name, description, findings };
}

export function buildSTTQualityMiningReport(
  input: STTQualityMiningInput,
): STTQualityMiningReport {
  const correctionPairs = input.correctionPairs ?? [];
  const recordingsByAudio = new Map(
    input.recordings.map((recording) => [recording.audioPath, recording]),
  );

  const archiveFindings = input.recordings.flatMap((recording) =>
    analyzeTranscriptCandidate({
      id: recording.id,
      recordingId: recording.id,
      source: "archived",
      text: recording.transcript,
      pass: "archive-intrinsic",
    }).findings,
  );

  const freshFindings = input.freshDecodes.flatMap((candidate) => {
    const recording =
      (candidate.recordingId &&
        input.recordings.find((item) => item.id === candidate.recordingId)) ||
      recordingsByAudio.get(candidate.audioPath);
    const intrinsic = analyzeTranscriptCandidate({
      id: candidate.id,
      recordingId: recording?.id ?? candidate.recordingId,
      source: "fresh_decode",
      variant: candidate.variant,
      text: candidate.text,
      pass: "fresh-decode-comparison",
    }).findings;
    const comparison = recording
      ? compareTranscriptPair({
          pass: "fresh-decode-comparison",
          candidateId: candidate.id,
          recordingId: recording.id,
          source: "fresh_decode",
          variant: candidate.variant,
          referenceText: recording.transcript,
          candidateText: candidate.text,
        })
      : [];
    return [...comparison, ...intrinsic];
  });

  const cleanupFindings = input.cleanupPairs.flatMap((pair) => {
    const rawVsCleaned = compareTranscriptPair({
      pass: "cleanup-shadow",
      candidateId: pair.id,
      source: "cleanup",
      referenceText: pair.rawText,
      candidateText: pair.cleanedText,
    }).filter(
      (finding) =>
        finding.category !== "missing_head_tail" &&
        finding.category !== "semantic_substitutions",
    );
    return [
      ...rawVsCleaned,
      ...analyzeTranscriptCandidate({
        id: pair.id,
        source: "cleanup",
        text: pair.rawText,
        pass: "cleanup-shadow",
      }).findings.filter(
        (finding) => finding.category === "filler_disfluency_handling",
      ),
      ...analyzeTranscriptCandidate({
        id: pair.id,
        source: "cleanup",
        text: pair.cleanedText,
        pass: "cleanup-shadow",
      }).findings,
    ];
  });

  const polishFindings = input.polishPairs.flatMap((pair) => [
    ...compareTranscriptPair({
      pass: "polish-shadow",
      candidateId: pair.id,
      source: "polish",
      referenceText: pair.cleanedText,
      candidateText: pair.polishedText,
    }),
    ...analyzeTranscriptCandidate({
      id: pair.id,
      source: "polish",
      text: pair.cleanedText,
      pass: "polish-shadow",
    }).findings,
    ...analyzeTranscriptCandidate({
      id: pair.id,
      source: "polish",
      text: pair.polishedText,
      pass: "polish-shadow",
    }).findings,
  ]);
  const correctionFindings = correctionPairs.flatMap(compareCorrectionPair);

  const passes = [
    makePass(
      "archive-intrinsic",
      "Scans archived VoiceBar transcripts for deterministic failure signatures.",
      archiveFindings,
    ),
    makePass(
      "fresh-decode-comparison",
      "Compares archived transcripts against fresh decode candidates from benchmark JSON.",
      freshFindings,
    ),
    makePass(
      "cleanup-shadow",
      "Compares raw/cleaned local cleanup pairs and residual cleanup artifacts.",
      cleanupFindings,
    ),
    makePass(
      "polish-shadow",
      "Compares deterministic cleanup against local polish shadow candidates.",
      polishFindings,
    ),
    makePass(
      "user-correction-comparison",
      "Compares user-provided observed/expected transcript corrections.",
      correctionFindings,
    ),
  ];

  const allFindings = passes.flatMap((pass) => pass.findings);
  const findingsByCategory = initCategoryCounts();
  const patternCounts = new Map<
    string,
    {
      category: STTQualityFindingCategory;
      pattern: string;
      count: number;
      severity: "low" | "medium" | "high";
    }
  >();

  for (const finding of allFindings) {
    findingsByCategory[finding.category]++;
    const key = `${finding.category}\0${finding.pattern.toLowerCase()}`;
    const existing = patternCounts.get(key);
    if (existing) {
      existing.count++;
      if (finding.severity === "high") existing.severity = "high";
      else if (finding.severity === "medium" && existing.severity === "low") {
        existing.severity = "medium";
      }
    } else {
      patternCounts.set(key, {
        category: finding.category,
        pattern: finding.pattern,
        count: 1,
        severity: finding.severity,
      });
    }
  }

  return {
    createdAt: input.createdAt ?? new Date().toISOString(),
    recommendation:
      "Keep this repo-local as scripts/docs first, then extract a general `$stt-quality-mining` skill once the report schema and taxonomy stabilize across two or three weekly runs.",
    summary: {
      recordings: input.recordings.length,
      freshDecodes: input.freshDecodes.length,
      cleanupPairs: input.cleanupPairs.length,
      polishPairs: input.polishPairs.length,
      correctionPairs: correctionPairs.length,
      findings: allFindings.length,
      findingsByCategory,
    },
    passes,
    recurringPatterns: [...patternCounts.values()]
      .sort((a, b) => b.count - a.count || a.pattern.localeCompare(b.pattern))
      .slice(0, 50),
  };
}

export function loadFreshDecodesFromBenchmarkReports(
  paths: string[],
): STTFreshDecodeCandidate[] {
  const candidates: STTFreshDecodeCandidate[] = [];
  for (const path of paths) {
    const parsed = readJson(path) as unknown as DecodeBenchmarkReport | null;
    if (!parsed?.results || !Array.isArray(parsed.results)) continue;
    for (const [index, result] of parsed.results.entries()) {
      const row = result as Partial<DecodeBenchmarkReport["results"][number]>;
      if (
        !result ||
        typeof result !== "object" ||
        row.error ||
        typeof row.text !== "string" ||
        !row.text.trim()
      ) {
        continue;
      }
      candidates.push({
        id: `${basename(path)}:${index}`,
        source: "fresh_decode",
        variant: row.planId ?? "unknown",
        audioPath: row.audio ?? "",
        text: row.text,
        latencyMs: row.latencyMs,
      });
    }
  }
  return candidates;
}

export function loadPolishPairsFromJsonl(
  path: string,
  options: { since?: Date; until?: Date } = {},
): STTPolishPair[] {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split(/\r?\n/)
    .flatMap((line, index): STTPolishPair[] => {
      if (!line.trim()) return [];
      try {
        const row = JSON.parse(line) as Record<string, unknown>;
        const cleanedText = stringValue(row.cleaned_text);
        const polishedText = stringValue(row.polished_text);
        if (!cleanedText || !polishedText) return [];
        const createdAt = stringValue(row.created_at);
        if (options.since && options.until) {
          if (!createdAt || !dateInWindow(createdAt, options.since, options.until)) {
            return [];
          }
        }
        return [
          {
            id: `${basename(path)}:${index + 1}`,
            createdAt: createdAt ?? undefined,
            cleanedText,
            polishedText,
            status: stringValue(row.status) ?? undefined,
            error: stringValue(row.error) ?? undefined,
          },
        ];
      } catch {
        return [];
      }
    });
}

export function loadCorrectionPairsFromJsonl(path: string): STTCorrectionPair[] {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split(/\r?\n/)
    .flatMap((line, index): STTCorrectionPair[] => {
      if (!line.trim()) return [];
      try {
        const row = JSON.parse(line) as Record<string, unknown>;
        const observedText =
          stringValue(row.observed_text) ??
          stringValue(row.observedText) ??
          stringValue(row.observed);
        const expectedText =
          stringValue(row.expected_text) ??
          stringValue(row.expectedText) ??
          stringValue(row.expected);
        if (!observedText || !expectedText) return [];
        return [
          {
            id: stringValue(row.id) ?? `${basename(path)}:${index + 1}`,
            observedText,
            expectedText,
            note: stringValue(row.note) ?? undefined,
          },
        ];
      } catch {
        return [];
      }
    });
}

export function buildCleanupPairsFromRecordings(
  recordings: VoiceBarRecordingForMining[],
): STTCleanupPair[] {
  return recordings.flatMap((recording): STTCleanupPair[] => {
    const cleanedText = cleanupTranscriptionText(recording.transcript);
    if (cleanedText === recording.transcript) return [];
    return [
      {
        id: recording.id,
        rawText: recording.transcript,
        cleanedText,
      },
    ];
  });
}

function formatCategoryLabel(category: STTQualityFindingCategory): string {
  return category.replace(/_/g, " ");
}

export function formatSTTQualityMiningMarkdown(
  report: STTQualityMiningReport,
): string {
  const lines = [
    "# VoiceLayer STT Quality Mining Report",
    "",
    `Created: ${report.createdAt}`,
    "",
    "## Recommendation",
    "",
    report.recommendation,
    "",
    "## Summary",
    "",
    `- Recordings analyzed: ${report.summary.recordings}`,
    `- Fresh decode candidates: ${report.summary.freshDecodes}`,
    `- Cleanup pairs: ${report.summary.cleanupPairs}`,
    `- Polish pairs: ${report.summary.polishPairs}`,
    `- User correction pairs: ${report.summary.correctionPairs}`,
    `- Findings: ${report.summary.findings}`,
    "",
    "## Findings By Category",
    "",
    "| Category | Count |",
    "| --- | ---: |",
  ];

  for (const category of CATEGORY_ORDER) {
    lines.push(
      `| ${formatCategoryLabel(category)} | ${report.summary.findingsByCategory[category]} |`,
    );
  }

  lines.push("", "## Recurring Patterns", "");
  if (report.recurringPatterns.length === 0) {
    lines.push("No recurring deterministic patterns found.");
  } else {
    lines.push("| Category | Pattern | Count | Severity |", "| --- | --- | ---: | --- |");
    for (const pattern of report.recurringPatterns) {
      lines.push(
        `| ${formatCategoryLabel(pattern.category)} | \`${pattern.pattern.replace(/\|/g, "\\|")}\` | ${pattern.count} | ${pattern.severity} |`,
      );
    }
  }

  lines.push("", "## Passes", "");
  for (const pass of report.passes) {
    lines.push(`### ${pass.name}`, "", pass.description, "");
    if (pass.findings.length === 0) {
      lines.push("No findings.", "");
      continue;
    }
    lines.push(
      "| Category | Pattern | Candidate | Source | Severity | Detail |",
      "| --- | --- | --- | --- | --- | --- |",
    );
    for (const finding of pass.findings.slice(0, 200)) {
      const source = finding.variant
        ? `${finding.source}:${finding.variant}`
        : finding.source;
      lines.push(
        `| ${formatCategoryLabel(finding.category)} | \`${finding.pattern.replace(/\|/g, "\\|")}\` | \`${finding.recordingId ?? finding.candidateId}\` | ${source} | ${finding.severity} | ${finding.detail.replace(/\|/g, "\\|")} |`,
      );
    }
    if (pass.findings.length > 200) {
      lines.push(
        `| ... | ... | ... | ... | ... | ${pass.findings.length - 200} additional findings omitted from markdown. See JSON. |`,
      );
    }
    lines.push("");
  }

  lines.push(
    "## Notes",
    "",
    "- This report intentionally avoids raw transcript blocks by default.",
    "- Semantic substitutions are candidate flags, not proof of transcript error; review them against local audio before creating rules.",
    "- Use the existing decode benchmark to create fresh decode JSON, then feed those JSON files into this miner.",
    "",
  );

  return `${lines.join("\n")}\n`;
}

export function writeSTTQualityMiningReport(
  report: STTQualityMiningReport,
  outputDir: string,
): { jsonPath: string; markdownPath: string } {
  mkdirSync(outputDir, { recursive: true, mode: 0o700 });
  const stamp = report.createdAt.replace(/[:.]/g, "-");
  const jsonPath = join(outputDir, `stt-quality-mining-${stamp}.json`);
  const markdownPath = join(outputDir, `stt-quality-mining-${stamp}.md`);
  writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`, {
    mode: 0o600,
  });
  writeFileSync(markdownPath, formatSTTQualityMiningMarkdown(report), {
    mode: 0o600,
  });
  return { jsonPath, markdownPath };
}

export function defaultPolishLogPath(): string {
  return join(homedir(), ".voicelayer", "eval", "polish-shadow.jsonl");
}
