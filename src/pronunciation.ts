/**
 * Pronunciation engine — text preprocessing for TTS.
 *
 * Applies pronunciation corrections before text reaches any TTS engine.
 * Loads a YAML dictionary from ~/.voicelayer/pronunciation.yaml (hot-reloadable).
 *
 * Categories:
 *   - tech: Framework/tool names (TypeScript → "Type Script")
 *   - hebrew: Hebrew names/words (Etan → "Eh tahn")
 *   - acronyms: Letter-by-letter (SQL → "S Q L", API → "A P I")
 *
 * Legacy YAML replacements are case-insensitive whole-word matches.
 * The private state-dir map uses case-sensitive Unicode whole-word matches.
 */

import { existsSync, readFileSync, statSync, mkdirSync, mkdtempSync, writeFileSync, renameSync, rmSync, rmdirSync } from "fs";
import { dirname, join } from "path";
import { getStateDir } from "./paths";

const PRONUNCIATION_OVERRIDE_ENV = "QA_VOICE_PRONUNCIATION_PATH";

export function pronunciationFilePath(
  env: NodeJS.ProcessEnv = process.env,
): string {
  return env[PRONUNCIATION_OVERRIDE_ENV]?.trim() || join(
    env.HOME || "~",
    ".voicelayer",
    "pronunciation.yaml",
  );
}

export interface PronunciationEntry {
  pattern: RegExp;
  replacement: string;
}

let cachedEntries: PronunciationEntry[] | null = null;
let cachedMtime: number = 0;
let cachedPath: string | null = null;

/**
 * Parse a simple YAML pronunciation dictionary.
 * Supports top-level categories with key: "value" pairs.
 * No full YAML parser needed — format is flat.
 */
function parseYaml(content: string): Record<string, string> {
  const result: Record<string, string> = {};
  let inCategory = false;

  for (const line of content.split("\n")) {
    const trimmed = line.trim();

    // Skip comments and empty lines
    if (!trimmed || trimmed.startsWith("#")) continue;

    // Category header (e.g., "tech:")
    if (/^[a-z_]+:\s*$/i.test(trimmed)) {
      inCategory = true;
      continue;
    }

    // Entry (e.g., '  TypeScript: "Type Script"')
    if (inCategory && trimmed.includes(":")) {
      const colonIdx = trimmed.indexOf(":");
      const key = trimmed.slice(0, colonIdx).trim();
      let value = trimmed.slice(colonIdx + 1).trim();

      // Strip quotes
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }

      if (key && value) {
        result[key] = value;
      }
    }
  }

  return result;
}

/**
 * Build regex entries from the dictionary.
 * Uses word boundaries for whole-word matching.
 */
function buildEntries(dict: Record<string, string>): PronunciationEntry[] {
  return Object.entries(dict).map(([term, replacement]) => ({
    // Word boundary match, case-insensitive
    pattern: new RegExp(`\\b${escapeRegex(term)}\\b`, "gi"),
    replacement,
  }));
}

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Load pronunciation dictionary with hot-reload support.
 * Re-reads file only when mtime changes.
 */
function loadEntries(): PronunciationEntry[] {
  const path = pronunciationFilePath();
  if (!existsSync(path)) {
    return [];
  }

  try {
    const stat = statSync(path);
    const mtime = stat.mtimeMs;

    if (cachedEntries && path === cachedPath && mtime === cachedMtime) {
      return cachedEntries;
    }

    const content = readFileSync(path, "utf-8");
    const dict = parseYaml(content);
    cachedEntries = buildEntries(dict);
    cachedMtime = mtime;
    cachedPath = path;

    return cachedEntries;
  } catch {
    return cachedEntries || [];
  }
}

/**
 * Apply pronunciation corrections to text before TTS.
 *
 * @param text - Raw text to preprocess
 * @returns Text with pronunciation corrections applied
 */
export function applyPronunciation(text: string): string {
  const entries = pronunciationRules();
  if (entries.length === 0) return text;

  let result = text;
  for (const { pattern, replacement } of entries) {
    result = result.replace(pattern, replacement);
  }
  return result;
}

/** Ordered snapshot for mapped speech preprocessing; shares the YAML hot-reload cache. */
export function pronunciationRules(): readonly PronunciationEntry[] {
  let personal: PronunciationEntry[] = [];
  try {
    personal = Object.entries(readPersonalPronunciations()).map(([term, replacement]) => ({
      pattern: new RegExp(`(?<![\\p{L}\\p{M}\\p{N}_])${escapeRegex(term)}(?![\\p{L}\\p{M}\\p{N}_])`, "gu"),
      // Rules use String.replace syntax. User entries are literal speech.
      replacement: replacement.split("$").join("$$"),
    }));
  } catch { /* A malformed/unreadable private file must not break narration. */ }
  return [...loadEntries(), ...personal];
}

/** Separate from the legacy YAML dictionary; never seeded or shipped. */
export function personalPronunciationPath(env: NodeJS.ProcessEnv = process.env): string {
  return join(getStateDir(env), "tts-pronunciations.json");
}

export function readPersonalPronunciations(env: NodeJS.ProcessEnv = process.env): Record<string, string> {
  let content: string;
  try { content = readFileSync(personalPronunciationPath(env), "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return {}; throw error; }
  if (!content.trim()) return {};
  const data: unknown = JSON.parse(content);
  if (!data || Array.isArray(data) || typeof data !== "object") throw new Error("Invalid pronunciation map");
  for (const [term, spoken] of Object.entries(data)) validatePersonalEntry(term, spoken);
  return data as Record<string, string>;
}

function validatePersonalEntry(term: string, spoken: unknown): void {
  if (!term.trim() || term !== term.trim() || term.length > 200 || /[\x00-\x1f\x7f]/.test(term)
      || typeof spoken !== "string" || !spoken.trim() || spoken.length > 500 || /[\x00-\x1f\x7f]/.test(spoken)) {
    throw new Error("Expected a nonempty term and spoken text without control characters");
  }
}

export function updatePersonalPronunciation(term: string, spoken: string | undefined, env: NodeJS.ProcessEnv = process.env): void {
  validatePersonalEntry(term, spoken ?? "remove");
  const path = personalPronunciationPath(env);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const lock = `${path}.lock`;
  try { mkdirSync(lock, { mode: 0o700 }); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new Error("Pronunciation list is busy; retry the edit");
    throw error;
  }
  try {
    const entries = new Map(Object.entries(readPersonalPronunciations(env)));
    if (spoken === undefined) entries.delete(term);
    else entries.set(term, spoken);
    const staging = mkdtempSync(`${path}.`);
    try {
      const tmp = join(staging, "map.json");
      writeFileSync(tmp, JSON.stringify(Object.fromEntries(entries), null, 2) + "\n", { mode: 0o600, flag: "wx" });
      renameSync(tmp, path);
    } finally { rmSync(staging, { recursive: true, force: true }); }
  } finally { rmdirSync(lock); } // Only the empty directory this writer created; never reap a stale lock.
}
