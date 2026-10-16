import { describe, expect, it } from "bun:test";
import { homedir } from "os";
import { join } from "path";

const preload = join(import.meta.dir, "setup", "preload.ts");
const journal = join(import.meta.dir, "..", "control-layer-journal.ts");

function probe(override?: string) {
  const env = { ...process.env };
  delete env.VOICELAYER_CONTROL_LAYER_BASE;
  delete env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL;
  delete env.VOICELAYER_TEST_KEEP_TMP;
  if (override !== undefined) env.VOICELAYER_CONTROL_LAYER_BASE = override;
  // RED is read-only: do not import/call the journal writer until the preload
  // has selected the exact private per-run base. Never probe the live DB.
  const script = [
    'const { join } = await import("path");',
    'const expected = join(process.env.VOICELAYER_TEST_RUN_ROOT, "orc");',
    'const base = process.env.VOICELAYER_CONTROL_LAYER_BASE;',
    'let rows = null, marker = false;',
    'if (base === expected) {',
    `  const { appendControlLayerEvent } = await import(${JSON.stringify(journal)});`,
    '  appendControlLayerEvent("test.journal-isolation", { synthetic: true }, { topic: "voice.test-isolation" });',
    '  const { Database } = await import("bun:sqlite");',
    '  const db = new Database(join(base, "fleet-journal.db"), { readonly: true });',
    '  rows = db.query("SELECT count(*) AS n FROM events WHERE type = ?").get("test.journal-isolation").n;',
    '  db.close();',
    '  marker = await Bun.file(join(base, "markers", "voice_test-isolation")).exists();',
    '}',
    'console.log(JSON.stringify({ pid: process.pid, root: process.env.VOICELAYER_TEST_RUN_ROOT, base: base ?? null, expected, rows, marker }));',
  ].join("\n");
  const result = Bun.spawnSync([process.execPath, "--preload", preload, "-e", script], {
    env, cwd: process.cwd(), stdout: "pipe", stderr: "pipe",
  });
  expect(result.exitCode).toBe(0);
  return JSON.parse(new TextDecoder().decode(result.stdout).trim().split("\n").at(-1)!);
}

describe("preload isolates the control-layer journal", () => {
  it("defaults the journal DB and markers to the private per-run test root", () => {
    const result = probe();
    expect(result.root).toMatch(new RegExp(`/\\.test-tmp/${result.pid}-[a-f0-9]{4,6}$`));
    expect(result.base).toBe(join(result.root, "orc"));
    expect(result.base).not.toStartWith(join(homedir(), ".local", "share", "orc"));
    expect(result.rows).toBe(1);
    expect(result.marker).toBe(true);
  });

  it("preserves an explicit caller-provided journal base", () => {
    const override = join(process.cwd(), ".test-tmp", "orc-manual");
    expect(probe(override).base).toBe(override);
  });
});
