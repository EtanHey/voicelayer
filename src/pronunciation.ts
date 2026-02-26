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
 * All replacements are case-insensitive and applied as whole-word matches.
 */

import { existsSync, readFileSync, statSync } from "fs";
import { join } from "path";

const PRONUNCIATION_FILE = join(
  process.env.HOME || "~",
  ".voicelayer",
  "pronunciation.yaml",
);

interface PronunciationEntry {
  pattern: RegExp;
  replacement: string;
}

let cachedEntries: PronunciationEntry[] | null = null;
let cachedMtime: number = 0;

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
  if (!existsSync(PRONUNCIATION_FILE)) {
    return [];
  }

  try {
    const stat = statSync(PRONUNCIATION_FILE);
    const mtime = stat.mtimeMs;

    if (cachedEntries && mtime === cachedMtime) {
      return cachedEntries;
    }

    const content = readFileSync(PRONUNCIATION_FILE, "utf-8");
    const dict = parseYaml(content);
    cachedEntries = buildEntries(dict);
    cachedMtime = mtime;

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
  const entries = loadEntries();
  if (entries.length === 0) return text;

  let result = text;
  for (const { pattern, replacement } of entries) {
    result = result.replace(pattern, replacement);
  }
  return result;
}
