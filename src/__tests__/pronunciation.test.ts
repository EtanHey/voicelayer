import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, writeFileSync, unlinkSync, mkdirSync } from "fs";
import { join } from "path";

// Test with a temp pronunciation file
const TEST_DIR = "/tmp/voicelayer-pronunciation-test";
const TEST_FILE = join(TEST_DIR, "pronunciation.yaml");

// We need to override the file path for testing
// Import the module — it reads from ~/.voicelayer/pronunciation.yaml by default
// For testing, we'll set HOME to our test dir
const originalHome = process.env.HOME;

describe("pronunciation", () => {
  beforeEach(() => {
    mkdirSync(join(TEST_DIR, ".voicelayer"), { recursive: true });
    process.env.HOME = TEST_DIR;
  });

  afterEach(() => {
    process.env.HOME = originalHome;
    try {
      unlinkSync(join(TEST_DIR, ".voicelayer", "pronunciation.yaml"));
    } catch {}
  });

  it("returns text unchanged when no dictionary exists", async () => {
    // Fresh import to pick up new HOME
    const mod = await import("../pronunciation");
    expect(mod.applyPronunciation("Hello world")).toBe("Hello world");
  });

  it("applies tech term replacements", async () => {
    writeFileSync(
      join(TEST_DIR, ".voicelayer", "pronunciation.yaml"),
      `tech:
  TypeScript: "Type Script"
  Supabase: "Soopa base"
  SQLite: "S Q Lite"
`,
    );

    // Need to bust the module cache for hot-reload testing
    // Since we changed HOME, re-import
    delete require.cache[require.resolve("../pronunciation")];
    const mod = await import("../pronunciation");

    const result = mod.applyPronunciation(
      "TypeScript and Supabase are great with SQLite",
    );
    expect(result).toBe("Type Script and Soopa base are great with S Q Lite");
  });

  it("applies acronym replacements", async () => {
    writeFileSync(
      join(TEST_DIR, ".voicelayer", "pronunciation.yaml"),
      `acronyms:
  SQL: "S Q L"
  API: "A P I"
  CLI: "C L I"
`,
    );

    delete require.cache[require.resolve("../pronunciation")];
    const mod = await import("../pronunciation");

    expect(mod.applyPronunciation("Use the SQL API via CLI")).toBe(
      "Use the S Q L A P I via C L I",
    );
  });

  it("is case-insensitive", async () => {
    writeFileSync(
      join(TEST_DIR, ".voicelayer", "pronunciation.yaml"),
      `tech:
  Vite: "Veet"
`,
    );

    delete require.cache[require.resolve("../pronunciation")];
    const mod = await import("../pronunciation");

    expect(mod.applyPronunciation("vite is fast, VITE is great")).toBe(
      "Veet is fast, Veet is great",
    );
  });

  it("only replaces whole words", async () => {
    writeFileSync(
      join(TEST_DIR, ".voicelayer", "pronunciation.yaml"),
      `tech:
  SQL: "S Q L"
`,
    );

    delete require.cache[require.resolve("../pronunciation")];
    const mod = await import("../pronunciation");

    // "MySQL" should NOT have SQL replaced inside it
    expect(mod.applyPronunciation("MySQL uses SQL")).toBe("MySQL uses S Q L");
  });

  it("handles hebrew names", async () => {
    writeFileSync(
      join(TEST_DIR, ".voicelayer", "pronunciation.yaml"),
      `hebrew:
  Etan: "Eh tahn"
  Zikaron: "Zee kah rone"
`,
    );

    delete require.cache[require.resolve("../pronunciation")];
    const mod = await import("../pronunciation");

    expect(mod.applyPronunciation("Etan built Zikaron")).toBe(
      "Eh tahn built Zee kah rone",
    );
  });
});
