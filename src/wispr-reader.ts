/**
 * Wispr Flow SQLite reader — extracts transcriptions and audio for A/B
 * comparison with VoiceLayer's whisper.cpp pipeline.
 *
 * Opens flow.sqlite read-only (WAL-safe). Wispr Flow can be running.
 *
 * Audio blobs are 16-bit PCM WAV, mono 16kHz — whisper.cpp's native format.
 */

import { Database } from "bun:sqlite";
import { existsSync } from "fs";

const DEFAULT_WISPR_DB_PATH = `${process.env.HOME}/Library/Application Support/Wispr Flow/flow.sqlite`;

export interface WisprDictionaryEntry {
  phrase: string;
  replacement: string | null;
}

export function getWisprDbPath(): string {
  return process.env.QA_VOICE_WISPR_DB_PATH || DEFAULT_WISPR_DB_PATH;
}

export interface WisprTranscription {
  transcriptEntityId: string;
  asrText: string;
  formattedText: string | null;
  editedText: string | null;
  timestamp: string;
  detectedLanguage: string | null;
  speechDuration: number | null;
  formattingDivergenceScore: number | null;
  averageLogProb: number | null;
}

export interface ComparisonPair {
  id: string;
  asrText: string;
  formattedText: string;
  editedText: string | null;
  timestamp: string;
  detectedLanguage: string | null;
  speechDuration: number | null;
  formattingDivergenceScore: number | null;
  hasAudio: boolean;
}

/** Open Wispr Flow's database read-only. Safe to use while Wispr is running (WAL). */
export function openWisprDb(path?: string): Database {
  const dbPath = path ?? getWisprDbPath();
  if (!existsSync(dbPath)) {
    throw new Error(`Wispr Flow database not found at ${dbPath}`);
  }
  return new Database(dbPath, { readonly: true });
}

/** Count total entries in History table. */
export function countEntries(db: Database): number {
  const row = db.query("SELECT COUNT(*) as count FROM History").get() as {
    count: number;
  };
  return row.count;
}

/** Fetch N most recent transcriptions. */
export function getRecentTranscriptions(
  db: Database,
  limit: number,
): WisprTranscription[] {
  return db
    .query(
      `SELECT transcriptEntityId, asrText, formattedText, editedText,
              timestamp, detectedLanguage, speechDuration,
              formattingDivergenceScore, averageLogProb
       FROM History
       ORDER BY timestamp DESC
       LIMIT ?`,
    )
    .all(limit) as WisprTranscription[];
}

/** Find entries containing Hebrew characters (U+0590-U+05FF) in asrText. */
export function getHebrewEntries(
  db: Database,
  limit: number,
): WisprTranscription[] {
  // SQLite doesn't support Unicode regex, so we fetch more and filter in JS
  const candidates = db
    .query(
      `SELECT transcriptEntityId, asrText, formattedText, editedText,
              timestamp, detectedLanguage, speechDuration,
              formattingDivergenceScore, averageLogProb
       FROM History
       WHERE asrText IS NOT NULL
       ORDER BY timestamp DESC
       LIMIT 500`,
    )
    .all() as WisprTranscription[];

  const hebrewPattern = /[\u0590-\u05FF]/;
  return candidates
    .filter((r) => hebrewPattern.test(r.asrText))
    .slice(0, limit);
}

/** Extract most recent audio blob. Returns Uint8Array (WAV) or null. */
export function extractAudio(
  db: Database,
  entityId?: string,
): Uint8Array | null {
  const query = entityId
    ? db.query("SELECT audio FROM History WHERE transcriptEntityId = ?")
    : db.query(
        "SELECT audio FROM History WHERE audio IS NOT NULL ORDER BY timestamp DESC LIMIT 1",
      );

  const row = (entityId ? query.get(entityId) : query.get()) as {
    audio: Uint8Array | null;
  } | null;

  return row?.audio ?? null;
}

/** Extract user dictionary terms from additionalContext JSON. */
export function getUserDictionary(db: Database): string[] {
  const rows = db
    .query(
      `SELECT DISTINCT additionalContext
       FROM History
       WHERE additionalContext IS NOT NULL
         AND additionalContext != 'null'
         AND additionalContext != ''
       ORDER BY timestamp DESC
       LIMIT 10`,
    )
    .all() as { additionalContext: string }[];

  const terms = new Set<string>();
  for (const row of rows) {
    try {
      const ctx = JSON.parse(row.additionalContext);
      const dict = ctx.dictionary_context;
      if (Array.isArray(dict)) {
        for (const term of dict) {
          if (typeof term === "string" && term.trim()) {
            terms.add(term.trim());
          }
        }
      }
    } catch {
      // Skip malformed JSON
    }
  }

  return [...terms].sort();
}

/** Extract active Wispr dictionary phrase/replacement rows. */
export function getWisprDictionaryEntries(db: Database): WisprDictionaryEntry[] {
  return db
    .query(
      `SELECT phrase, replacement
       FROM Dictionary
       WHERE isDeleted = 0
         AND isSnippet = 0
         AND phrase IS NOT NULL
         AND phrase != ''
       ORDER BY frequencyUsed DESC, createdAt DESC`,
    )
    .all() as WisprDictionaryEntry[];
}

/** Get comparison pairs — entries with both asrText and formattedText + audio info. */
export function getComparisonPairs(
  db: Database,
  limit: number,
): ComparisonPair[] {
  return db
    .query(
      `SELECT
         transcriptEntityId as id,
         asrText,
         formattedText,
         editedText,
         timestamp,
         detectedLanguage,
         speechDuration,
         formattingDivergenceScore,
         CASE WHEN audio IS NOT NULL THEN 1 ELSE 0 END as hasAudio
       FROM History
       WHERE asrText IS NOT NULL
         AND formattedText IS NOT NULL
         AND asrText != ''
         AND formattedText != ''
       ORDER BY timestamp DESC
       LIMIT ?`,
    )
    .all(limit)
    .map((row: any) => ({
      ...row,
      hasAudio: row.hasAudio === 1,
    })) as ComparisonPair[];
}
