import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { Database } from "bun:sqlite";
import { chmodSync, linkSync, mkdirSync, mkdtempSync, renameSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { createSpeakReceipt, type SpeakArchiveContext } from "../speak-archive";
import { assertNoCanaryDiagnostics, diagnosticLeaks, streamLeaks } from "./setup/privacy-canary";

const token = "CANARY-TXT-synthetic-retained-speak";
let root: string, privateRoot: string, recordingsRoot: string, context: SpeakArchiveContext;
let savedRoot: string | undefined;
const scan = (configuredRoot = recordingsRoot, suppliedPrivateRoot = privateRoot) =>
  diagnosticLeaks(root, [token], suppliedPrivateRoot, configuredRoot);
const inputPath = () => join(context.path, "input.txt");
const metadataPath = () => join(context.path, "metadata.json");
const writeMetadata = (value: unknown) => writeFileSync(metadataPath(), JSON.stringify(value));

describe("private retained Speak input classification", () => {
  beforeEach(() => {
    const run = process.env.VOICELAYER_TEST_RUN_ROOT;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run) throw new Error("canonical isolated preload required");
    savedRoot = process.env.QA_VOICE_RECORDINGS_DIR;
    root = mkdtempSync(join(run, "speak-classifier-"));
    privateRoot = join(root, "private");
    mkdirSync(privateRoot, { mode: 0o700 });
    recordingsRoot = join(privateRoot, "recordings");
    process.env.QA_VOICE_RECORDINGS_DIR = recordingsRoot;
    const receipt = createSpeakReceipt({
      input: token, request_id: "synthetic-classifier", request_source: "ask_prompt",
      connection: "daemon", format: null, blocking: true,
      requested: { mode: "converse", profile: null, engine: null, voice: null, rate: null },
      build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null },
    });
    if (receipt.kind !== "created") throw new Error("synthetic receipt creation failed");
    context = receipt.context;
  });
  afterEach(() => {
    if (savedRoot === undefined) delete process.env.QA_VOICE_RECORDINGS_DIR;
    else process.env.QA_VOICE_RECORDINGS_DIR = savedRoot;
    rmSync(root, { recursive: true, force: true });
  });

  it("excludes a real creator receipt only with explicit root context", () => {
    expect(scan()).toEqual([]);
    expect(diagnosticLeaks(root, [token], privateRoot)).toEqual(["input.txt"]);
    expect(() => assertNoCanaryDiagnostics(root, [token], "", "", recordingsRoot)).not.toThrow();
  });
  it("still detects an adjacent diagnostic, SQLite and both captured streams", () => {
    writeFileSync(join(context.path, "debug.log"), token);
    const db = new Database(join(context.path, "journal.db"));
    try {
      db.exec("CREATE TABLE diagnostics (text TEXT)");
      db.query("INSERT INTO diagnostics VALUES (?)").run(token);
    } finally { db.close(); }
    expect(scan().sort()).toEqual(["debug.log", "journal.db"]);
    expect(streamLeaks(token, token, [token])).toEqual(["stdout", "stderr"]);
    expect(() => assertNoCanaryDiagnostics(root, [token], token, token, recordingsRoot)).toThrow("stdout, stderr");
  });
  it("scans input.txt outside the explicit recordings root despite valid sibling metadata", () => {
    const outside = join(privateRoot, "adjacent", context.id.slice(0, 10), context.id);
    mkdirSync(dirname(outside), { recursive: true, mode: 0o700 });
    renameSync(context.path, outside);
    expect(scan()).toEqual(["input.txt"]);
  });
  for (const shape of ["wrong-day", "bad-id", "extra-depth"] as const) {
    it(`scans a receipt with ${shape} hierarchy`, () => {
      const destination = shape === "wrong-day" ? join(recordingsRoot, "2000-01-01", context.id)
        : shape === "bad-id" ? join(dirname(context.path), "not-an-allocator-id")
        : join(dirname(context.path), "nested", context.id);
      mkdirSync(dirname(destination), { recursive: true, mode: 0o700 });
      renameSync(context.path, destination);
      expect(scan()).toEqual(["input.txt"]);
    });
  }
  for (const field of ["source", "schema", "id", "bytes", "hash", "created_at", "request_source"] as const) {
    it(`scans mismatching ${field} metadata`, () => {
      const patches = {
        source: { source: "voice_ask" }, schema: { schema_version: 2 },
        id: { id: context.id.replace(/.$/, "x") },
        bytes: { input: { ...context.metadata.input, bytes: context.metadata.input.bytes + 1 } },
        hash: { input: { ...context.metadata.input, sha256: "0".repeat(64) } },
        created_at: { created_at: "2000-01-01T00:00:00.000Z" },
        request_source: { request_source: "diagnostic" },
      };
      writeMetadata({ ...context.metadata, ...patches[field] });
      expect(scan()).toEqual(["input.txt"]);
    });
  }
  it("scans a receipt not owned by the observing UID", () => {
    if (!process.getuid) throw new Error("UID observation required");
    const uid = spyOn(process, "getuid").mockReturnValue(process.getuid() + 1);
    try { expect(scan()).toEqual(["input.txt"]); }
    finally { uid.mockRestore(); }
  });
  for (const defect of ["missing", "malformed", "missing-input-contract"] as const) {
    it(`scans ${defect} metadata`, () => {
      if (defect === "missing") rmSync(metadataPath());
      if (defect === "malformed") writeFileSync(metadataPath(), "{");
      if (defect === "missing-input-contract") writeMetadata({ source: "speak", id: context.id });
      expect(scan()).toEqual(["input.txt"]);
    });
  }
  for (const target of ["private-root", "recordings-root", "day", "entry", "input", "metadata"] as const) {
    it(`scans insecure ${target} permissions`, () => {
      const path = target === "private-root" ? privateRoot : target === "recordings-root" ? recordingsRoot
        : target === "day" ? dirname(context.path) : target === "entry" ? context.path
        : target === "input" ? inputPath() : metadataPath();
      chmodSync(path, target === "input" || target === "metadata" ? 0o644 : 0o755);
      expect(scan()).toEqual(["input.txt"]);
    });
  }
  for (const target of ["input", "metadata"] as const) {
    it(`reports a symlink ${target} without following it`, () => {
      const path = target === "input" ? inputPath() : metadataPath();
      const moved = join(root, `owned-${target}`);
      renameSync(path, moved); symlinkSync(moved, path);
      const leaks = scan();
      expect(leaks).toContain(target === "input" ? "input.txt" : "metadata.json");
      if (target === "metadata") expect(leaks).toContain("input.txt");
    });
    it(`scans a hard-linked ${target}`, () => {
      linkSync(target === "input" ? inputPath() : metadataPath(), join(root, `alias-${target}`));
      expect(scan()).toContain("input.txt");
    });
  }
  it("rejects root escapes and lexical aliases without normalizing them into permission", () => {
    expect(scan(recordingsRoot, join(root, "unrelated-private"))).toEqual(["input.txt"]);
    expect(scan(privateRoot)).toEqual(["input.txt"]);
    expect(scan(`${recordingsRoot}/../recordings`)).toEqual(["input.txt"]);
    const alias = join(privateRoot, "alias");
    symlinkSync(recordingsRoot, alias);
    expect(scan(alias).sort()).toEqual(["alias", "input.txt"]);
  });
  it("reports a symlink archive ancestor without descending into its target", () => {
    const day = dirname(context.path), moved = join(root, "owned-day");
    renameSync(day, moved); symlinkSync(moved, day);
    expect(scan()).toContain(context.id.slice(0, 10));
    expect(scan()).toContain("input.txt"); // The real file outside recordings remains scanned.
  });
});
