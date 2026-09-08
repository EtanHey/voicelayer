export interface PolishEvalInput {
  id: string;
  input: string;
  target: string;
  output: string;
  tags: string[];
}

export interface PolishScore {
  id: string;
  tags: string[];
  inputSimilarity: number;
  targetSimilarity: number;
  selfCorrectionPass: boolean | null;
  listFormatPass: boolean | null;
  disfluencyCleanupPass: boolean | null;
  noMeaningLossPass: boolean;
  hallucinatedTokens: string[];
  overallPass: boolean;
}

export interface PolishEvalSummary {
  total: number;
  selfCorrectionCases: number;
  listCases: number;
  disfluencyCases: number;
  selfCorrectionRate: number | null;
  listFormatRate: number | null;
  disfluencyCleanupRate: number | null;
  noMeaningLossRate: number;
  averageTargetSimilarity: number;
  overallPassRate: number;
}

interface EvalExample {
  id: string;
  input: string;
  target: string;
  tags: string[];
}

interface PredictionRow extends EvalExample {
  output: string;
}

const STOPWORDS = new Set([
  "a",
  "an",
  "and",
  "are",
  "as",
  "at",
  "be",
  "but",
  "by",
  "for",
  "from",
  "how",
  "i",
  "in",
  "is",
  "it",
  "of",
  "on",
  "or",
  "so",
  "that",
  "the",
  "this",
  "to",
  "was",
  "what",
  "with",
  "you",
]);

const DISFLUENCIES = new Set([
  "um",
  "uh",
  "yeah",
  "okay",
  "like",
  "actually",
  "rather",
]);

function normalizeForSimilarity(text: string): string {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "");
}

function levenshteinDistance(left: string, right: string): number {
  if (left === right) return 0;
  if (!left) return right.length;
  if (!right) return left.length;
  const previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  const current = new Array<number>(right.length + 1);
  for (let i = 1; i <= left.length; i++) {
    current[0] = i;
    for (let j = 1; j <= right.length; j++) {
      const substitutionCost = left[i - 1] === right[j - 1] ? 0 : 1;
      current[j] = Math.min(
        previous[j] + 1,
        current[j - 1] + 1,
        previous[j - 1] + substitutionCost,
      );
    }
    for (let j = 0; j <= right.length; j++) previous[j] = current[j];
  }
  return previous[right.length];
}

export function normalizedSimilarity(left: string, right: string): number {
  const a = normalizeForSimilarity(left);
  const b = normalizeForSimilarity(right);
  if (!a && !b) return 1;
  const maxLength = Math.max(a.length, b.length);
  return 1 - levenshteinDistance(a, b) / maxLength;
}

function words(text: string): string[] {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .match(/[\p{L}\p{N}][\p{L}\p{N}'-]*/gu) ?? [];
}

function contentWords(text: string): Set<string> {
  return new Set(
    words(text).filter(
      (word) => word.length >= 3 && !STOPWORDS.has(word) && !DISFLUENCIES.has(word),
    ),
  );
}

function protectedTokens(text: string): Set<string> {
  const tokens = new Set<string>();
  const comparableText = text.replace(/^\s*\d+\.\s+/gm, "");
  const patterns = [
    /(?:^|\s)([./@][\w.-]+)/g,
    /\b[A-Z][A-Za-z0-9]*(?:[A-Z][A-Za-z0-9]*)+\b/g,
    /\b\w+[._-]\w+\b/g,
    /\b\d+(?:[.,:/-]\d+)*\b/g,
    /\b(?:no|not|never|without|cannot|can't|dont|don't|doesnt|doesn't)\b/gi,
  ];
  for (const pattern of patterns) {
    for (const match of comparableText.matchAll(pattern)) {
      tokens.add((match[1] ?? match[0]).trim().toLowerCase());
    }
  }
  return tokens;
}

function numberedItemCount(text: string): number {
  return (text.match(/^\s*\d+\.\s+\S/gm) ?? []).length;
}

function disfluencyCount(text: string): number {
  return words(text).filter((word) => DISFLUENCIES.has(word)).length;
}

function setDifference(left: Set<string>, right: Set<string>): string[] {
  return [...left].filter((value) => !right.has(value)).sort();
}

function noMeaningLoss(input: string, target: string, output: string): {
  pass: boolean;
  hallucinatedTokens: string[];
} {
  const targetProtected = protectedTokens(target);
  const outputProtected = protectedTokens(output);
  const missingProtected = setDifference(targetProtected, outputProtected);
  const inputAndTargetWords = new Set([...contentWords(input), ...contentWords(target)]);
  const hallucinatedTokens = setDifference(contentWords(output), inputAndTargetWords);
  const missingTargetContent = setDifference(contentWords(target), contentWords(output));
  return {
    pass:
      missingProtected.length === 0 &&
      hallucinatedTokens.length === 0 &&
      missingTargetContent.length === 0,
    hallucinatedTokens,
  };
}

export function scorePolishOutput(input: PolishEvalInput): PolishScore {
  const targetSimilarity = normalizedSimilarity(input.output, input.target);
  const inputSimilarity = normalizedSimilarity(input.input, input.target);
  const meaning = noMeaningLoss(input.input, input.target, input.output);

  const isSelfCorrection = input.tags.includes("self-correction");
  const isList = numberedItemCount(input.target) > 0;
  const isDisfluency = input.tags.includes("disfluency");

  const selfCorrectionPass = isSelfCorrection
    ? targetSimilarity >= 0.82 &&
      !/\b(well,?\s+no|no,?\s+wait|scratch that)\b/i.test(input.output)
    : null;
  const targetItems = numberedItemCount(input.target);
  const listFormatPass = isList
    ? targetItems > 0 && numberedItemCount(input.output) >= targetItems
    : null;
  const disfluencyCleanupPass = isDisfluency
    ? disfluencyCount(input.output) <= disfluencyCount(input.input) &&
      targetSimilarity >= inputSimilarity
    : null;

  const behaviorPasses = [
    selfCorrectionPass,
    listFormatPass,
    disfluencyCleanupPass,
  ].filter((value): value is boolean => value !== null);
  const behaviorPass =
    behaviorPasses.length === 0
      ? targetSimilarity >= inputSimilarity
      : behaviorPasses.every(Boolean);

  return {
    id: input.id,
    tags: input.tags,
    inputSimilarity,
    targetSimilarity,
    selfCorrectionPass,
    listFormatPass,
    disfluencyCleanupPass,
    noMeaningLossPass: meaning.pass,
    hallucinatedTokens: meaning.hallucinatedTokens,
    overallPass: behaviorPass && meaning.pass,
  };
}

function rate(count: number, total: number): number | null {
  if (total === 0) return null;
  return count / total;
}

export function aggregatePolishScores(scores: PolishScore[]): PolishEvalSummary {
  const selfCorrection = scores.filter((score) => score.selfCorrectionPass !== null);
  const lists = scores.filter((score) => score.listFormatPass !== null);
  const disfluencies = scores.filter((score) => score.disfluencyCleanupPass !== null);
  return {
    total: scores.length,
    selfCorrectionCases: selfCorrection.length,
    listCases: lists.length,
    disfluencyCases: disfluencies.length,
    selfCorrectionRate: rate(
      selfCorrection.filter((score) => score.selfCorrectionPass).length,
      selfCorrection.length,
    ),
    listFormatRate: rate(
      lists.filter((score) => score.listFormatPass).length,
      lists.length,
    ),
    disfluencyCleanupRate: rate(
      disfluencies.filter((score) => score.disfluencyCleanupPass).length,
      disfluencies.length,
    ),
    noMeaningLossRate: rate(
      scores.filter((score) => score.noMeaningLossPass).length,
      scores.length,
    ) ?? 0,
    averageTargetSimilarity:
      scores.reduce((sum, score) => sum + score.targetSimilarity, 0) /
      Math.max(1, scores.length),
    overallPassRate:
      (rate(scores.filter((score) => score.overallPass).length, scores.length) ?? 0),
  };
}

function loadJsonl(path: string): any[] {
  return readFileSync(path, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

export function loadEvalExamples(path: string): EvalExample[] {
  return loadJsonl(path).map((row, index) => ({
    id: String(row.id ?? `row-${index}`),
    input: String(row.messages?.[1]?.content ?? row.input ?? ""),
    target: String(row.messages?.[2]?.content ?? row.target ?? ""),
    tags: Array.isArray(row.metadata?.tags) ? row.metadata.tags : row.tags ?? [],
  }));
}

function writeJsonl(path: string, rows: unknown[]): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${rows.map((row) => JSON.stringify(row)).join("\n")}\n`);
}

function writeJson(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function flushEvalProgress(input: {
  rows: PredictionRow[];
  predictionsPath: string;
  metricsPath: string;
}): void {
  writeJsonl(input.predictionsPath, input.rows);
  writeJson(input.metricsPath, scorePredictionRows(input.rows));
}

export function scorePredictionRows(rows: PredictionRow[]): {
  scores: PolishScore[];
  summary: PolishEvalSummary;
} {
  const scores = rows.map(scorePolishOutput);
  return { scores, summary: aggregatePolishScores(scores) };
}

async function runPromptBaseline(input: {
  examplesPath: string;
  predictionsPath: string;
  metricsPath: string;
  limit?: number;
}): Promise<void> {
  const examples = loadEvalExamples(input.examplesPath).slice(0, input.limit);
  const rows: PredictionRow[] = [];
  for (const [index, example] of examples.entries()) {
    const output = await finalizeTranscriptionTextForSurface(example.input, "dictation", {
      ...process.env,
      QA_VOICE_STT_POLISH: "on",
      QA_VOICE_STT_POLISH_LOG_PATH: input.predictionsPath.replace(/\.jsonl$/, ".shadow.jsonl"),
    });
    rows.push({ ...example, output });
    if ((index + 1) % 25 === 0) {
      flushEvalProgress({
        rows,
        predictionsPath: input.predictionsPath,
        metricsPath: input.metricsPath,
      });
      console.error(`baseline ${index + 1}/${examples.length}`);
    }
  }
  flushEvalProgress({
    rows,
    predictionsPath: input.predictionsPath,
    metricsPath: input.metricsPath,
  });
}

async function requestEndpoint(input: {
  endpoint: string;
  model: string;
  system: string;
  user: string;
}): Promise<string> {
  const response = await fetch(input.endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model: input.model,
      messages: [
        { role: "system", content: input.system },
        { role: "user", content: input.user },
      ],
      temperature: 0,
      max_tokens: 512,
    }),
  });
  if (!response.ok) {
    throw new Error(`endpoint failed: ${response.status} ${response.statusText}`);
  }
  const payload: any = await response.json();
  const message = payload.choices?.[0]?.message;
  const content = typeof message === "string" ? message : message?.content;
  if (typeof content !== "string") throw new Error("endpoint response missing content");
  return content.trim();
}

async function runEndpointEval(input: {
  examplesPath: string;
  predictionsPath: string;
  metricsPath: string;
  endpoint: string;
  model: string;
  limit?: number;
}): Promise<void> {
  const examples = loadJsonl(input.examplesPath).slice(0, input.limit);
  const rows: PredictionRow[] = [];
  for (const [index, row] of examples.entries()) {
    const system = String(row.messages?.[0]?.content ?? "");
    const example = {
      id: String(row.id ?? `row-${index}`),
      input: String(row.messages?.[1]?.content ?? ""),
      target: String(row.messages?.[2]?.content ?? ""),
      tags: Array.isArray(row.metadata?.tags) ? row.metadata.tags : [],
    };
    const output = await requestEndpoint({
      endpoint: input.endpoint,
      model: input.model,
      system,
      user: example.input,
    });
    rows.push({ ...example, output });
    if ((index + 1) % 25 === 0) {
      flushEvalProgress({
        rows,
        predictionsPath: input.predictionsPath,
        metricsPath: input.metricsPath,
      });
      console.error(`endpoint ${index + 1}/${examples.length}`);
    }
  }
  flushEvalProgress({
    rows,
    predictionsPath: input.predictionsPath,
    metricsPath: input.metricsPath,
  });
}

function scorePredictions(input: {
  predictionsPath: string;
  metricsPath: string;
}): void {
  const rows = loadJsonl(input.predictionsPath) as PredictionRow[];
  writeJson(input.metricsPath, scorePredictionRows(rows));
}

function parseArg(name: string): string | undefined {
  const prefix = `--${name}=`;
  return process.argv.find((arg) => arg.startsWith(prefix))?.slice(prefix.length);
}

if (import.meta.main) {
  const mode = parseArg("mode") ?? "score";
  const metricsPath = resolve(parseArg("metrics") ?? "polish-eval-metrics.json");
  if (mode === "baseline") {
    const examplesPath = parseArg("examples");
    const predictionsPath = parseArg("predictions");
    if (!examplesPath || !predictionsPath) {
      throw new Error("--examples and --predictions are required for --mode=baseline");
    }
    await runPromptBaseline({
      examplesPath: resolve(examplesPath),
      predictionsPath: resolve(predictionsPath),
      metricsPath,
      limit: parseArg("limit") ? Number(parseArg("limit")) : undefined,
    });
  } else if (mode === "endpoint") {
    const examplesPath = parseArg("examples");
    const predictionsPath = parseArg("predictions");
    if (!examplesPath || !predictionsPath) {
      throw new Error("--examples and --predictions are required for --mode=endpoint");
    }
    await runEndpointEval({
      examplesPath: resolve(examplesPath),
      predictionsPath: resolve(predictionsPath),
      metricsPath,
      endpoint:
        parseArg("endpoint") ?? "http://127.0.0.1:18081/v1/chat/completions",
      model: parseArg("model") ?? "mlx-community/Qwen3-4B-Instruct-2507-4bit",
      limit: parseArg("limit") ? Number(parseArg("limit")) : undefined,
    });
  } else {
    const predictionsPath = parseArg("predictions");
    if (!predictionsPath) throw new Error("--predictions is required");
    scorePredictions({ predictionsPath: resolve(predictionsPath), metricsPath });
  }
}
import { mkdirSync, readFileSync, writeFileSync } from "fs";
import { dirname, resolve } from "path";
import { finalizeTranscriptionTextForSurface } from "./input";
