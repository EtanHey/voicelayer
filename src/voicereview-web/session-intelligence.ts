import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";

export const DEFAULT_JUDGE_VERDICTS_PATH = "/tmp/kg-judge-verdicts/worker*.json";
export const DEFAULT_JUDGE_REPORTS_PATH = "/tmp/kg-judge-collect-smoke*";

export interface JudgeVerdict {
  stem: string;
  proposed_type: string;
  identity: string;
  merge_disposition: string;
  canonical_suggestion: string;
  confidence: string | number;
  evidence_cited: string[];
  reasoning: string;
  [key: string]: unknown;
}

export interface JudgeReport {
  path: string;
  content: string;
}

export interface RuleCluster {
  cluster_id: string;
  category: string;
  stem: string;
  members?: Array<{ name: string; type: string }>;
}

export interface SessionRule {
  kind: "rule";
  statement: string;
  examples: string[];
  vocabulary_correction?: {
    misheard: string;
    intended: string;
  };
}

export interface SessionRuleLogContext {
  endpoint: "interpret" | "converse";
  cluster: RuleCluster;
  sourceText: string;
  recordedAt?: string;
}

export async function loadJudgeVerdicts(
  configuredPaths = DEFAULT_JUDGE_VERDICTS_PATH,
): Promise<JudgeVerdict[]> {
  const files = await expandConfiguredPaths(configuredPaths);
  const verdicts: JudgeVerdict[] = [];
  for (const file of files) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(await readFile(file, "utf8"));
    } catch {
      continue;
    }
    const items = Array.isArray(parsed) ? parsed : [parsed];
    for (const item of items) {
      if (isJudgeVerdict(item)) verdicts.push(item);
    }
  }
  return verdicts;
}

export async function loadJudgeReports(
  configuredPaths = DEFAULT_JUDGE_REPORTS_PATH,
): Promise<JudgeReport[]> {
  const files = await expandConfiguredPaths(configuredPaths);
  const reports: JudgeReport[] = [];
  for (const file of files) {
    try {
      reports.push({ path: file, content: await readFile(file, "utf8") });
    } catch {
      continue;
    }
  }
  return reports;
}

export function findJudgeVerdict(
  verdicts: JudgeVerdict[],
  cluster: RuleCluster,
): JudgeVerdict | null {
  const stem = normalizeStem(cluster.stem);
  const clusterIdStem = normalizeStem(cluster.cluster_id.split(":").pop() || "");
  return (
    verdicts.find((verdict) => {
      const verdictStem = normalizeStem(verdict.stem);
      return verdictStem === stem || verdictStem === clusterIdStem;
    }) || null
  );
}

export function buildJudgeReflectBack(verdict: JudgeVerdict): string {
  const identity = condenseIdentity(verdict.identity);
  const disposition = normalizeSpokenValue(verdict.merge_disposition);
  const confidence = normalizeSpokenValue(String(verdict.confidence));
  return `The judge concluded: ${identity}; disposition ${disposition} with ${confidence} confidence - confirm, or correct me.`;
}

export function extractSessionRule(
  text: string,
  _cluster?: RuleCluster,
): SessionRule | null {
  const clean = text.replace(/\s+/g, " ").trim();
  if (!clean) return null;

  const vocabularyCorrection = extractVocabularyCorrection(clean);
  if (vocabularyCorrection) return vocabularyCorrection;

  const firstClause = clean
    .split(/\s*,\s*(?:so|then|and)\b/i)[0]
    .replace(/[.?!]+$/g, "")
    .trim();

  const endingMatch = firstClause.match(
    /^(anything|everything)\s+ending\s+in\s+([^\s,.;]+)\s+(is|are|means|should be|should always be)\s+(.+)$/i,
  );
  if (endingMatch) {
    return {
      kind: "rule",
      statement: ensureSentence(firstClause),
      examples: [endingMatch[2]],
    };
  }

  const alwaysMatch = firstClause.match(/^(.{2,80}?)\s+(is|are)\s+always\s+(.+)$/i);
  if (alwaysMatch) {
    return {
      kind: "rule",
      statement: ensureSentence(firstClause),
      examples: [alwaysMatch[1].trim()],
    };
  }

  return null;
}

export async function appendSessionRule(
  rule: SessionRule,
  logPath: string,
  context: SessionRuleLogContext,
): Promise<void> {
  await mkdir(dirname(logPath), { recursive: true });
  const record: Record<string, unknown> = {
    ...rule,
    recorded_at: context.recordedAt || new Date().toISOString(),
    source_endpoint: context.endpoint,
    source_text: context.sourceText,
    cluster_id: context.cluster.cluster_id,
    stem: context.cluster.stem,
    category: context.cluster.category,
  };
  if (rule.vocabulary_correction) {
    record.vocabulary_status = "d1_vocab_store_unavailable";
  }
  await writeFile(logPath, `${JSON.stringify(record)}\n`, { flag: "a" });
}

async function expandConfiguredPaths(configuredPaths: string): Promise<string[]> {
  const patterns = configuredPaths
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  const files: string[] = [];
  for (const pattern of patterns) {
    files.push(...(await expandOnePath(pattern)));
  }
  return [...new Set(files)].sort();
}

async function expandOnePath(pattern: string): Promise<string[]> {
  if (!pattern.includes("*")) return [pattern];
  const dir = dirname(pattern);
  const filePattern = basename(pattern);
  const matcher = wildcardMatcher(filePattern);
  let entries: string[];
  try {
    entries = await readdir(dir);
  } catch {
    return [];
  }
  return entries.filter((entry) => matcher.test(entry)).map((entry) => join(dir, entry));
}

function wildcardMatcher(pattern: string): RegExp {
  const escaped = pattern
    .split("*")
    .map((part) => part.replace(/[|\\{}()[\]^$+?.]/g, "\\$&"))
    .join(".*");
  return new RegExp(`^${escaped}$`);
}

function isJudgeVerdict(value: unknown): value is JudgeVerdict {
  return (
    isRecord(value) &&
    typeof value.stem === "string" &&
    typeof value.proposed_type === "string" &&
    typeof value.identity === "string" &&
    typeof value.merge_disposition === "string" &&
    typeof value.canonical_suggestion === "string" &&
    (typeof value.confidence === "string" || typeof value.confidence === "number") &&
    Array.isArray(value.evidence_cited) &&
    typeof value.reasoning === "string"
  );
}

function extractVocabularyCorrection(text: string): SessionRule | null {
  const direct = text.match(/^not\s+([^,.;!?]+)\s*,\s*([^,.;!?]+)[.;!?]?$/i);
  if (direct) {
    return vocabularyRule(direct[1], direct[2]);
  }

  const means = text.match(/^([^,.;!?]{2,80}?)\s+(?:means|should be|is actually)\s+([^,.;!?]+)[.;!?]?$/i);
  if (!means) return null;
  const left = means[1].trim();
  if (!/\b(misheard|heard|transcribed|spelled|pronounced|caneloop)\b/i.test(left)) {
    return null;
  }
  return vocabularyRule(left.replace(/^.*\b(?:as|like)\s+/i, ""), means[2]);
}

function vocabularyRule(misheard: string, intended: string): SessionRule {
  const cleanMisheard = cleanTerm(misheard);
  const cleanIntended = cleanTerm(intended);
  return {
    kind: "rule",
    statement: `Vocabulary correction: ${cleanMisheard} means ${cleanIntended}.`,
    examples: [cleanMisheard, cleanIntended],
    vocabulary_correction: {
      misheard: cleanMisheard,
      intended: cleanIntended,
    },
  };
}

function cleanTerm(value: string): string {
  return value.replace(/^["']|["']$/g, "").replace(/\s+/g, " ").trim();
}

function condenseIdentity(identity: string): string {
  const normalized = identity
    .replace(/[—–]/g, "-")
    .replace(/\s+/g, " ")
    .replace(/[.。]+$/g, "")
    .trim();
  if (normalized.length <= 180) return normalized;
  return `${normalized.slice(0, 177).trim()}...`;
}

function normalizeSpokenValue(value: string): string {
  return value.replace(/[—–]/g, "-").replace(/\s+/g, " ").trim().toLowerCase();
}

function normalizeStem(value: string): string {
  return value.replace(/\s+/g, " ").trim().toLowerCase();
}

function ensureSentence(value: string): string {
  const trimmed = value.trim();
  return /[.?!]$/.test(trimmed) ? trimmed : `${trimmed}.`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
