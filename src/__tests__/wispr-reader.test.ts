/**
 * Tests for Wispr Flow SQLite reader — extracts transcriptions and audio
 * from Wispr Flow's flow.sqlite for A/B comparison with VoiceLayer.
 */
import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { Database } from "bun:sqlite";

const fixtureDir = mkdtempSync(join(TEST_TMP, "wispr-reader-"));
const WISPR_DB = join(fixtureDir, "flow.sqlite");

describe("wispr-reader", () => {
  beforeAll(() => {
    const db = new Database(WISPR_DB, { create: true });
    try {
      db.run(`CREATE TABLE History (
        transcriptEntityId TEXT, asrText TEXT, formattedText TEXT, editedText TEXT,
        timestamp TEXT, detectedLanguage TEXT, speechDuration REAL,
        formattingDivergenceScore REAL, averageLogProb REAL, audio BLOB, additionalContext TEXT
      )`);
      const audio = Buffer.alloc(44);
      audio.write("RIFF");
      audio.writeUInt32LE(16000, 24);
      db.run("INSERT INTO History VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
        "synthetic-1", "שלום fixture", "שלום fixture.", null, "2026-01-01", "he",
        1, 0, -0.1, audio, JSON.stringify({ dictionary_context: ["FixtureTerm"] }),
      ]);
    } finally {
      db.close();
    }
  });
  afterAll(() => rmSync(fixtureDir, { recursive: true, force: true }));

  it("opens Wispr Flow DB read-only without error", async () => {
    const { openWisprDb } = await import("../wispr-reader");
    const db = openWisprDb(WISPR_DB);
    expect(db).toBeDefined();
    db.close();
  });

  it("counts total entries", async () => {
    const { openWisprDb, countEntries } = await import("../wispr-reader");
    const db = openWisprDb(WISPR_DB);
    const count = countEntries(db);
    expect(count).toBeGreaterThan(0);
    db.close();
  });

  it("fetches recent transcriptions with required fields", async () => {
    const { openWisprDb, getRecentTranscriptions } =
      await import("../wispr-reader");
    const db = openWisprDb(WISPR_DB);
    const rows = getRecentTranscriptions(db, 5);

    expect(rows.length).toBeGreaterThan(0);
    expect(rows.length).toBeLessThanOrEqual(5);

    for (const row of rows) {
      expect(row.transcriptEntityId).toBeDefined();
      expect(row.asrText).toBeDefined();
      expect(row.timestamp).toBeDefined();
      // formattedText may be null for some entries
    }
    db.close();
  });

  it("returns only Hebrew entries when Hebrew text is present", async () => {
    const { openWisprDb, getHebrewEntries } = await import("../wispr-reader");
    const db = openWisprDb(WISPR_DB);
    const rows = getHebrewEntries(db, 10);

    expect(rows.length).toBeLessThanOrEqual(10);
    for (const row of rows) {
      // Should contain at least one Hebrew character (U+0590-U+05FF)
      const hasHebrew = /[\u0590-\u05FF]/.test(row.asrText);
      expect(hasHebrew).toBe(true);
    }
    db.close();
  });

  it("extracts audio blob as WAV buffer", async () => {
    const { openWisprDb, extractAudio } = await import("../wispr-reader");
    const db = openWisprDb(WISPR_DB);
    const audio = extractAudio(db);

    if (audio) {
      // Should be a RIFF WAV header
      const header = new TextDecoder("ascii").decode(audio.slice(0, 4));
      expect(header).toBe("RIFF");
      // 16kHz sample rate at byte offset 24
      const sampleRate =
        audio[24] | (audio[25] << 8) | (audio[26] << 16) | (audio[27] << 24);
      expect(sampleRate).toBe(16000);
    }
    db.close();
  });

  it("extracts user dictionary terms from additionalContext", async () => {
    const { openWisprDb, getUserDictionary } = await import("../wispr-reader");
    const db = openWisprDb(WISPR_DB);
    const dictionary = getUserDictionary(db);

    expect(Array.isArray(dictionary)).toBe(true);
    if (dictionary.length === 0) {
      db.close();
      return;
    }
    for (const term of dictionary) {
      expect(typeof term).toBe("string");
      expect(term.trim().length).toBeGreaterThan(0);
    }
    db.close();
  });

  it("gets comparison pair (asrText + formattedText + audio)", async () => {
    const { openWisprDb, getComparisonPairs } = await import("../wispr-reader");
    const db = openWisprDb(WISPR_DB);
    const pairs = getComparisonPairs(db, 3);

    expect(pairs.length).toBeGreaterThan(0);
    for (const pair of pairs) {
      expect(pair.id).toBeDefined();
      expect(pair.asrText).toBeDefined();
      expect(pair.formattedText).toBeDefined();
      expect(pair.hasAudio).toBeDefined();
      expect(pair.detectedLanguage).toBeDefined();
    }
    db.close();
  });
});
