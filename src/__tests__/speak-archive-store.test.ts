import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { createHash } from "crypto";
import * as fs from "fs";
import { join, relative, resolve } from "path";
import { createSpeakReceipt, type SpeakReceiptRequest } from "../speak-archive";
import { openSpeakEventJournal } from "../speak-archive-events";
import { recoverSpeakArchive, saveSpeakArtifact, saveSpeakProjection, updateSpeakLifecycle,
  type SpeakLifecycle } from "../speak-archive-store";
const at = new Date("2026-10-23T12:34:56.789Z"), id = "2026-10-23T12-34-56-789Z-1234abcd";
const request: SpeakReceiptRequest = { input: " \t**שלום** e\u0301 🗣️ fu… no, full\r\n ", request_id: "../synthetic-request",
  request_source: "selection", connection: "daemon", format: "markdown", blocking: false,
  requested: { mode: null, profile: null, engine: null, voice: null, rate: null },
  build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } };
const update: SpeakLifecycle = { status: "preparing", generation_id: "g1",
  timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null },
  summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code: null }, played_spans: [] };
const projection = { display: " שלום\n", spoken: " shalom\n", normalization: {
  version: null, pronunciation_hash: null, settings_hash: null, stages: [] }, chunks: [{ chunk_id: "c0", index: 0,
  source_range_utf16: null, display_range_utf16: null, spoken_range_utf16: null,
  display_text: " שלום\n", spoken_text: " shalom\n", state: "planned", attempts: [] }] } as const;
const hash = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
let root: string, previous: string;
let restores: (() => void)[] = [];
function receipt(value = request) {
  const result = createSpeakReceipt(value, { now: () => at, id: () => id });
  if (result.kind !== "created") throw new Error("synthetic creation failed");
  return result.context;
}
function disk(path: string) { return JSON.parse(fs.readFileSync(join(path, "metadata.json"), "utf8")); }
function artifact(bytes = Buffer.from("synthetic playback MP3 bytes")) {
  return { bytes, role: "playback_ready", mime: "audio/mpeg", duration_ms: null, sample_rate: null, channels: null } as const;
}
describe("speak store completion (real isolated filesystem)", () => {
  beforeEach(() => {
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, archive = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !archive ||
      relative(resolve(run), resolve(archive)).startsWith("..") || resolve(run) === resolve(archive)) throw new Error("canonical isolated preload required");
    previous = archive; root = fs.mkdtempSync(join(archive, "speak-store-")); process.env.QA_VOICE_RECORDINGS_DIR = root;
  });
  afterEach(() => {
    for (const restore of restores.reverse()) restore(); restores = [];
    if (previous) process.env.QA_VOICE_RECORDINGS_DIR = previous;
    if (root) fs.rmSync(root, { recursive: true, force: true });
  });
  for (const status of ["playing", "paused", "completed", "stopped", "replaced", "rejected", "failed"] as const) {
    it(`persists ${status}, explicit unknowns and exact identity without changing input`, () => {
      const c = receipt(), before = fs.readFileSync(join(c.path, "input.txt"));
      expect(updateSpeakLifecycle(c, update).kind).toBe("stored");
      const enriched = { ...update, status, secret: "synthetic-secret" };
      expect(updateSpeakLifecycle(c, enriched).kind).toBe("stored");
      expect(disk(c.path)).toMatchObject({ id, request_id: request.request_id, status, generation_id: "g1",
        lifecycle: { timing: { acoustic_first_audio_ms: null }, summary: { generated_audio_ms: null } }, retention: { policy: "indefinite" } });
      expect(fs.readFileSync(join(c.path, "metadata.json"), "utf8")).not.toContain("synthetic-secret");
      expect(fs.readFileSync(join(c.path, "input.txt"))).toEqual(before);
      expect(fs.statSync(join(c.path, "metadata.json")).mode & 0o777).toBe(0o600);
      if (["completed", "stopped", "replaced", "rejected", "failed"].includes(status))
        expect(updateSpeakLifecycle(c, update)).toEqual({ kind: "failed", code: "FINALIZED" });
    });
  }
  it("preserves creation's unrestricted request ID domain", () => {
    const c = receipt({ ...request, request_id: "\ud800\u0000../request" });
    expect(updateSpeakLifecycle(c, update)).toMatchObject({ kind: "stored", metadata: { request_id: c.metadata.request_id } });
  });
  it("keeps projections exact, planned chunks after Stop, and rejects a different projection", () => {
    const c = receipt(), p = JSON.parse(JSON.stringify(projection));
    expect(saveSpeakProjection(c, p).kind).toBe("stored");
    expect(updateSpeakLifecycle(c, { ...update, status: "stopped" }).kind).toBe("stored");
    expect(saveSpeakProjection(c, p).kind).toBe("stored");
    expect(fs.readFileSync(join(c.path, "display.txt"), "utf8")).toBe(projection.display);
    expect(fs.readFileSync(join(c.path, "spoken.txt"), "utf8")).toBe(projection.spoken);
    expect(JSON.parse(fs.readFileSync(join(c.path, "chunks.json"), "utf8"))).toEqual(projection.chunks);
    expect(saveSpeakProjection(c, { ...p, display: "different" })).toEqual({ kind: "failed", code: "CONFLICT" });
    expect(fs.readFileSync(join(c.path, "input.txt"), "utf8")).toBe(request.input);
  });
  it("retains playback bytes before caller disposal, hashes provider WAV by default, and stores debug bytes only explicitly", () => {
    const c = receipt(), source = join(root, "synthetic-temp.mp3"), bytes = artifact().bytes;
    fs.writeFileSync(source, bytes, { mode: 0o600 });
    expect(saveSpeakArtifact(c, artifact(fs.readFileSync(source))).kind).toBe("stored"); fs.unlinkSync(source);
    const a = disk(c.path).artifacts[0]; expect(a.sha256).toBe(hash(bytes)); expect(a.bytes).toBe(bytes.length);
    expect(fs.readFileSync(join(c.path, a.relative_path))).toEqual(bytes);
    const wav = { ...artifact(Buffer.from("synthetic provider WAV")), role: "provider_output", mime: "audio/wav" } as const;
    expect(saveSpeakArtifact(c, wav).kind).toBe("stored"); expect(disk(c.path).artifacts[1].relative_path).toBeNull();
    expect(fs.readdirSync(join(c.path, "audio"))).toHaveLength(1);
    expect(saveSpeakArtifact(c, artifact(bytes)).kind).toBe("stored");
    expect(fs.readdirSync(join(c.path, "audio"))).toHaveLength(1);
    expect(saveSpeakArtifact(c, { ...wav, debug_provider_bytes: true }).kind).toBe("stored");
    for (const name of fs.readdirSync(join(c.path, "audio"))) expect(fs.statSync(join(c.path, "audio", name)).mode & 0o777).toBe(0o600);
    expect(fs.statSync(join(c.path, "audio")).mode & 0o777).toBe(0o700);
    for (const name of ["audio.wav", "voicelayer-transcript.txt", "played_derived"]) expect(fs.existsSync(join(c.path, name))).toBe(false);
    expect(saveSpeakArtifact(c, { ...wav, role: "playback_ready" })).toEqual({ kind: "failed", code: "INVALID_INPUT" });
  });
  it("recovers unfinished state and torn tail while preserving every original journal byte and available audio", () => {
    const c = receipt(), opened = openSpeakEventJournal(c);
    if (opened.kind !== "opened") throw new Error("synthetic journal failed");
    opened.journal.append({ generation_id: null, playback_id: null, chunk_id: null, utc: at.toISOString(),
      clock_id: null, elapsed_ms: null, event: "request_received", data: { request_source: "selection" } }); opened.journal.close();
    updateSpeakLifecycle(c, update); saveSpeakArtifact(c, artifact());
    const path = join(c.path, "events.ndjson"); fs.appendFileSync(path, '{"seq":2'); const original = fs.readFileSync(path);
    expect(recoverSpeakArchive(id)).toMatchObject({ kind: "stored", metadata: { status: "interrupted_unknown",
      request_id: request.request_id, recovery: { journal_complete_lines: 1, torn_tail_bytes: 8 } } });
    expect(fs.readFileSync(path)).toEqual(original); expect(openSpeakEventJournal(c).kind).toBe("failed");
    const recovered = fs.readFileSync(join(c.path, "metadata.json")); recoverSpeakArchive(id);
    expect(fs.readFileSync(join(c.path, "metadata.json"))).toEqual(recovered);
  });
  it("recovers input-only crash with explicit unknown request identity", () => {
    const c = receipt(); fs.unlinkSync(join(c.path, "metadata.json"));
    expect(recoverSpeakArchive(id)).toMatchObject({ kind: "stored", metadata: { request_id: null, status: "interrupted_unknown",
      input: c.metadata.input, recovery: { metadata_missing: true } } });
    expect(fs.readFileSync(join(c.path, "input.txt"), "utf8")).toBe(request.input);
  });
  for (const fault of ["write", "sync", "directory-sync", "metadata-rename"] as const) {
    it(`reports ${fault} uncertainty, preserves evidence, and never leaks a private error`, () => {
      const c = receipt(), original = fs.readFileSync(join(c.path, "metadata.json"));
      const write = fs.writeFileSync, rename = fs.renameSync, sync = fs.fsyncSync;
      const fail = () => { throw new Error(request.input + c.path); };
      const spy = fault === "write" ? spyOn(fs, "writeFileSync").mockImplementation((fd, bytes, opts) => { write(fd, "partial", opts); fail(); }) :
        fault === "metadata-rename" ? spyOn(fs, "renameSync").mockImplementation((a, b) => { if (String(b).endsWith("metadata.json")) fail(); rename(a, b); }) :
        spyOn(fs, "fsyncSync").mockImplementation(fd => { if ((fault === "sync" && fs.fstatSync(fd).isFile()) || (fault === "directory-sync" && fs.fstatSync(fd).isDirectory() && fs.readdirSync(join(c.path, "audio")).length > 0)) fail(); sync(fd); });
      restores.push(() => spy.mockRestore());
      const result = saveSpeakArtifact(c, artifact()); expect(result.kind).toBe("failed"); expect(JSON.stringify(result)).not.toContain(request.input);
      expect(JSON.stringify(result)).not.toContain(c.path); expect(fs.readFileSync(join(c.path, "metadata.json"))).toEqual(original);
      spy.mockRestore(); restores = [];
      expect(fs.readdirSync(c.path).length + fs.readdirSync(join(c.path, "audio")).length).toBeGreaterThan(3);
      expect(recoverSpeakArchive(id).kind).toBe("stored");
      if (fault === "metadata-rename") {
        expect(disk(c.path).recovery.orphan_audio).toHaveLength(1);
        expect(disk(c.path).artifacts[0]).toMatchObject({ role: "unknown", sha256: hash(artifact().bytes) });
      }
    });
  }
  it("keeps late generated lookahead after Stop and preserves terminal outcome on recovery", () => {
    const c = receipt(); updateSpeakLifecycle(c, { ...update, status: "stopped" });
    expect(saveSpeakArtifact(c, artifact()).kind).toBe("stored");
    expect(recoverSpeakArchive(id)).toMatchObject({ kind: "stored", metadata: { status: "stopped", artifacts: [{ sha256: hash(artifact().bytes) }] } });
  });
  it("rejects foreign identities, unsafe links, forbidden names and lost call-time isolation", () => {
    const c = receipt(); expect(updateSpeakLifecycle({ ...c, path: root }, update).kind).toBe("failed");
    fs.symlinkSync(join(c.path, "input.txt"), join(c.path, "audio")); expect(saveSpeakArtifact(c, artifact()).kind).toBe("failed"); fs.unlinkSync(join(c.path, "audio"));
    fs.writeFileSync(join(c.path, "audio.wav"), "forbidden", { mode: 0o600 }); expect(updateSpeakLifecycle(c, update).kind).toBe("failed"); fs.unlinkSync(join(c.path, "audio.wav"));
    process.env.QA_VOICE_RECORDINGS_DIR = " "; expect(updateSpeakLifecycle(c, update).kind).toBe("failed");
  });
  it("preserves same-day Dictation/Ask bytes, modes and audio-based reader membership", () => {
    const c = receipt(), day = join(root, "2026-10-23");
    for (const source of ["voicebar", "voice_ask"]) {
      const path = join(day, source); fs.mkdirSync(path, { mode: 0o750 });
      fs.chmodSync(path, 0o750);
      expect(fs.statSync(path).mode & 0o777).toBe(0o750);
      fs.writeFileSync(join(path, "metadata.json"), JSON.stringify({ source }), { mode: 0o640 }); fs.writeFileSync(join(path, "audio.wav"), source, { mode: 0o640 });
    }
    updateSpeakLifecycle(c, update); saveSpeakArtifact(c, artifact()); recoverSpeakArchive(id);
    expect(fs.readdirSync(day).filter(name => fs.existsSync(join(day, name, "audio.wav"))).sort()).toEqual(["voice_ask", "voicebar"]);
    for (const source of ["voicebar", "voice_ask"]) {
      const path = join(day, source); expect(fs.readFileSync(join(path, "metadata.json"), "utf8")).toBe(JSON.stringify({ source }));
      expect(fs.readFileSync(join(path, "audio.wav"), "utf8")).toBe(source); expect(fs.statSync(path).mode & 0o777).toBe(0o750);
    }
  });
  it("SOL-R1-1 retries the failed audio-directory sync without rewriting matching artifact bytes", () => {
    const c = receipt(), input = fs.readFileSync(join(c.path, "input.txt")), audio = join(c.path, "audio");
    const a = artifact(), path = join(audio, hash(a.bytes) + ".mp3"), originalSync = fs.fsyncSync, rename = fs.renameSync;
    let fault = true, audioSyncs = 0, artifactRenames = 0;
    const syncSpy = spyOn(fs, "fsyncSync").mockImplementation(fd => {
      const stat = fs.fstatSync(fd);
      if (stat.isDirectory() && fs.existsSync(audio) && stat.ino === fs.statSync(audio).ino && stat.dev === fs.statSync(audio).dev) {
        audioSyncs++; if (fault) throw new Error("synthetic audio-directory sync failure");
      }
      originalSync(fd);
    });
    const renameSpy = spyOn(fs, "renameSync").mockImplementation((from, to) => {
      if (String(to) === path) artifactRenames++; rename(from, to);
    });
    restores.push(() => syncSpy.mockRestore(), () => renameSpy.mockRestore());
    expect(saveSpeakArtifact(c, a)).toEqual({ kind: "failed", code: "SYNC_UNCERTAIN" });
    const inode = fs.statSync(path).ino;
    expect(saveSpeakArtifact(c, a)).toEqual({ kind: "failed", code: "SYNC_UNCERTAIN" });
    expect(audioSyncs).toBe(2); expect(artifactRenames).toBe(1); expect(disk(c.path).artifacts).toBeUndefined();
    fault = false;
    expect(saveSpeakArtifact(c, a).kind).toBe("stored"); expect(audioSyncs).toBe(3);
    expect(artifactRenames).toBe(1); expect(fs.statSync(path).ino).toBe(inode);
    expect(fs.readFileSync(path)).toEqual(a.bytes); expect(fs.readFileSync(join(c.path, "input.txt"))).toEqual(input);
  });
  it("SOL-R1-2 repeats recovery's required entry sync after interrupted metadata was renamed", () => {
    const c = receipt(), opened = openSpeakEventJournal(c);
    if (opened.kind !== "opened") throw new Error("synthetic journal failed");
    expect(opened.journal.append({ generation_id: null, playback_id: null, chunk_id: null, utc: at.toISOString(),
      clock_id: null, elapsed_ms: null, event: "request_received", data: { request_source: "selection" } }).kind).toBe("durable");
    opened.journal.close();
    const input = fs.readFileSync(join(c.path, "input.txt")), journal = fs.readFileSync(join(c.path, "events.ndjson"));
    const entry = fs.statSync(c.path), originalSync = fs.fsyncSync; let fault = true, entrySyncs = 0;
    const spy = spyOn(fs, "fsyncSync").mockImplementation(fd => {
      const stat = fs.fstatSync(fd);
      if (stat.isDirectory() && stat.ino === entry.ino && stat.dev === entry.dev) {
        entrySyncs++; if (fault) throw new Error("synthetic post-rename recovery sync failure");
      }
      originalSync(fd);
    });
    restores.push(() => spy.mockRestore());
    expect(recoverSpeakArchive(id)).toEqual({ kind: "failed", code: "SYNC_UNCERTAIN" });
    expect(disk(c.path).status).toBe("interrupted_unknown");
    const published = fs.readFileSync(join(c.path, "metadata.json"));
    expect(recoverSpeakArchive(id)).toEqual({ kind: "failed", code: "SYNC_UNCERTAIN" }); expect(entrySyncs).toBe(2);
    expect(fs.readFileSync(join(c.path, "metadata.json"))).toEqual(published);
    fault = false;
    expect(recoverSpeakArchive(id).kind).toBe("stored"); expect(entrySyncs).toBe(3);
    expect(fs.readFileSync(join(c.path, "metadata.json"))).toEqual(published);
    expect(fs.readFileSync(join(c.path, "input.txt"))).toEqual(input);
    expect(fs.readFileSync(join(c.path, "events.ndjson"))).toEqual(journal);
  });
  it("SOL-R1-2 reconciles late orphan/partial evidence after a prior successful interruption recovery", () => {
    const c = receipt(), opened = openSpeakEventJournal(c);
    if (opened.kind !== "opened") throw new Error("synthetic journal failed");
    expect(opened.journal.append({ generation_id: null, playback_id: null, chunk_id: null, utc: at.toISOString(),
      clock_id: null, elapsed_ms: null, event: "request_received", data: { request_source: "selection" } }).kind).toBe("durable");
    opened.journal.close(); fs.appendFileSync(join(c.path, "events.ndjson"), '{"seq":2');
    const input = fs.readFileSync(join(c.path, "input.txt")), journal = fs.readFileSync(join(c.path, "events.ndjson"));
    expect(recoverSpeakArchive(id).kind).toBe("stored");
    const recovered = fs.readFileSync(join(c.path, "metadata.json")), rename = fs.renameSync;
    const spy = spyOn(fs, "renameSync").mockImplementation((from, to) => {
      if (String(to) === join(c.path, "metadata.json")) throw new Error("synthetic late-artifact metadata failure");
      rename(from, to);
    });
    restores.push(() => spy.mockRestore());
    expect(saveSpeakArtifact(c, artifact())).toEqual({ kind: "failed", code: "WRITE_UNCERTAIN" });
    expect(fs.readFileSync(join(c.path, "metadata.json"))).toEqual(recovered);
    // The synchronous writer has returned; recovery never runs against an active writer.
    spy.mockRestore();
    const partials = fs.readdirSync(c.path).filter(name => name.endsWith(".partial")); expect(partials).toHaveLength(1);
    const partial = fs.readFileSync(join(c.path, partials[0]!)), name = hash(artifact().bytes) + ".mp3";
    expect(recoverSpeakArchive(id)).toMatchObject({ kind: "stored", metadata: { status: "interrupted_unknown",
      recovery: { orphan_audio: [name], partial_files: partials, journal_complete_lines: 1, torn_tail_bytes: 8 },
      artifacts: [{ role: "unknown", sha256: hash(artifact().bytes), relative_path: "audio/" + name }] } });
    const reconciled = fs.readFileSync(join(c.path, "metadata.json"));
    expect(recoverSpeakArchive(id).kind).toBe("stored");
    expect(fs.readFileSync(join(c.path, "metadata.json"))).toEqual(reconciled); expect(disk(c.path).artifacts).toHaveLength(1);
    expect(fs.readFileSync(join(c.path, partials[0]!))).toEqual(partial);
    expect(fs.readFileSync(join(c.path, "audio", name))).toEqual(artifact().bytes);
    expect(fs.readFileSync(join(c.path, "input.txt"))).toEqual(input);
    expect(fs.readFileSync(join(c.path, "events.ndjson"))).toEqual(journal);
  });
});
