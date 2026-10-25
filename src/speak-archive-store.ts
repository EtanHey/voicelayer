import { initialSpeech, speechSchema, speechReasonSchema, transitionSpeech, type SpeechState, type SpeechRecord } from "./speech-state";
import { createHash, randomBytes } from "crypto";
import * as fs from "fs";
import { isAbsolute, join, normalize, parse } from "path";
import { z } from "zod";
import { recordingsArchiveRoot } from "./recordings-archive-fs";
import type { SpeakReceiptResult } from "./speak-archive";

type Context = Extract<SpeakReceiptResult, { kind: "created" }>["context"];
const text = z.string().refine(s => Buffer.from(s).toString("utf8") === s);
const count = z.number().finite().nonnegative();
const hash = z.string().regex(/^[a-f0-9]{64}$/);
const nullableText = z.string().nullable(); // Creation retains unrestricted request identity/config strings.
const config = z.object({ mode: nullableText, profile: nullableText, engine: nullableText,
  voice: nullableText, rate: z.number().finite().nullable(), rate_raw: text.optional() });
const range = z.tuple([z.number().int().nonnegative(), z.number().int().nonnegative()])
  .refine(([start, end]) => start <= end).nullable();
const normalization = z.object({ version: nullableText, pronunciation_hash: hash.nullable(),
  settings_hash: hash.nullable(), stages: z.array(z.object({ name: text, input_hash: hash, output_hash: hash })) });
const wordBoundary = z.object({ offset_utf16: count, start_ms: count, end_ms: count });
const chunks = z.array(z.object({ chunk_id: text, index: z.number().int().nonnegative(),
  source_range_utf16: range, display_range_utf16: range, spoken_range_utf16: range,
  display_text: text, spoken_text: text, state: z.enum(["planned", "generating", "generated", "failed", "output_unavailable"]),
  attempts: z.array(z.object({ attempt_id: text, engine_input_text: text, transforms: z.array(text),
    requested_config: config, effective: z.object({ engine: nullableText, voice: nullableText,
      provider_rate: z.number().finite().nullable(), post_rate_factor: z.number().finite().nullable(), model: nullableText,
      engine_options: z.object({ speed: z.number().finite().nullable(), temperature: z.number().finite().nullable(),
        seed: z.number().int().nullable(), language: nullableText }).nullable() }),
    reference_asset_hash: hash.nullable(), started_ms: count.nullable(), finished_ms: count.nullable(),
    outcome: z.enum(["pending", "generated", "failed", "output_unavailable"]), fallback_reason: nullableText,
    provider_boundaries: z.array(wordBoundary), mapped_boundaries: z.array(wordBoundary), mapping_reason: nullableText,
    artifact_ids: z.array(hash) })) }));
const artifact = z.object({ id: hash, relative_path: nullableText,
  role: z.enum(["playback_ready", "provider_output", "unknown"]), mime: z.enum(["audio/mpeg", "audio/wav"]),
  bytes: count, sha256: hash, duration_ms: count.nullable(), sample_rate: count.nullable(), channels: count.nullable() });
const status = z.enum(["received", "preparing", "playing", "paused", "completed", "stopped", "replaced", "rejected", "failed", "interrupted_unknown"]);
const terminal = new Set(["completed", "stopped", "replaced", "rejected", "failed", "interrupted_unknown"]);
const lifecycle = z.object({ status, generation_id: nullableText,
  timing: z.object({ request_clock_id: nullableText, first_player_start_ms: count.nullable(),
    acoustic_first_audio_ms: z.null(), ended_ms: count.nullable() }),
  summary: z.object({ generated_audio_ms: count.nullable(), player_reported_played_ms: count.nullable(),
    error_code: z.enum(["SYNTH_FAILED", "PLAYER_FAILED", "REJECTED", "OUTPUT_UNAVAILABLE", "ARCHIVE_INCOMPLETE"]).nullable() }),
  played_spans: z.array(z.object({ chunk_id: text, playback_id: text, start_ms: count, end_ms: count,
    completion: z.enum(["completed", "partial", "unknown"]), measurement: z.literal("player_reported") })) });
const metadata = z.object({ speech: speechSchema.optional(), schema_version: z.literal(1), source: z.literal("speak"), id: text,
  created_at: z.string().datetime(), updated_at: z.string().datetime(), request_id: nullableText,
  request_source: z.enum(["voice_speak", "selection", "clipboard", "cli", "preview", "ask_prompt", "direct"]).nullable(),
  connection: z.enum(["stdio", "daemon", "cli_local"]).nullable(), format: z.enum(["plain", "markdown"]).nullable(),
  blocking: z.boolean().nullable(), requested: config,
  build: z.object({ app_version: nullableText, daemon_version: nullableText, git_sha: nullableText, executable_hash: nullableText }),
  input: z.object({ bytes: count, sha256: hash }), status, generation_id: nullableText,
  parent_ask_id: nullableText.default(null), caller_request_id: nullableText.default(null),
  lifecycle: lifecycle.nullable().default(null), normalization: normalization.nullable().default(null),
  artifacts: z.array(artifact).default([]), projections: z.array(z.object({ name: z.enum(["display.txt", "spoken.txt", "chunks.json"]), sha256: hash })).default([]),
  retention: z.object({ policy: z.literal("indefinite"), pinned: z.literal(false) }).default({ policy: "indefinite", pinned: false }),
  totals: z.object({ stored_audio_bytes: count, provider_output_bytes: count, chunk_count: count }).default({ stored_audio_bytes: 0, provider_output_bytes: 0, chunk_count: 0 }),
  recovery: z.object({ metadata_missing: z.boolean(), journal_complete_lines: count, torn_tail_bytes: count,
    orphan_audio: z.array(text), partial_files: z.array(text) }).nullable().default(null) });
export type SpeakStoreMetadata = z.infer<typeof metadata>;
export type SpeakLifecycle = z.infer<typeof lifecycle>;
export type SpeakChunks = z.infer<typeof chunks>;
const failureCode = z.enum(["INVALID_INPUT", "UNSAFE_PATH", "CORRUPT_METADATA", "FINALIZED", "CONFLICT", "IO_ERROR", "WRITE_UNCERTAIN", "SYNC_UNCERTAIN"]);
type Code = z.infer<typeof failureCode>;
export type SpeakStoreResult = { kind: "stored"; metadata: SpeakStoreMetadata } | { kind: "failed"; code: Code };
class Failure extends Error { constructor(readonly code: Code) { super(code); } }
function check(ok: boolean, code: Code): asserts ok { if (!ok) throw new Failure(code); }
const digest = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const absent = (e: unknown) => typeof e === "object" && e !== null && "code" in e && e.code === "ENOENT";
function privateStat(s: fs.Stats, directory: boolean) {
  check((directory ? s.isDirectory() : s.isFile()) && !s.isSymbolicLink() &&
    s.uid === process.getuid?.() && (s.mode & 0o7777) === (directory ? 0o700 : 0o600) &&
    (directory || s.nlink === 1), "UNSAFE_PATH");
}
function read(path: string): Buffer {
  const before = fs.lstatSync(path); privateStat(before, false);
  const fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try { const s = fs.fstatSync(fd); check(s.ino === before.ino && s.dev === before.dev, "UNSAFE_PATH"); return fs.readFileSync(fd); }
  finally { fs.closeSync(fd); }
}
function sync(path: string) {
  const fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_DIRECTORY);
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
function location(id: string) {
  check(/^\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}Z-[a-f0-9]{8}$/.test(id), "UNSAFE_PATH");
  const root = recordingsArchiveRoot();
  check(isAbsolute(root) && normalize(root) === root && !root.endsWith("/"), "UNSAFE_PATH");
  const entry = join(root, id.slice(0, 10), id);
  let path = parse(entry).root;
  for (const part of entry.slice(path.length).split("/")) {
    path = join(path, part); const s = fs.lstatSync(path);
    check(s.isDirectory() && !s.isSymbolicLink(), "UNSAFE_PATH");
    if (path === root || path.startsWith(root + "/")) privateStat(s, true);
  }
  for (const name of ["audio.wav", "voicelayer-transcript.txt", "played_derived"]) {
    try { fs.lstatSync(join(entry, name)); throw new Failure("UNSAFE_PATH"); } catch (e) { if (!absent(e)) throw e; }
  }
  return entry;
}
// Retain exclusively owned partials on every error, including after rename. No durability claim beyond successful sync calls.
function publish(entry: string, name: string, bytes: Uint8Array) {
  const temporary = join(entry, `.${name}.${randomBytes(8).toString("hex")}.partial`);
  let code: Code = "WRITE_UNCERTAIN";
  try {
    const fd = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try { fs.writeFileSync(fd, bytes); code = "SYNC_UNCERTAIN"; fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    code = "WRITE_UNCERTAIN"; fs.renameSync(temporary, join(entry, name));
    code = "SYNC_UNCERTAIN"; sync(entry);
  } catch { throw new Failure(code); }
}
const encode = (value: unknown) => Buffer.from(JSON.stringify(value, null, 2) + "\n");
function load(entry: string) {
  try { return metadata.parse(JSON.parse(read(join(entry, "metadata.json")).toString("utf8"))); }
  catch (e) { if (e instanceof Failure || absent(e)) throw e; throw new Failure("CORRUPT_METADATA"); }
}
function boundary(work: () => SpeakStoreMetadata): SpeakStoreResult {
  try { return { kind: "stored", metadata: work() }; }
  catch (e) {
    try {
      return { kind: "failed", code: e instanceof Failure ? failureCode.parse(e.code) : e instanceof z.ZodError ? "INVALID_INPUT" : "IO_ERROR" };
    } catch { return { kind: "failed", code: "IO_ERROR" }; }
  }
}
function persist(entry: string, m: SpeakStoreMetadata) {
  const stored = new Map(m.artifacts.filter(a => a.relative_path !== null).map(a => [a.relative_path, a.bytes]));
  m.totals.stored_audio_bytes = [...stored.values()].reduce((sum, bytes) => sum + bytes, 0);
  m.totals.provider_output_bytes = m.artifacts.filter(a => a.role === "provider_output").reduce((sum, a) => sum + a.bytes, 0);
  m.updated_at = new Date().toISOString(); publish(entry, "metadata.json", encode(m)); return m;
}
function current(entry: string, context: Context) {
  const m = load(entry);
  check(context.path === entry && m.id === context.id && m.request_id === context.metadata.request_id &&
    m.created_at === context.metadata.created_at && m.input.sha256 === context.metadata.input.sha256, "UNSAFE_PATH");
  const input = read(join(entry, "input.txt"));
  check(digest(input) === m.input.sha256 && input.length === m.input.bytes, "CORRUPT_METADATA");
  return m;
}

/** Single synchronous writer per entry. Context is explicit; no ambient current request. */
export function updateSpeakLifecycle(context: Context, update: SpeakLifecycle, linkage?: { parent_ask_id: string | null; caller_request_id: string | null }): SpeakStoreResult {
  return boundary(() => {
    const entry = location(context.id);
    const m = current(entry, context), next = lifecycle.parse(update);
    check(!terminal.has(m.status), "FINALIZED");
    check(next.status !== "received" && next.status !== "interrupted_unknown", "INVALID_INPUT");
    if (m.generation_id !== null) check(next.generation_id === m.generation_id, "CONFLICT");
    if (linkage) {
      const links = z.object({ parent_ask_id: nullableText, caller_request_id: nullableText }).parse(linkage);
      check((m.parent_ask_id === null || m.parent_ask_id === links.parent_ask_id) &&
        (m.caller_request_id === null || m.caller_request_id === links.caller_request_id), "CONFLICT");
      Object.assign(m, links);
    }
    if (m.speech && speechStateForStatus(next.status) !== m.speech.state) {
      const changed = transitionSpeech(m.speech, speechStateForStatus(next.status),
        next.status === "replaced" ? "REPLACED" : next.summary.error_code, new Date().toISOString());
      check(changed !== null, "CONFLICT");
      m.speech = changed;
    }
    m.status = next.status; m.generation_id = next.generation_id; m.lifecycle = next;
    return persist(entry, m);
  });
}
export function readSpeakArchive(context: Context): SpeakStoreResult {
  return boundary(() => current(location(context.id), context));
}
/** Close a player segment without inventing a pause between long-read chunks. */
export function endSpeakPlayer(context: Context): SpeakStoreResult {
  return boundary(() => {
    const entry = location(context.id), m = current(entry, context);
    if (m.speech?.playing_since) {
      m.speech.played_ms += Math.max(0, Date.now() - Date.parse(m.speech.playing_since));
      m.speech.playing_since = null;
    }
    return persist(entry, m);
  });
}
export function startSpeakPlayer(context: Context): SpeakStoreResult {
  return boundary(() => {
    const entry = location(context.id), m = current(entry, context);
    check(m.speech?.state === "playing", "CONFLICT");
    m.speech.playing_since ??= new Date().toISOString();
    return persist(entry, m);
  });
}
/** Persist a validated transition using the existing private atomic metadata writer. */
export function transitionSpeakArchive(context: Context, to: SpeechState, reason: string | null = null): SpeakStoreResult {
  return boundary(() => {
    const entry = location(context.id), m = current(entry, context);
    reason = speechReasonSchema.parse(reason);
    check(!terminal.has(m.status) || m.speech !== undefined, "FINALIZED");
    const next = transitionSpeech(m.speech ?? speechFromLegacy(m), to, reason, new Date().toISOString());
    check(next !== null, "CONFLICT");
    m.speech = next;
    m.status = to === "failed" && reason === "REJECTED" ? "rejected" : to === "requested" ? "received" : to === "cancelled" ? "stopped" : to === "interrupted" ? "interrupted_unknown" : to;
    m.lifecycle ??= { status: m.status, generation_id: m.generation_id,
      timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null },
      summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code: null }, played_spans: [] };
    m.lifecycle.status = m.status;
    if (to === "playing") m.lifecycle.timing.first_player_start_ms ??= Math.max(0, Date.now() - Date.parse(m.created_at));
    if (terminal.has(m.status)) {
      m.lifecycle.timing.ended_ms = Math.max(0, Date.now() - Date.parse(m.created_at));
      m.lifecycle.summary.player_reported_played_ms = next.played_ms;
      m.lifecycle.summary.error_code = to !== "failed" ? null : reason === "REJECTED" ? "REJECTED" : "SYNTH_FAILED";
    }
    return persist(entry, m);
  });
}
export function saveSpeakGenerated(context: Context, generated: SpeechRecord["generated"][number]): SpeakStoreResult {
  return boundary(() => {
    const entry = location(context.id), m = current(entry, context);
    const item = speechSchema.shape.generated.element.parse(generated);
    check(m.artifacts.some(a => a.relative_path === item.audio_path), "INVALID_INPUT");
    m.speech ??= speechFromLegacy(m);
    m.speech.generated = m.speech.generated.filter(g => g.index !== item.index);
    m.speech.generated.push(item); m.speech.generated.sort((a, b) => a.index - b.index);
    return persist(entry, m);
  });
}
export function saveSpeakProjection(context: Context, projection: {
  display: string; spoken: string; normalization: z.infer<typeof normalization>; chunks: SpeakChunks;
}): SpeakStoreResult {
  return boundary(() => {
    const entry = location(context.id);
    const m = current(entry, context);
    const p = z.object({ display: text, spoken: text, normalization, chunks }).parse(projection);
    // Projection text is immutable once published; chunk state can progress after Stop.
    const files = [["display.txt", Buffer.from(p.display)], ["spoken.txt", Buffer.from(p.spoken)], ["chunks.json", encode(p.chunks)]] as const;
    for (const [name, bytes] of files) {
      if (name !== "chunks.json") {
        const sha256 = digest(bytes);
        check(m.projections.every(p => p.name !== name || p.sha256 === sha256), "CONFLICT");
        try { check(read(join(entry, name)).equals(bytes), "CONFLICT"); } catch (e) { if (!absent(e)) throw e; }
      }
    }
    for (const [name, bytes] of files) {
      publish(entry, name, bytes);
      m.projections = [...m.projections.filter(p => p.name !== name), { name, sha256: digest(bytes) }];
    }
    m.totals.chunk_count = p.chunks.length; m.normalization = p.normalization; return persist(entry, m);
  });
}
export function saveSpeakArtifact(context: Context, input: {
  bytes: Uint8Array; role: "playback_ready" | "provider_output"; mime: z.infer<typeof artifact>["mime"];
  duration_ms: number | null; sample_rate: number | null; channels: number | null; debug_provider_bytes?: boolean;
}): SpeakStoreResult {
  return boundary(() => {
    const entry = location(context.id);
    const m = current(entry, context), bytes = Buffer.from(input.bytes), sha256 = digest(bytes);
    const a = artifact.parse({ ...input, bytes: bytes.length, sha256, id: sha256, relative_path: null });
    check(bytes.length > 0 && a.role !== "unknown" && (a.role !== "playback_ready" || a.mime === "audio/mpeg"), "INVALID_INPUT");
    if (a.role === "playback_ready" || input.debug_provider_bytes === true) {
      const audio = join(entry, "audio");
      try { fs.mkdirSync(audio, { mode: 0o700 }); } catch (e) { if (!(typeof e === "object" && e !== null && "code" in e && e.code === "EEXIST")) throw e; }
      privateStat(fs.lstatSync(audio), true);
      // EEXIST may be a retry after mkdir succeeded but its parent sync failed.
      try { sync(entry); } catch { throw new Failure("SYNC_UNCERTAIN"); }
      const name = sha256 + (a.mime === "audio/mpeg" ? ".mp3" : ".wav");
      try {
        check(read(join(audio, name)).equals(bytes), "CONFLICT");
        // Matching bytes do not settle an earlier post-rename directory-sync failure.
        try { sync(audio); } catch { throw new Failure("SYNC_UNCERTAIN"); }
      }
      catch (e) { if (!absent(e)) throw e; publish(audio, name, bytes); }
      a.relative_path = "audio/" + name;
    }
    // A late completed generation is retained even after stopped/failed; no playback is triggered.
    const existing = m.artifacts.find(old => old.id === a.id && old.role === a.role);
    if (existing?.relative_path && a.relative_path === null) a.relative_path = existing.relative_path;
    m.artifacts = [...m.artifacts.filter(old => !(old.id === a.id && old.role === a.role)), a];
    return persist(entry, m);
  });
}

/** Caller invokes only after the previous writer has stopped. Never opens a journal for writing. */
export function recoverSpeakArchive(id: string): SpeakStoreResult {
  return boundary(() => {
    const entry = location(id);
    const input = read(join(entry, "input.txt"));
    let journal: Buffer = Buffer.alloc(0);
    try { journal = read(join(entry, "events.ndjson")); } catch (e) { if (!absent(e)) throw e; }
    const end = journal.lastIndexOf(10) + 1, lines = journal.subarray(0, end).toString("utf8").split("\n").slice(0, -1);
    const requestIds = lines.map((line, index) => {
      let decoded: unknown;
      try { decoded = JSON.parse(line); } catch { throw new Failure("CORRUPT_METADATA"); }
      const record = z.object({ seq: z.literal(index + 1), request_id: z.string() }).safeParse(decoded);
      check(record.success, "CORRUPT_METADATA");
      return record.data.request_id;
    });
    let m: SpeakStoreMetadata, missing = false;
    try { m = load(entry); }
    catch (e) {
      if (!absent(e)) throw e; missing = true;
      const created_at = id.slice(0, 23).replace(/T(\d\d)-(\d\d)-(\d\d)-(\d{3})$/, "T$1:$2:$3.$4") + "Z";
      m = metadata.parse({ schema_version: 1, source: "speak", id, created_at, updated_at: created_at,
        request_id: requestIds[0] ?? null, request_source: null, connection: null, format: null, blocking: null,
        requested: { mode: null, profile: null, engine: null, voice: null, rate: null },
        build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null },
        input: { bytes: input.length, sha256: digest(input) }, status: "received", generation_id: null });
    }
    check(m.id === id && m.created_at.replace(/[:.]/g, "-") === id.slice(0, 24) &&
      m.input.sha256 === digest(input) && m.input.bytes === input.length, "CORRUPT_METADATA");
    const before = encode(m); // Outcome alone is not a reconciliation/durability checkpoint.
    const finished = terminal.has(m.status);
    check(requestIds.every(request_id => request_id === m.request_id), "CORRUPT_METADATA");
    let audio: string[] = [], audioExists = false;
    try { privateStat(fs.lstatSync(join(entry, "audio")), true); audio = fs.readdirSync(join(entry, "audio")); audioExists = true; }
    catch (e) { if (!absent(e)) throw e; }
    for (const name of audio) if (!name.startsWith(".")) {
      check(/^[a-f0-9]{64}\.(mp3|wav)$/.test(name) && digest(read(join(entry, "audio", name))) === name.slice(0, 64), "CORRUPT_METADATA");
    }
    for (const a of m.artifacts) if (a.relative_path !== null) {
      check(a.relative_path === "audio/" + a.sha256 + (a.mime === "audio/mpeg" ? ".mp3" : ".wav"), "CORRUPT_METADATA");
      if (!audio.includes(a.relative_path.slice(6))) a.relative_path = null; // Hash retained; bytes unavailable.
    }
    for (const name of ["display.txt", "spoken.txt", "chunks.json"] as const) {
      try {
        const bytes = read(join(entry, name));
        if (name === "chunks.json") {
          try { m.totals.chunk_count = chunks.parse(JSON.parse(bytes.toString("utf8"))).length; }
          catch { throw new Failure("CORRUPT_METADATA"); }
        }
        const sha256 = digest(bytes);
        check(name === "chunks.json" || m.projections.every(p => p.name !== name || p.sha256 === sha256), "CORRUPT_METADATA");
        m.projections = [...m.projections.filter(p => p.name !== name), { name, sha256 }];
      } catch (e) { if (!absent(e)) throw e; }
    }
    const orphanAudio = audio.filter(name => !name.startsWith(".") && !m.artifacts.some(a => a.relative_path === "audio/" + name));
    m.recovery = { metadata_missing: missing || m.recovery?.metadata_missing === true,
      journal_complete_lines: lines.length, torn_tail_bytes: journal.length - end,
      orphan_audio: [...new Set([...(m.recovery?.orphan_audio ?? []), ...orphanAudio])].sort(),
      partial_files: [...fs.readdirSync(entry).filter(n => n.startsWith(".")), ...audio.filter(n => n.startsWith(".")).map(n => "audio/" + n)].sort() };
    for (const name of orphanAudio) {
      const bytes = read(join(entry, "audio", name)), sha256 = digest(bytes);
      m.artifacts.push({ id: sha256, sha256, bytes: bytes.length, relative_path: "audio/" + name,
        role: "unknown", mime: name.endsWith(".mp3") ? "audio/mpeg" : "audio/wav", duration_ms: null, sample_rate: null, channels: null });
    }
    if (m.speech && legalRecovery(m.speech)) {
      m.speech = transitionSpeech({ ...m.speech, playing_since: null }, "interrupted", "PROCESS_RESTART", new Date().toISOString()) ?? m.speech;
    }
    if (!finished) { m.status = "interrupted_unknown"; if (m.lifecycle) m.lifecycle.status = "interrupted_unknown"; }
    try {
      if (audioExists) sync(join(entry, "audio"));
      if (before.equals(encode(m))) { sync(entry); return m; }
    } catch { throw new Failure("SYNC_UNCERTAIN"); }
    return persist(entry, m);
  });
}

function legalRecovery(speech: SpeechRecord): boolean { return ["requested", "preparing", "playing", "paused"].includes(speech.state); }

function speechStateForStatus(status: SpeakStoreMetadata["status"]): SpeechState {
  switch (status) {
    case "received": return "requested";
    case "rejected": return "failed";
    case "replaced": return "stopped";
    case "interrupted_unknown": return "interrupted";
    default: return status;
  }
}
// Import an old snapshot without fabricating historical transitions or player time.
function speechFromLegacy(m: SpeakStoreMetadata): SpeechRecord {
  return { ...initialSpeech(), state: speechStateForStatus(m.status), reason: m.status === "rejected" ? "REJECTED" : null };
}
