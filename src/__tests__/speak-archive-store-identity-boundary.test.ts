import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { createHash } from "crypto";
import * as fs from "fs";
import { isAbsolute, join, relative, resolve } from "path";
import { createSpeakReceipt, type SpeakReceiptRequest } from "../speak-archive";
import { recoverSpeakArchive, saveSpeakArtifact, saveSpeakProjection, updateSpeakLifecycle,
  type SpeakLifecycle, type SpeakStoreResult } from "../speak-archive-store";

// Authored source-only regressions: UNRUN_UNCOMPILED until the parent qualifies this head.
const request: SpeakReceiptRequest = { input: "  synthetic שלום e\u0301 🗣️ fu… no, full\n",
  request_id: "synthetic-request", request_source: "selection", connection: "daemon", format: "plain", blocking: false,
  requested: { mode: null, profile: null, engine: null, voice: null, rate: null },
  build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } };
const projection: Parameters<typeof saveSpeakProjection>[1] = {
  display: "synthetic display שלום", spoken: "synthetic spoken שלום",
  normalization: { version: null, pronunciation_hash: null, settings_hash: null, stages: [] },
  chunks: [{ chunk_id: "c0", index: 0, source_range_utf16: null, display_range_utf16: null,
    spoken_range_utf16: null, display_text: "synthetic display שלום", spoken_text: "synthetic spoken שלום",
    state: "planned", attempts: [] }] };
const stopped: SpeakLifecycle = { status: "stopped", generation_id: null,
  timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null },
  summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code: null }, played_spans: [] };
const artifact: Parameters<typeof saveSpeakArtifact>[1] = { bytes: Buffer.from("synthetic MP3 bytes"),
  role: "playback_ready", mime: "audio/mpeg", duration_ms: null, sample_rate: null, channels: null };
const marker = "synthetic-private-error-marker";
const hash = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
let root: string | undefined, previous: string | undefined;
let restores: (() => void)[] = [];
function receipt() {
  const result = createSpeakReceipt(request);
  if (result.kind !== "created") throw new Error("synthetic receipt failed");
  return result.context;
}
function stored(result: SpeakStoreResult) {
  if (result.kind !== "stored") throw new Error(`synthetic store failed: ${result.code}`);
  return result.metadata;
}
function evidence(entry: string) {
  return fs.readdirSync(entry).sort().map(name => {
    const stat = fs.lstatSync(join(entry, name));
    return { name, inode: stat.ino, mode: stat.mode, bytes: fs.readFileSync(join(entry, name)) };
  });
}
function bounded(call: () => SpeakStoreResult, code: Extract<SpeakStoreResult, { kind: "failed" }>["code"]) {
  let result: SpeakStoreResult | undefined;
  expect(() => { result = call(); }).not.toThrow();
  expect(result).toEqual({ kind: "failed", code });
  for (const privateValue of [marker, request.input, root]) {
    if (privateValue) expect(JSON.stringify(result)).not.toContain(privateValue);
  }
}
const apis = [
  { name: "updateSpeakLifecycle", call: (c: ReturnType<typeof receipt>) => updateSpeakLifecycle(c, stopped),
    invalid: (c: ReturnType<typeof receipt>) => updateSpeakLifecycle(c,
      { ...stopped, summary: { ...stopped.summary, generated_audio_ms: -1 } }) },
  { name: "saveSpeakProjection", call: (c: ReturnType<typeof receipt>) => saveSpeakProjection(c, projection),
    invalid: (c: ReturnType<typeof receipt>) => saveSpeakProjection(c, { ...projection, display: "\ud800" }) },
  { name: "saveSpeakArtifact", call: (c: ReturnType<typeof receipt>) => saveSpeakArtifact(c, artifact),
    invalid: (c: ReturnType<typeof receipt>) => saveSpeakArtifact(c, { ...artifact, channels: -1 }) },
];

describe("speak store immutable identity and total error boundary (source-only authored cases)", () => {
  beforeEach(() => {
    root = undefined; previous = process.env.QA_VOICE_RECORDINGS_DIR;
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, base = resolve(".test-tmp");
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run) throw new Error("canonical isolated preload required");
    const child = relative(base, resolve(run));
    if (!child || child === ".." || child.startsWith("../") || isAbsolute(child) ||
      fs.realpathSync(run) !== resolve(run)) throw new Error("owned preload root required");
    root = fs.mkdtempSync(join(run, "store-identity-boundary-"));
    process.env.QA_VOICE_RECORDINGS_DIR = root;
  });
  afterEach(() => {
    for (const restore of restores.reverse()) restore(); restores = [];
    if (previous === undefined) delete process.env.QA_VOICE_RECORDINGS_DIR;
    else process.env.QA_VOICE_RECORDINGS_DIR = previous;
    if (root) fs.rmSync(root, { recursive: true, force: true });
    root = undefined;
  });

  for (const field of ["display", "spoken"] as const) {
    for (const disk of ["missing", "altered to candidate"] as const) {
      it(`I0BD7-R1-1 refuses changed indexed ${field} with disk ${disk} and preserves all evidence`, () => {
        const c = receipt(), m = stored(saveSpeakProjection(c, projection)), name = `${field}.txt`;
        const path = join(c.path, name), candidate = { ...projection, [field]: "synthetic changed text" };
        const retained = m.projections.find(p => p.name === name);
        expect(retained?.sha256).toBe(hash(Buffer.from(projection[field])));
        if (disk === "missing") fs.unlinkSync(path);
        else fs.writeFileSync(path, candidate[field]);
        const before = evidence(c.path);
        bounded(() => saveSpeakProjection(c, candidate), "CONFLICT");
        expect(evidence(c.path)).toEqual(before);
        expect(JSON.parse(fs.readFileSync(join(c.path, "metadata.json"), "utf8")).projections).toEqual(m.projections);
        if (disk === "missing") expect(fs.existsSync(path)).toBe(false);
        else bounded(() => recoverSpeakArchive(c.id), "CORRUPT_METADATA");
        expect(evidence(c.path)).toEqual(before);
      });
    }
    it(`I0BD7-R1-1 restores missing indexed ${field} only with matching bytes`, () => {
      const c = receipt(), m = stored(saveSpeakProjection(c, projection));
      const input = fs.readFileSync(join(c.path, "input.txt")), path = join(c.path, `${field}.txt`);
      fs.unlinkSync(path);
      const restored = stored(saveSpeakProjection(c, projection));
      expect(fs.readFileSync(path, "utf8")).toBe(projection[field]);
      expect(restored.projections).toEqual(m.projections);
      expect(restored.normalization).toEqual(projection.normalization);
      expect(fs.statSync(path).mode & 0o777).toBe(0o600);
      expect(fs.readFileSync(join(c.path, "input.txt"))).toEqual(input);
    });
  }

  it("preserves first publication with no indexed projection", () => {
    const c = receipt(), input = fs.readFileSync(join(c.path, "input.txt"));
    expect(fs.readdirSync(c.path).sort()).toEqual(["input.txt", "metadata.json"]);
    const m = stored(saveSpeakProjection(c, projection));
    expect(m.projections).toHaveLength(3);
    for (const p of m.projections) expect(p.sha256).toBe(hash(fs.readFileSync(join(c.path, p.name))));
    expect(m.totals.chunk_count).toBe(1);
    expect(fs.readFileSync(join(c.path, "input.txt"))).toEqual(input);
  });

  for (const reconciliation of ["writer retry", "recovery"]) {
    it(`preserves no-index crash reconciliation by ${reconciliation}`, () => {
      const c = receipt(), beforeMetadata = fs.readFileSync(join(c.path, "metadata.json"));
      const originalRename = fs.renameSync;
      const spy = spyOn(fs, "renameSync").mockImplementation((from, to) => {
        if (String(to) === join(c.path, "metadata.json")) throw new Error(marker);
        originalRename(from, to);
      });
      restores.push(() => spy.mockRestore());
      try { bounded(() => saveSpeakProjection(c, projection), "WRITE_UNCERTAIN"); }
      finally { spy.mockRestore(); }
      expect(fs.readFileSync(join(c.path, "metadata.json"))).toEqual(beforeMetadata);
      const before = evidence(c.path);
      const m = stored(reconciliation === "writer retry" ? saveSpeakProjection(c, projection) : recoverSpeakArchive(c.id));
      expect(m.projections).toHaveLength(3);
      for (const p of m.projections) expect(p.sha256).toBe(hash(fs.readFileSync(join(c.path, p.name))));
      expect(m.totals.chunk_count).toBe(1);
      for (const file of before.filter(f => f.name !== "metadata.json")) {
        expect(fs.readFileSync(join(c.path, file.name))).toEqual(file.bytes);
      }
    });
  }

  it("allows chunks to progress after Stop while retaining both immutable text identities", () => {
    const c = receipt(), published = stored(saveSpeakProjection(c, projection));
    stored(updateSpeakLifecycle(c, stopped));
    const m = stored(saveSpeakProjection(c, { ...projection,
      chunks: projection.chunks.map(chunk => ({ ...chunk, state: "generated" })) }));
    expect(m.status).toBe("stopped"); expect(m.lifecycle).toEqual(stopped);
    for (const field of ["display", "spoken"] as const) {
      expect(fs.readFileSync(join(c.path, `${field}.txt`), "utf8")).toBe(projection[field]);
      expect(m.projections.find(p => p.name === `${field}.txt`)).toEqual(
        published.projections.find(p => p.name === `${field}.txt`));
    }
    expect(m.projections.find(p => p.name === "chunks.json")).not.toEqual(
      published.projections.find(p => p.name === "chunks.json"));
    expect(JSON.parse(fs.readFileSync(join(c.path, "chunks.json"), "utf8"))[0].state).toBe("generated");
    expect(m.normalization).toEqual(projection.normalization);
    expect(stored(recoverSpeakArchive(c.id)).status).toBe("stopped");
    expect(fs.readFileSync(join(c.path, "input.txt"), "utf8")).toBe(request.input);
    bounded(() => updateSpeakLifecycle(c, stopped), "FINALIZED");
  });

  for (const api of apis) {
    it(`I0BD7-R1-2 ${api.name} contains a throwing id getter before filesystem access`, () => {
      const c = receipt(), entry = c.path, before = evidence(entry); let reads = 0;
      Object.defineProperty(c, "id", { get() { reads++; throw new Error(marker); } });
      bounded(() => api.call(c), "IO_ERROR");
      expect(reads).toBe(1); expect(evidence(entry)).toEqual(before);
    });
    for (const thrown of ["ordinary Error", "hostile prototype", "hostile code", "hostile has"]) {
      it(`I0BD7-R1-2 ${api.name} contains metadata getter throwing ${thrown}`, () => {
        const c = receipt(), entry = c.path, before = evidence(entry); let reads = 0, traps = 0;
        const exception = thrown === "ordinary Error" ? new Error(marker) : thrown === "hostile prototype" ?
          new Proxy({}, { getPrototypeOf() { traps++; throw new Error(marker); } }) : thrown === "hostile code" ?
          Object.defineProperty({}, "code", { get() { throw new Error(marker); } }) :
          new Proxy({}, { has() { throw new Error(marker); } });
        Object.defineProperty(c, "metadata", { get() { reads++; throw exception; } });
        bounded(() => api.call(c), "IO_ERROR");
        expect(reads).toBe(1);
        if (thrown === "hostile prototype") expect(traps).toBe(1);
        expect(evidence(entry)).toEqual(before);
      });
    }
    it(`${api.name} preserves ordinary internal Failure classification`, () => {
      const c = receipt(), before = evidence(c.path);
      bounded(() => api.call({ ...c, path: join(c.path, "foreign") }), "UNSAFE_PATH");
      expect(evidence(c.path)).toEqual(before);
    });
    it(`${api.name} preserves ordinary Zod classification`, () => {
      const c = receipt(), before = evidence(c.path);
      bounded(() => api.invalid(c), "INVALID_INPUT");
      expect(evidence(c.path)).toEqual(before);
    });
    it(`${api.name} preserves ordinary filesystem IO_ERROR classification`, () => {
      const c = receipt(), before = evidence(c.path), originalOpen = fs.openSync; let faults = 0;
      const spy = spyOn(fs, "openSync").mockImplementation((path, flags, mode) => {
        if (String(path) === join(c.path, "input.txt")) { faults++; throw new Error(marker); }
        return originalOpen(path, flags, mode);
      });
      restores.push(() => spy.mockRestore());
      try { bounded(() => api.call(c), "IO_ERROR"); } finally { spy.mockRestore(); }
      expect(faults).toBe(1); expect(evidence(c.path)).toEqual(before);
    });
  }

  it("recoverSpeakArchive shares the total boundary for a hostile filesystem exception", () => {
    const c = receipt(), before = evidence(c.path), originalOpen = fs.openSync; let faults = 0, traps = 0;
    const exception = new Proxy({}, { getPrototypeOf() { traps++; throw new Error(marker); } });
    const spy = spyOn(fs, "openSync").mockImplementation((path, flags, mode) => {
      if (String(path) === join(c.path, "input.txt")) { faults++; throw exception; }
      return originalOpen(path, flags, mode);
    });
    restores.push(() => spy.mockRestore());
    try { bounded(() => recoverSpeakArchive(c.id), "IO_ERROR"); } finally { spy.mockRestore(); }
    expect(faults).toBe(1); expect(traps).toBe(1); expect(evidence(c.path)).toEqual(before);
  });

  for (const field of ["display", "spoken"] as const) {
    for (const order of ["matching first", "conflicting first"]) {
      it(`STORE2-23CA-R1-1 refuses conflicting ${field} duplicates with ${order} without erasing evidence`, () => {
        const c = receipt(), m = stored(saveSpeakProjection(c, projection)), name = `${field}.txt`;
        m.projections = m.projections.flatMap(p => {
          if (p.name !== name) return [p];
          const conflicting = { ...p, sha256: hash(Buffer.from("synthetic conflicting identity")) };
          return order === "matching first" ? [p, conflicting] : [conflicting, p];
        });
        fs.writeFileSync(join(c.path, "metadata.json"), JSON.stringify(m));
        fs.writeFileSync(join(c.path, "events.ndjson"),
          JSON.stringify({ seq: 1, request_id: c.metadata.request_id }) + '\n{"torn":', { mode: 0o600 });
        fs.writeFileSync(join(c.path, ".synthetic.partial"), "synthetic retained partial", { mode: 0o600 });
        const before = evidence(c.path);
        bounded(() => saveSpeakProjection(c, projection), "CONFLICT");
        expect(evidence(c.path)).toEqual(before);
        for (let attempt = 0; attempt < 2; attempt++) {
          bounded(() => recoverSpeakArchive(c.id), "CORRUPT_METADATA");
          expect(evidence(c.path)).toEqual(before);
        }
        bounded(() => saveSpeakProjection(c, projection), "CONFLICT");
        expect(evidence(c.path)).toEqual(before);
      });
    }
    for (const ledger of ["absent", "unique", "matching duplicates"]) {
      it(`preserves ${field} recovery with ${ledger} identity records`, () => {
        const c = receipt(), m = stored(saveSpeakProjection(c, projection)), name = `${field}.txt`;
        m.projections = m.projections.flatMap(p => p.name !== name ? [p] :
          ledger === "absent" ? [] : ledger === "unique" ? [p] : [p, { ...p }]);
        fs.writeFileSync(join(c.path, "metadata.json"), JSON.stringify(m));
        const before = evidence(c.path), recovered = stored(recoverSpeakArchive(c.id));
        expect(recovered.projections.filter(p => p.name === name)).toEqual([
          { name, sha256: hash(Buffer.from(projection[field])) }]);
        expect(recovered.projections).toHaveLength(3);
        expect(recovered.normalization).toEqual(projection.normalization);
        expect(evidence(c.path).filter(f => f.name !== "metadata.json")).toEqual(
          before.filter(f => f.name !== "metadata.json"));
        const settled = evidence(c.path);
        stored(recoverSpeakArchive(c.id)); expect(evidence(c.path)).toEqual(settled);
        stored(saveSpeakProjection(c, projection));
      });
    }
  }

  it("keeps chunks mutable after Stop despite conflicting duplicate chunk hashes", () => {
    const c = receipt(); stored(saveSpeakProjection(c, projection));
    const m = stored(updateSpeakLifecycle(c, stopped));
    m.projections.push({ name: "chunks.json", sha256: hash(Buffer.from("synthetic stale chunk identity")) });
    fs.writeFileSync(join(c.path, "metadata.json"), JSON.stringify(m));
    const bytes = Buffer.from(JSON.stringify(projection.chunks.map(chunk => ({ ...chunk, state: "generated" }))));
    fs.writeFileSync(join(c.path, "chunks.json"), bytes);
    const before = evidence(c.path), recovered = stored(recoverSpeakArchive(c.id));
    expect(recovered.status).toBe("stopped"); expect(recovered.lifecycle).toEqual(stopped);
    expect(recovered.projections.filter(p => p.name === "chunks.json")).toEqual([
      { name: "chunks.json", sha256: hash(bytes) }]);
    expect(recovered.projections.filter(p => p.name !== "chunks.json")).toEqual(
      m.projections.filter(p => p.name !== "chunks.json"));
    expect(recovered.totals.chunk_count).toBe(1);
    expect(evidence(c.path).filter(f => f.name !== "metadata.json")).toEqual(
      before.filter(f => f.name !== "metadata.json"));
  });
});
