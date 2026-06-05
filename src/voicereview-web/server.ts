import { dlopen, FFIType } from "bun:ffi";
import { mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { initEnrichedPATH, resolveBinary } from "../resolve-binary";

export type ReviewAction = "merge" | "keep" | "mixed" | "skip";
export type MemberDecision = "merge" | "keep" | "prune";

export interface ReviewMember {
  id: string;
  name: string;
  type: string;
  chunks: number;
}

export interface ReviewCluster {
  cluster_id: string;
  category: string;
  stem: string;
  size: number;
  members: ReviewMember[];
}

export interface VoiceDecision {
  action: ReviewAction;
  canonical_id?: string;
  members?: Record<string, MemberDecision>;
  note: string;
  source: "voice";
}

export interface CommandCall {
  args: string[];
  cwd: string;
  env: Record<string, string>;
}

export interface CommandResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  durationMs: number;
}

export interface VoiceReviewConfig {
  port: number;
  hostname: string;
  defaultCategory: string;
  brainlayerWorktree: string;
  batchPath: string;
  decisionsPath: string;
  sttVocabularyPath: string;
  ffmpegPath: string | null;
  whisperCliPath: string | null;
  whisperModelPath: string;
  liteRtUrl: string;
  liteRtModel: string;
  tempDir: string;
  ttsVoice: string;
  requestTimeoutMs: number;
}

export const KG_FLAG_DECISIONS_SCHEMA = "kg-flag-decisions-v1";

type FetchLike = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

type CommandRunner = (call: CommandCall) => Promise<CommandResult>;
type DecisionFileLocker = <T>(
  decisionsPath: string,
  work: () => Promise<T>,
) => Promise<T>;

const HOME = homedir();

export const DEFAULT_CONFIG: VoiceReviewConfig = {
  port: Number(process.env.VOICE_REVIEW_WEB_PORT || "8849"),
  hostname: process.env.VOICE_REVIEW_WEB_HOST || "127.0.0.1",
  defaultCategory: process.env.VOICE_REVIEW_CATEGORY || "diagnosis-flag",
  brainlayerWorktree:
    process.env.VOICE_REVIEW_BRAINLAYER_WT || "/tmp/voice-review-wt",
  batchPath:
    process.env.VOICE_REVIEW_BATCH ||
    join(
      HOME,
      "Gits/brainlayer/eval_results/kg-phase1-flag-batch-2026-06-05.json",
    ),
  decisionsPath:
    process.env.VOICE_REVIEW_DECISIONS ||
    join(
      HOME,
      "Gits/brainlayer/eval_results/kg-phase1-decisions-2026-06-05.json",
    ),
  sttVocabularyPath:
    process.env.VOICE_REVIEW_STT_VOCAB ||
    join(HOME, ".local/state/voicelayer/stt-vocabulary.json"),
  ffmpegPath:
    process.env.VOICE_REVIEW_FFMPEG ||
    resolveBinary("ffmpeg", ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]),
  whisperCliPath:
    process.env.VOICE_REVIEW_WHISPER_CLI ||
    resolveBinary("whisper-cli", [
      "/opt/homebrew/bin/whisper-cli",
      "/usr/local/bin/whisper-cli",
    ]),
  whisperModelPath:
    process.env.VOICE_REVIEW_WHISPER_MODEL ||
    join(HOME, ".cache/whisper/ggml-large-v3-turbo.bin"),
  liteRtUrl:
    process.env.VOICE_REVIEW_LITERT_URL ||
    "http://127.0.0.1:9379/v1/chat/completions",
  liteRtModel: process.env.VOICE_REVIEW_LITERT_MODEL || "gemma4-e4b,gpu",
  tempDir: process.env.VOICE_REVIEW_TEMP_DIR || join(tmpdir(), "voicereview-web"),
  ttsVoice: process.env.VOICE_REVIEW_TTS_VOICE || "en-US-AriaNeural",
  requestTimeoutMs: Number(process.env.VOICE_REVIEW_TIMEOUT_MS || "60000"),
};

export function mergeConfig(
  overrides?: Partial<VoiceReviewConfig>,
): VoiceReviewConfig {
  return { ...DEFAULT_CONFIG, ...overrides };
}

export function buildDriverArgs(
  command: "next" | "record" | "stats",
  options: {
    pythonBinary?: string;
    pythonScript: string;
    batchPath: string;
    decisionsPath: string;
    category?: string;
    clusterId?: string;
    decisionJson?: string;
  },
): string[] {
  const args = [options.pythonBinary || "python3", options.pythonScript, command];

  if (command === "next") {
    args.push("--batch", options.batchPath, "--decisions", options.decisionsPath);
    if (options.category) args.push("--category", options.category);
    return args;
  }

  if (command === "stats") {
    args.push("--batch", options.batchPath, "--decisions", options.decisionsPath);
    return args;
  }

  if (!options.clusterId || !options.decisionJson) {
    throw new Error("record requires clusterId and decisionJson");
  }
  args.push(
    "--batch",
    options.batchPath,
    "--decisions",
    options.decisionsPath,
    "--cluster-id",
    options.clusterId,
    "--decision-json",
    options.decisionJson,
  );
  return args;
}

export function buildWhisperPrompt(
  terms: unknown[],
  maxTokens = 224,
): string {
  const selected: string[] = [];
  let tokens = 0;
  for (const term of terms) {
    if (typeof term !== "string") continue;
    const clean = term.replace(/\s+/g, " ").trim();
    if (!clean) continue;
    const termTokens = clean.split(/\s+/).length;
    if (tokens + termTokens > maxTokens) continue;
    const candidate = [...selected, clean].join(" ");
    if (candidate.length > 900) break;
    selected.push(clean);
    tokens += termTokens;
  }
  return selected.join(" ");
}

export function buildWhisperArgs(options: {
  binary: string;
  modelPath: string;
  wavPath: string;
  prompt: string;
}): string[] {
  const args = [
    options.binary,
    "-m",
    options.modelPath,
    "-f",
    options.wavPath,
    "--no-timestamps",
  ];
  if (options.prompt.trim()) args.push("--prompt", options.prompt.trim());
  args.push("--no-prints");
  return args;
}

export function buildInterpretMessages(options: {
  transcript: string;
  cluster: ReviewCluster;
}): Array<{ role: "system" | "user"; content: string }> {
  const system = [
    "STRICT KG voice-review interpreter.",
    "Map one free-form spoken reviewer answer to exactly one JSON object.",
    "Allowed action values: merge|keep|mixed|skip.",
    "For merge, canonical_id must be one id from cluster.members.",
    "For keep and skip, omit canonical_id and members.",
    "For mixed, members must map member id to merge|keep|prune.",
    "Every action must carry note equal to the verbatim transcript.",
    "If the transcript is ambiguous or non-deterministic, choose skip with the verbatim transcript as note. Never force a clean merge/keep/mixed disposition from unclear speech.",
    "Return exactly one JSON object. No markdown, no prose.",
    "",
    "few-shot examples:",
    'Transcript: "merge them all, the company one is the real one"',
    '{"action":"merge","canonical_id":"<company-member-id>","note":"merge them all, the company one is the real one"}',
    'Transcript: "keep these separate"',
    '{"action":"keep","note":"keep these separate"}',
    'Transcript: "mixed, merge the tool and project, prune the person"',
    '{"action":"mixed","members":{"<tool-id>":"merge","<project-id>":"merge","<person-id>":"prune"},"note":"mixed, merge the tool and project, prune the person"}',
    'Transcript: "I am not sure, maybe this is one thing but maybe not"',
    '{"action":"skip","note":"I am not sure, maybe this is one thing but maybe not"}',
  ].join("\n");

  const memberLines = options.cluster.members
    .map(
      (member) =>
        `- ${member.id}: ${member.name} (${member.type}, ${member.chunks} chunks)`,
    )
    .join("\n");
  const user = [
    `Cluster: ${options.cluster.cluster_id}`,
    `Stem: ${options.cluster.stem}`,
    `Category: ${options.cluster.category}`,
    "Members:",
    memberLines,
    `Transcript: ${JSON.stringify(options.transcript)}`,
  ].join("\n");

  return [
    { role: "system", content: system },
    { role: "user", content: user },
  ];
}

export function parseInterpretDecision(
  rawContent: string,
  cluster: ReviewCluster,
  transcript: string,
): VoiceDecision {
  const parsed = parseJsonObject(rawContent);
  if (!isRecord(parsed)) throw new Error("LiteRT response was not an object");

  const action = normalizeInterpretAction(parsed.action);

  const memberIds = new Set(cluster.members.map((member) => member.id));
  const decision: VoiceDecision = {
    action,
    note: transcript.trim(),
    source: "voice",
  };

  if (action === "merge") {
    if (typeof parsed.canonical_id !== "string") {
      throw new Error("merge interpretation requires canonical_id");
    }
    if (!memberIds.has(parsed.canonical_id)) {
      throw new Error("canonical_id is not a member of this cluster");
    }
    decision.canonical_id = parsed.canonical_id;
  }

  if (action === "mixed") {
    if (!isRecord(parsed.members)) {
      throw new Error("mixed interpretation requires members object");
    }
    const members: Record<string, MemberDecision> = {};
    for (const [id, value] of Object.entries(parsed.members)) {
      if (!memberIds.has(id)) throw new Error(`unknown member id: ${id}`);
      if (value !== "merge" && value !== "keep" && value !== "prune") {
        throw new Error(`invalid mixed member action for ${id}`);
      }
      members[id] = value;
    }
    if (Object.keys(members).length !== memberIds.size) {
      throw new Error("mixed interpretation requires every cluster member");
    }
    decision.members = members;
  }

  return decision;
}

export function buildConfirmation(
  decision: VoiceDecision,
  cluster: ReviewCluster,
): string {
  if (decision.action === "merge") {
    const canonical = cluster.members.find(
      (member) => member.id === decision.canonical_id,
    );
    if (canonical) return `Merge all into ${canonical.name}, ${canonical.type}.`;
    return "Merge all into the selected canonical entity.";
  }
  if (decision.action === "keep") return "Keep all entries separate.";
  if (decision.action === "mixed") return "Record the mixed member decision.";
  return "Skip this cluster.";
}

export function legacyDecisionsToKgFlagV1(
  data: unknown,
  clusters: ReviewCluster[],
  source: string,
): Record<string, unknown> | null {
  if (!isRecord(data)) return null;
  if (data.schema === KG_FLAG_DECISIONS_SCHEMA) return null;
  if (data.version !== 1 || !isRecord(data.decisions)) return null;

  const migrated: Record<string, unknown> = {
    schema: KG_FLAG_DECISIONS_SCHEMA,
    source,
    rules: {},
    per_category: {},
    counts: {
      merge_clusters: 0,
      rows_merged_away: 0,
      keep: 0,
      explicit: 0,
      by_rule: 0,
    },
    merge: [],
    keep: [],
  };

  const byClusterId = new Map(clusters.map((cluster) => [cluster.cluster_id, cluster]));
  for (const [clusterId, rawDecision] of Object.entries(data.decisions)) {
    if (!isRecord(rawDecision)) continue;
    const cluster = byClusterId.get(clusterId);
    if (!cluster) {
      throw new Error(`legacy decision references unknown cluster ${clusterId}`);
    }
    const action = normalizeLegacyAction(rawDecision.action);
    const sourceValue = normalizeLegacySource(rawDecision.source);
    const note =
      typeof rawDecision.note === "string" && rawDecision.note.trim()
        ? rawDecision.note.trim()
        : undefined;
    const decidedAt =
      typeof rawDecision.decided_at === "string"
        ? rawDecision.decided_at
        : new Date().toISOString();

    if (action === "merge") {
      const canonical = selectCanonicalMember(cluster, rawDecision.canonical_id);
      const item: Record<string, unknown> = {
        stem: cluster.stem,
        category: cluster.category,
        source: sourceValue,
        canonical: memberRef(canonical),
        members: cluster.members
          .filter((member) => member.id !== canonical.id)
          .map(memberRef),
        decided_at: decidedAt,
      };
      if (note) item.note = note;
      (migrated.merge as unknown[]).push(item);
      continue;
    }

    if (action === "skip") {
      const item: Record<string, unknown> = {
        stem: cluster.stem,
        category: cluster.category,
        source: sourceValue,
        decided_at: decidedAt,
      };
      if (note) item.note = note;
      if (!Array.isArray(migrated.skipped)) migrated.skipped = [];
      (migrated.skipped as unknown[]).push(item);
      continue;
    }

    const item: Record<string, unknown> = {
      stem: cluster.stem,
      category: cluster.category,
      source: sourceValue,
      decided_at: decidedAt,
    };
    if (note) item.note = note;
    (migrated.keep as unknown[]).push(item);
  }

  recomputeKgFlagRollups(migrated, clusters);
  return migrated;
}

export function createVoiceReviewApp(options?: {
  config?: Partial<VoiceReviewConfig>;
  runCommand?: CommandRunner;
  fetchImpl?: FetchLike;
  lockDecisionFile?: DecisionFileLocker;
}): { fetch: (request: Request) => Promise<Response> } {
  const config = mergeConfig(options?.config);
  const runCommand = options?.runCommand || runShellCommand;
  const fetchImpl = options?.fetchImpl || fetch;
  const lockDecisionFile = options?.lockDecisionFile || withDecisionFileLock;

  return {
    fetch: async (request: Request): Promise<Response> => {
      try {
        const url = new URL(request.url);
        if (request.method === "GET" && url.pathname === "/") {
          return htmlResponse(renderPage(config.defaultCategory));
        }
        if (request.method === "GET" && url.pathname === "/api/next") {
          return await handleNext(url, config, runCommand, lockDecisionFile);
        }
        if (request.method === "GET" && url.pathname === "/api/stats") {
          return await handleStats(config, runCommand, lockDecisionFile);
        }
        if (request.method === "POST" && url.pathname === "/api/decide") {
          return await handleDecide(request, config, runCommand, lockDecisionFile);
        }
        if (request.method === "POST" && url.pathname === "/api/interpret") {
          return await handleInterpret(request, config, fetchImpl);
        }
        if (request.method === "POST" && url.pathname === "/api/transcribe") {
          return await handleTranscribe(request, config, runCommand);
        }
        if (request.method === "POST" && url.pathname === "/api/tts") {
          return await handleTts(request, config, runCommand);
        }
        return jsonResponse({ error: "not found" }, 404);
      } catch (error) {
        return jsonResponse({ error: errorMessage(error) }, 500);
      }
    },
  };
}

async function handleNext(
  url: URL,
  config: VoiceReviewConfig,
  runCommand: CommandRunner,
  lockDecisionFile: DecisionFileLocker,
): Promise<Response> {
  await ensureDecisionFileCompatible(config, lockDecisionFile);
  const category = url.searchParams.get("category") || config.defaultCategory;
  const result = await runCommand({
    args: buildDriverArgs("next", {
      pythonScript: driverScript(config),
      batchPath: config.batchPath,
      decisionsPath: config.decisionsPath,
      category,
    }),
    cwd: config.brainlayerWorktree,
    env: driverEnv(config),
  });
  const payload = parseDriverRecord(result);
  return jsonResponse({ ...payload, timings: { driver_ms: result.durationMs } });
}

async function handleStats(
  config: VoiceReviewConfig,
  runCommand: CommandRunner,
  lockDecisionFile: DecisionFileLocker,
): Promise<Response> {
  await ensureDecisionFileCompatible(config, lockDecisionFile);
  const result = await runCommand({
    args: buildDriverArgs("stats", {
      pythonScript: driverScript(config),
      batchPath: config.batchPath,
      decisionsPath: config.decisionsPath,
    }),
    cwd: config.brainlayerWorktree,
    env: driverEnv(config),
  });
  const stats = parseDriverJson(result);
  const decisions = await loadDecisionsJson(config.decisionsPath);
  return jsonResponse({
    stats: decorateStatsWithSkippedCounts(stats, decisions),
    timings: { driver_ms: result.durationMs },
  });
}

async function handleDecide(
  request: Request,
  config: VoiceReviewConfig,
  runCommand: CommandRunner,
  lockDecisionFile: DecisionFileLocker,
): Promise<Response> {
  const body = await request.json();
  if (!isRecord(body) || typeof body.cluster_id !== "string") {
    return jsonResponse({ error: "cluster_id is required" }, 400);
  }
  if (!isRecord(body.decision)) {
    return jsonResponse({ error: "decision object is required" }, 400);
  }

  await ensureDecisionFileCompatible(config, lockDecisionFile);
  const decision = { ...body.decision, source: "voice" };
  const result = await runCommand({
    args: buildDriverArgs("record", {
      pythonScript: driverScript(config),
      batchPath: config.batchPath,
      decisionsPath: config.decisionsPath,
      clusterId: body.cluster_id,
      decisionJson: JSON.stringify(decision),
    }),
    cwd: config.brainlayerWorktree,
    env: driverEnv(config),
  });
  return jsonResponse({
    ...parseDriverRecord(result),
    timings: { driver_ms: result.durationMs },
  });
}

async function handleInterpret(
  request: Request,
  config: VoiceReviewConfig,
  fetchImpl: FetchLike,
): Promise<Response> {
  const body = await request.json();
  if (
    !isRecord(body) ||
    typeof body.transcript !== "string" ||
    !isReviewCluster(body.cluster)
  ) {
    return jsonResponse({ error: "transcript and cluster are required" }, 400);
  }

  const started = performance.now();
  const messages = buildInterpretMessages({
    transcript: body.transcript,
    cluster: body.cluster,
  });
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.requestTimeoutMs);
  try {
    const response = await fetchImpl(config.liteRtUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: config.liteRtModel,
        messages,
        temperature: 0,
        max_tokens: 256,
        stream: false,
      }),
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new Error(`LiteRT-LM failed: ${response.status} ${response.statusText}`);
    }
    const raw = await response.json();
    const content = extractChatContent(raw);
    const decision = parseInterpretDecision(content, body.cluster, body.transcript);
    return jsonResponse({
      decision,
      confirmation: buildConfirmation(decision, body.cluster),
      timings: { llm_ms: Math.round(performance.now() - started) },
    });
  } finally {
    clearTimeout(timeout);
  }
}

async function handleTranscribe(
  request: Request,
  config: VoiceReviewConfig,
  runCommand: CommandRunner,
): Promise<Response> {
  const started = performance.now();
  const audio = await request.blob();
  if (audio.size === 0) return jsonResponse({ error: "empty audio" }, 400);

  const id = crypto.randomUUID();
  const inputPath = join(
    config.tempDir,
    `${id}.${extensionForContentType(request.headers.get("content-type"))}`,
  );
  const wavPath = join(config.tempDir, `${id}.wav`);
  await mkdir(config.tempDir, { recursive: true });
  await Bun.write(inputPath, audio);

  try {
    const ffmpeg = config.ffmpegPath;
    if (!ffmpeg) throw new Error("ffmpeg not found");

    const convert = await runCommand({
      args: [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        inputPath,
        "-ac",
        "1",
        "-ar",
        "16000",
        "-acodec",
        "pcm_s16le",
        wavPath,
      ],
      cwd: process.cwd(),
      env: processEnv(),
    });
    assertSuccess(convert, "ffmpeg");

    const whisper = config.whisperCliPath;
    if (!whisper) throw new Error("whisper-cli not found");

    const prompt = await loadVocabularyPrompt(config.sttVocabularyPath);
    const whisperResult = await runCommand({
      args: buildWhisperArgs({
        binary: whisper,
        modelPath: config.whisperModelPath,
        wavPath,
        prompt,
      }),
      cwd: process.cwd(),
      env: processEnv(),
    });
    assertSuccess(whisperResult, "whisper-cli");

    const text = cleanTranscript(whisperResult.stdout);
    if (!text) return jsonResponse({ error: "empty transcript" }, 422);

    return jsonResponse({
      text,
      timings: {
        convert_ms: convert.durationMs,
        whisper_ms: whisperResult.durationMs,
        total_ms: Math.round(performance.now() - started),
      },
    });
  } finally {
    await Promise.allSettled([rm(inputPath, { force: true }), rm(wavPath, { force: true })]);
  }
}

async function handleTts(
  request: Request,
  config: VoiceReviewConfig,
  runCommand: CommandRunner,
): Promise<Response> {
  const body = await request.json();
  if (!isRecord(body) || typeof body.text !== "string" || !body.text.trim()) {
    return jsonResponse({ error: "text is required" }, 400);
  }
  const started = performance.now();
  const id = crypto.randomUUID();
  const mp3Path = join(config.tempDir, `${id}.mp3`);
  await mkdir(config.tempDir, { recursive: true });
  try {
    const python = resolveBinary("python3", [
      "/opt/homebrew/bin/python3",
      "/usr/local/bin/python3",
      "/usr/bin/python3",
    ]);
    if (!python) throw new Error("python3 not found");
    const result = await runCommand({
      args: [
        python,
        "-m",
        "edge_tts",
        "--voice",
        config.ttsVoice,
        "--text",
        body.text.slice(0, 4000),
        "--write-media",
        mp3Path,
      ],
      cwd: process.cwd(),
      env: processEnv(),
    });
    assertSuccess(result, "edge-tts");
    const bytes = await readFile(mp3Path);
    return new Response(bytes, {
      status: 200,
      headers: {
        "content-type": "audio/mpeg",
        "cache-control": "no-store",
        "x-tts-ms": String(Math.round(performance.now() - started)),
      },
    });
  } finally {
    await rm(mp3Path, { force: true });
  }
}

async function runShellCommand(call: CommandCall): Promise<CommandResult> {
  const started = performance.now();
  const proc = Bun.spawn(call.args, {
    cwd: call.cwd,
    env: call.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return {
    exitCode,
    stdout,
    stderr,
    durationMs: Math.round(performance.now() - started),
  };
}

const FLOCK_EX = 2;
const FLOCK_UN = 8;
let flockFn: ((fd: number, operation: number) => number) | null = null;

export function decisionLockPath(decisionsPath: string): string {
  return `${decisionsPath}.lock`;
}

async function withDecisionFileLock<T>(
  decisionsPath: string,
  work: () => Promise<T>,
): Promise<T> {
  const lockPath = decisionLockPath(decisionsPath);
  await mkdir(dirname(lockPath), { recursive: true });
  const handle = await open(lockPath, "w");
  let locked = false;
  try {
    const flock = loadFlock();
    if (flock(handle.fd, FLOCK_EX) !== 0) {
      throw new Error(`failed to flock ${lockPath}`);
    }
    locked = true;
    return await work();
  } finally {
    if (locked) loadFlock()(handle.fd, FLOCK_UN);
    await handle.close();
  }
}

function loadFlock(): (fd: number, operation: number) => number {
  if (flockFn) return flockFn;
  const library =
    process.platform === "darwin"
      ? "/usr/lib/libSystem.B.dylib"
      : process.platform === "linux"
        ? "libc.so.6"
        : null;
  if (!library) throw new Error(`flock is unsupported on ${process.platform}`);
  const libc = dlopen(library, {
    flock: {
      args: [FFIType.i32, FFIType.i32],
      returns: FFIType.i32,
    },
  });
  flockFn = libc.symbols.flock;
  return flockFn;
}

async function ensureDecisionFileCompatible(
  config: VoiceReviewConfig,
  lockDecisionFile: DecisionFileLocker = withDecisionFileLock,
): Promise<void> {
  try {
    const preflight = JSON.parse(await readFile(config.decisionsPath, "utf8"));
    if (isRecord(preflight) && preflight.schema === KG_FLAG_DECISIONS_SCHEMA) return;
  } catch {
    return;
  }

  await lockDecisionFile(config.decisionsPath, async () => {
    let rawDecisions: string;
    try {
      rawDecisions = await readFile(config.decisionsPath, "utf8");
    } catch {
      return;
    }

    const parsed = JSON.parse(rawDecisions);
    if (isRecord(parsed) && parsed.schema === KG_FLAG_DECISIONS_SCHEMA) return;

    const rawBatch = await readFile(config.batchPath, "utf8");
    const clusters = flattenFlagBatch(JSON.parse(rawBatch));
    const migrated = legacyDecisionsToKgFlagV1(
      parsed,
      clusters,
      sourceFromBatchPath(config.batchPath),
    );
    if (!migrated) return;

    const tmpPath = `${config.decisionsPath}.web-migrate-${process.pid}.tmp`;
    await writeFile(tmpPath, JSON.stringify(migrated, null, 2));
    await rename(tmpPath, config.decisionsPath);
  });
}

async function loadDecisionsJson(decisionsPath: string): Promise<unknown> {
  try {
    return JSON.parse(await readFile(decisionsPath, "utf8"));
  } catch {
    return null;
  }
}

export function decorateStatsWithSkippedCounts(
  stats: unknown,
  decisions: unknown,
): unknown {
  if (!isRecord(stats) || !isRecord(stats.per_category)) return stats;
  const skippedByCategory = new Map<string, number>();
  const skipped = isRecord(decisions) && Array.isArray(decisions.skipped)
    ? decisions.skipped
    : [];
  for (const item of skipped) {
    if (!isRecord(item) || typeof item.category !== "string") continue;
    skippedByCategory.set(
      item.category,
      (skippedByCategory.get(item.category) || 0) + 1,
    );
  }
  const perCategory: Record<string, unknown> = {};
  for (const [category, bucket] of Object.entries(stats.per_category)) {
    if (!isRecord(bucket)) {
      perCategory[category] = bucket;
      continue;
    }
    perCategory[category] = {
      ...bucket,
      skipped: skippedByCategory.get(category) || 0,
    };
  }
  return { ...stats, per_category: perCategory };
}

async function loadVocabularyPrompt(path: string): Promise<string> {
  try {
    const raw = await readFile(path, "utf8");
    const parsed = JSON.parse(raw);
    const terms = isRecord(parsed) && Array.isArray(parsed.prompt_terms)
      ? parsed.prompt_terms
      : [];
    return buildWhisperPrompt(terms, 224);
  } catch {
    return buildWhisperPrompt(["VoiceLayer", "BrainLayer", "Cantaloupe AI"], 224);
  }
}

function flattenFlagBatch(raw: unknown): ReviewCluster[] {
  if (!isRecord(raw)) throw new Error("flag batch must be an object");
  const clusters: ReviewCluster[] = [];
  for (const [category, items] of Object.entries(raw)) {
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      if (!isRecord(item) || typeof item.stem !== "string") continue;
      const members = Array.isArray(item.members)
        ? item.members.filter(isReviewMember)
        : [];
      clusters.push({
        cluster_id: `${category}:${item.stem}`,
        category,
        stem: item.stem,
        size: typeof item.size === "number" ? item.size : members.length,
        members,
      });
    }
  }
  return clusters;
}

function isReviewMember(value: unknown): value is ReviewMember {
  return (
    isRecord(value) &&
    typeof value.id === "string" &&
    typeof value.name === "string" &&
    typeof value.type === "string" &&
    typeof value.chunks === "number"
  );
}

function sourceFromBatchPath(batchPath: string): string {
  const basename = batchPath.split("/").pop() || "kg-phase1-flag-batch-2026-06-05.json";
  return basename.replace(/\.json$/i, "");
}

function normalizeLegacyAction(action: unknown): "merge" | "keep" | "skip" {
  if (action === "merge" || action === "merge_all") return "merge";
  if (action === "keep" || action === "keep_all" || action === "mixed") {
    return "keep";
  }
  if (action === "skip") return "skip";
  throw new Error(`invalid legacy action ${String(action)}`);
}

function normalizeInterpretAction(action: unknown): ReviewAction {
  if (action === "merge" || action === "merge_all") return "merge";
  if (action === "keep" || action === "keep_all") return "keep";
  if (action === "mixed" || action === "skip") return action;
  throw new Error(`invalid interpreted action: ${String(action)}`);
}

function normalizeLegacySource(source: unknown): "voice" | "explicit" | "rule" | "voice-rule" {
  if (source === "visual") return "explicit";
  if (
    source === "voice" ||
    source === "explicit" ||
    source === "rule" ||
    source === "voice-rule"
  ) {
    return source;
  }
  return "voice";
}

function selectCanonicalMember(
  cluster: ReviewCluster,
  canonicalId: unknown,
): ReviewMember {
  if (typeof canonicalId === "string") {
    const canonical = cluster.members.find((member) => member.id === canonicalId);
    if (canonical) return canonical;
    throw new Error(`canonical_id ${canonicalId} is not in ${cluster.cluster_id}`);
  }
  const first = cluster.members[0];
  if (!first) throw new Error(`cluster ${cluster.cluster_id} has no members`);
  return first;
}

function memberRef(member: ReviewMember): Record<string, string> {
  return { id: member.id, name: member.name, type: member.type };
}

function recomputeKgFlagRollups(
  data: Record<string, unknown>,
  clusters: ReviewCluster[],
): void {
  const perCategory: Record<string, Record<string, unknown>> = {};
  for (const cluster of clusters) {
    const row = perCategory[cluster.category] || {
      total: 0,
      explicit: 0,
      by_rule: 0,
      undecided: 0,
      rule: undefined,
    };
    row.total = Number(row.total) + 1;
    perCategory[cluster.category] = row;
  }

  const merge = Array.isArray(data.merge) ? data.merge.filter(isRecord) : [];
  const keep = Array.isArray(data.keep) ? data.keep.filter(isRecord) : [];
  for (const item of [...merge, ...keep]) {
    if (typeof item.category !== "string") continue;
    const row = perCategory[item.category] || {
      total: 0,
      explicit: 0,
      by_rule: 0,
      undecided: 0,
      rule: undefined,
    };
    if (item.source === "rule" || item.source === "voice-rule") {
      row.by_rule = Number(row.by_rule) + 1;
    } else {
      row.explicit = Number(row.explicit) + 1;
    }
    perCategory[item.category] = row;
  }

  for (const row of Object.values(perCategory)) {
    row.undecided =
      Number(row.total) - Number(row.explicit) - Number(row.by_rule);
    if (row.rule === undefined) delete row.rule;
  }

  data.per_category = perCategory;
  data.counts = {
    merge_clusters: merge.length,
    rows_merged_away: merge.reduce((sum, item) => {
      const members = Array.isArray(item.members) ? item.members.length : 0;
      return sum + members;
    }, 0),
    keep: keep.length,
    explicit: [...merge, ...keep].filter(
      (item) => item.source !== "rule" && item.source !== "voice-rule",
    ).length,
    by_rule: [...merge, ...keep].filter(
      (item) => item.source === "rule" || item.source === "voice-rule",
    ).length,
  };
}

function parseDriverJson(result: CommandResult): unknown {
  assertSuccess(result, "kg_review_session.py");
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`driver returned invalid JSON: ${errorMessage(error)}`);
  }
}

function parseDriverRecord(result: CommandResult): Record<string, unknown> {
  const parsed = parseDriverJson(result);
  if (!isRecord(parsed)) throw new Error("driver returned non-object JSON");
  return parsed;
}

function assertSuccess(result: CommandResult, label: string): void {
  if (result.exitCode !== 0) {
    throw new Error(
      `${label} failed with exit ${result.exitCode}: ${result.stderr.slice(0, 800)}`,
    );
  }
}

function extractChatContent(raw: unknown): string {
  if (!isRecord(raw)) throw new Error("LiteRT response was not JSON object");
  const choices = raw.choices;
  if (!Array.isArray(choices) || choices.length === 0) {
    throw new Error("LiteRT response missing choices");
  }
  const first = choices[0];
  if (!isRecord(first)) throw new Error("LiteRT choice was not object");
  if (typeof first.text === "string") return first.text;
  const message = first.message;
  if (isRecord(message) && typeof message.content === "string") {
    return message.content;
  }
  throw new Error("LiteRT response missing message content");
}

function parseJsonObject(raw: string): unknown {
  const trimmed = raw.trim();
  const unfenced = trimmed
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/i, "")
    .trim();
  const start = unfenced.indexOf("{");
  const end = unfenced.lastIndexOf("}");
  if (start < 0 || end < start) throw new Error("no JSON object in response");
  return JSON.parse(unfenced.slice(start, end + 1));
}

function cleanTranscript(stdout: string): string {
  return stdout
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" ")
    .trim();
}

function driverScript(config: VoiceReviewConfig): string {
  return join(config.brainlayerWorktree, "scripts/kg_review_session.py");
}

function driverEnv(config: VoiceReviewConfig): Record<string, string> {
  return { ...processEnv(), PYTHONPATH: join(config.brainlayerWorktree, "src") };
}

function processEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (typeof value === "string") env[key] = value;
  }
  return env;
}

function extensionForContentType(contentType: string | null): string {
  const value = contentType || "";
  if (value.includes("wav")) return "wav";
  if (value.includes("mp4")) return "m4a";
  if (value.includes("ogg")) return "ogg";
  return "webm";
}

function isReviewCluster(value: unknown): value is ReviewCluster {
  if (!isRecord(value)) return false;
  return (
    typeof value.cluster_id === "string" &&
    typeof value.category === "string" &&
    typeof value.stem === "string" &&
    Array.isArray(value.members) &&
    value.members.every(isReviewMember)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function htmlResponse(html: string): Response {
  return new Response(html, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function renderPage(defaultCategory: string): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>KG Voice Review</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f7f8fa;
      --panel: #ffffff;
      --ink: #172026;
      --muted: #5a6872;
      --line: #d9e0e5;
      --accent: #0f766e;
      --accent-ink: #ffffff;
      --warn: #9a3412;
      --ok: #166534;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--ink);
      letter-spacing: 0;
    }
    header {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 16px;
      align-items: end;
      padding: 24px clamp(16px, 3vw, 36px) 18px;
      border-bottom: 1px solid var(--line);
      background: #ffffff;
    }
    h1, h2, p { margin: 0; }
    h1 { font-size: clamp(24px, 3vw, 34px); font-weight: 700; }
    .sub { margin-top: 6px; color: var(--muted); font-size: 14px; }
    .top-controls { display: flex; gap: 10px; align-items: center; }
    select, button {
      font: inherit;
      border: 1px solid var(--line);
      background: #ffffff;
      color: var(--ink);
      border-radius: 8px;
    }
    select { padding: 10px 12px; min-width: 190px; }
    main {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(280px, 360px);
      gap: 18px;
      padding: 18px clamp(16px, 3vw, 36px);
      max-width: 1180px;
      margin: 0 auto;
    }
    section {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
    }
    .cluster { padding: 18px; min-width: 0; }
    .cluster-head {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      align-items: start;
      margin-bottom: 16px;
    }
    .cluster-id {
      color: var(--muted);
      font-size: 13px;
      overflow-wrap: anywhere;
    }
    h2 { font-size: clamp(24px, 4vw, 42px); line-height: 1.05; margin-top: 3px; }
    .badge {
      flex: none;
      padding: 5px 9px;
      border-radius: 999px;
      background: #e6f3f1;
      color: #0f5f59;
      font-size: 12px;
      font-weight: 700;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
      font-size: 14px;
    }
    th, td {
      border-bottom: 1px solid var(--line);
      padding: 10px 8px;
      text-align: left;
      vertical-align: top;
      overflow-wrap: anywhere;
    }
    th { color: var(--muted); font-size: 12px; text-transform: uppercase; }
    .controls {
      padding: 18px;
      display: grid;
      gap: 16px;
      align-content: start;
    }
    .mic {
      width: min(100%, 300px);
      aspect-ratio: 1 / 1;
      justify-self: center;
      border-radius: 50%;
      border: 0;
      background: var(--accent);
      color: var(--accent-ink);
      font-size: clamp(24px, 4vw, 34px);
      font-weight: 800;
      cursor: pointer;
      box-shadow: 0 16px 30px rgba(15, 118, 110, 0.24);
    }
    .mic.recording { background: #b91c1c; box-shadow: 0 16px 30px rgba(185, 28, 28, 0.22); }
    .mic:disabled { opacity: 0.55; cursor: wait; }
    .status {
      min-height: 44px;
      color: var(--muted);
      font-size: 15px;
      line-height: 1.4;
    }
    .transcript, .decision {
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 12px;
      min-height: 62px;
      background: #fbfcfd;
      font-size: 14px;
      line-height: 1.4;
      overflow-wrap: anywhere;
    }
    footer {
      max-width: 1180px;
      margin: 0 auto;
      padding: 0 clamp(16px, 3vw, 36px) 24px;
      display: grid;
      gap: 10px;
      color: var(--muted);
      font-size: 13px;
    }
    .progress {
      height: 12px;
      border: 1px solid var(--line);
      background: #ffffff;
      border-radius: 999px;
      overflow: hidden;
    }
    .progress > div { height: 100%; width: 0%; background: var(--ok); transition: width 160ms ease; }
    .honesty {
      color: var(--warn);
      line-height: 1.35;
    }
    audio { display: none; }
    @media (max-width: 820px) {
      header { grid-template-columns: 1fr; align-items: start; }
      .top-controls { flex-wrap: wrap; }
      main { grid-template-columns: 1fr; }
      .mic { width: min(76vw, 260px); }
      table { font-size: 13px; }
    }
  </style>
</head>
<body>
  <header>
    <div>
      <h1>KG Voice Review</h1>
      <p class="sub">Mac/Helium localhost voice loop. Browser mic and browser speaker only; VoiceBar, F5, and CLI audio stay out of this path.</p>
    </div>
    <div class="top-controls">
      <select id="category" aria-label="Category">
        ${["diagnosis-flag", "sep-variants", "identical-name", "case-only", "prefix-variants"]
          .map(
            (category) =>
              `<option value="${category}"${category === defaultCategory ? " selected" : ""}>${category}</option>`,
          )
          .join("")}
      </select>
    </div>
  </header>

  <main>
    <section class="cluster" aria-live="polite">
      <div class="cluster-head">
        <div>
          <div id="clusterId" class="cluster-id">No cluster loaded</div>
          <h2 id="stem">Ready</h2>
        </div>
        <div id="categoryBadge" class="badge">${defaultCategory}</div>
      </div>
      <table>
        <thead><tr><th>Name</th><th>Type</th><th>Chunks</th><th>ID</th></tr></thead>
        <tbody id="members"><tr><td colspan="4">Tap Start.</td></tr></tbody>
      </table>
    </section>

    <section class="controls">
      <button id="mic" class="mic" type="button">Start</button>
      <div id="status" class="status">Tap Start once to allow the browser mic and load the next cluster.</div>
      <div id="transcript" class="transcript">Transcript appears here.</div>
      <div id="decision" class="decision">Decision appears here.</div>
    </section>
  </main>

  <footer>
    <div class="progress"><div id="progressFill"></div></div>
    <div id="progressText">Progress pending.</div>
    <div id="timings">Timings: record-stop to transcript -, transcript to decision -, total -.</div>
    <div class="honesty">Phone/tailnet is display-only tonight; Mac/Helium localhost is the supported voice surface.</div>
    <div class="honesty">TTS v0 uses /api/tts with edge-tts for audio element playback; cluster text leaves the Mac for that leg. STT and interpretation stay local.</div>
  </footer>

  <audio id="audio" preload="auto"></audio>

  <script>
    const $ = (id) => document.getElementById(id);
    const mic = $("mic");
    const category = $("category");
    const audio = $("audio");
    let stream = null;
    let recorder = null;
    let chunks = [];
    let current = null;
    let currentSpeak = "";
    let busy = false;
    let recording = false;
    let ttsPlaying = false;
    let activePlayback = null;

    function setStatus(text) { $("status").textContent = text; }
    function syncControlState() {
      mic.disabled = busy && !ttsPlaying;
      category.disabled = busy || recording;
    }
    function setBusy(value) {
      busy = value;
      syncControlState();
    }
    function setRecording(value) {
      recording = value;
      syncControlState();
    }
    function setTtsPlaying(value) {
      ttsPlaying = value;
      syncControlState();
    }
    function ms(value) { return Math.round(value) + " ms"; }

    async function api(path, options = {}) {
      const response = await fetch(path, options);
      const type = response.headers.get("content-type") || "";
      if (!response.ok) {
        let message = response.statusText;
        if (type.includes("application/json")) {
          const body = await response.json();
          message = body.error || message;
        }
        throw new Error(message);
      }
      return response;
    }

    async function ensureMic() {
      if (stream) return;
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        throw new Error("Browser microphone API unavailable on this origin.");
      }
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    }

    async function loadStats() {
      try {
        const response = await api("/api/stats");
        const body = await response.json();
        const bucket = body.stats?.per_category?.[category.value];
        if (!bucket) return;
        const total = Number(bucket.total || 0);
        const undecided = Number(bucket.undecided || 0);
        const decided = Math.max(0, total - undecided);
        const skipped = Number(bucket.skipped || 0);
        const pct = total ? (decided / total) * 100 : 0;
        $("progressFill").style.width = pct + "%";
        $("progressText").textContent =
          category.value + ": " + decided + " decided · " + skipped + " skipped" + " · " + total + " total";
      } catch (error) {
        $("progressText").textContent = "Progress unavailable: " + error.message;
      }
    }

    async function loadNext(play = true) {
      let done = false;
      setBusy(true);
      setStatus("Loading next cluster...");
      try {
        const response = await api("/api/next?category=" + encodeURIComponent(category.value));
        const body = await response.json();
        current = body.cluster;
        currentSpeak = body.speak || "";
        renderCluster(current);
        await loadStats();
        if (!current) {
          setStatus("No undecided clusters in this category.");
          mic.textContent = "Done";
          done = true;
          return;
        }
        mic.textContent = "Record";
        setStatus("Review the cluster, then tap Record and speak your decision.");
        if (play && currentSpeak) await playText(currentSpeak);
      } catch (error) {
        current = null;
        currentSpeak = "";
        renderLoadError(error);
        mic.textContent = "Retry";
        setStatus("Load failed: " + error.message + ". Tap Retry.");
      } finally {
        setBusy(false);
        if (done) mic.disabled = true;
      }
    }

    function renderCluster(cluster) {
      if (!cluster) {
        $("clusterId").textContent = "Complete";
        $("stem").textContent = "No cluster";
        $("members").innerHTML = "<tr><td colspan='4'>No undecided clusters.</td></tr>";
        return;
      }
      $("clusterId").textContent = cluster.cluster_id;
      $("stem").textContent = cluster.stem;
      $("categoryBadge").textContent = cluster.category;
      $("members").innerHTML = cluster.members.map((member) => (
        "<tr><td>" + escapeHtml(member.name) + "</td><td>" + escapeHtml(member.type) +
        "</td><td>" + String(member.chunks ?? 0) + "</td><td>" + escapeHtml(member.id) + "</td></tr>"
      )).join("");
    }

    function renderLoadError(error) {
      $("clusterId").textContent = "Load failed";
      $("stem").textContent = "Retry";
      $("members").innerHTML =
        "<tr><td colspan='4'>Error loading the next cluster: " + escapeHtml(error.message) +
        ". Tap Retry.</td></tr>";
    }

    async function playText(text) {
      stopTtsPlayback();
      const started = performance.now();
      let url = null;
      try {
        const response = await api("/api/tts", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ text })
        });
        const blob = await response.blob();
        url = URL.createObjectURL(blob);
        audio.src = url;
        const ttsMs = response.headers.get("x-tts-ms") || Math.round(performance.now() - started);
        setStatus("TTS ready in " + ttsMs + " ms. Playing...");
        setTtsPlaying(true);
        await new Promise((resolve, reject) => {
          const playback = {
            resolve,
            cleanup: () => {}
          };
          const cleanup = () => {
            audio.removeEventListener("ended", onEnded);
            audio.removeEventListener("error", onError);
            if (url) URL.revokeObjectURL(url);
            url = null;
            if (activePlayback === playback) activePlayback = null;
            setTtsPlaying(false);
          };
          playback.cleanup = cleanup;
          const onEnded = () => {
            cleanup();
            resolve();
          };
          const onError = () => {
            cleanup();
            reject(new Error("browser audio playback failed"));
          };
          audio.addEventListener("ended", onEnded, { once: true });
          audio.addEventListener("error", onError, { once: true });
          activePlayback = playback;
          audio.play().catch((error) => {
            cleanup();
            reject(error);
          });
        });
      } catch (error) {
        if (url) URL.revokeObjectURL(url);
        setTtsPlaying(false);
        setStatus("TTS failed: " + error.message);
      }
    }

    function stopTtsPlayback() {
      const playback = activePlayback;
      if (!playback && !ttsPlaying) return;
      audio.pause();
      audio.removeAttribute("src");
      audio.load();
      if (playback) {
        playback.cleanup();
        playback.resolve();
      } else {
        setTtsPlaying(false);
      }
    }

    async function startRecording() {
      if (!current) return;
      const recordingCluster = current;
      chunks = [];
      const options = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
        ? { mimeType: "audio/webm;codecs=opus" }
        : {};
      recorder = new MediaRecorder(stream, options);
      recorder.ondataavailable = (event) => {
        if (event.data.size > 0) chunks.push(event.data);
      };
      recorder.onstop = () => processRecording(new Blob(chunks, { type: recorder.mimeType || "audio/webm" }), recordingCluster);
      recorder.start();
      setRecording(true);
      mic.classList.add("recording");
      mic.textContent = "Stop";
      setStatus("Recording in browser. Tap Stop when your answer is done.");
    }

    async function stopRecording() {
      if (recorder && recorder.state === "recording") recorder.stop();
    }

    async function processRecording(blob, cluster) {
      const stoppedAt = performance.now();
      setRecording(false);
      setBusy(true);
      mic.classList.remove("recording");
      mic.textContent = "Record";
      try {
        setStatus("Transcribing locally with whisper-cli...");
        const transcribeResponse = await api("/api/transcribe", {
          method: "POST",
          headers: { "content-type": blob.type || "audio/webm" },
          body: blob
        });
        const transcribedAt = performance.now();
        const transcribe = await transcribeResponse.json();
        $("transcript").textContent = transcribe.text || "(empty transcript)";

        setStatus("Interpreting decision with LiteRT-LM...");
        const interpretResponse = await api("/api/interpret", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ transcript: transcribe.text, cluster: cluster })
        });
        const interpretedAt = performance.now();
        const interpreted = await interpretResponse.json();
        $("decision").textContent = JSON.stringify(interpreted.decision, null, 2);
        $("timings").textContent =
          "Timings: record-stop to transcript " + ms(transcribedAt - stoppedAt) +
          ", transcript to decision " + ms(interpretedAt - transcribedAt) +
          ", total " + ms(interpretedAt - stoppedAt) + ".";

        setStatus("Recording decision...");
        await api("/api/decide", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ cluster_id: cluster.cluster_id, decision: interpreted.decision })
        });
        setStatus("Decision recorded.");
        await playText(interpreted.confirmation);
        setStatus("Loading next cluster...");
        await loadNext(true);
      } catch (error) {
        setStatus("Error: " + error.message);
        setBusy(false);
      }
    }

    mic.addEventListener("click", async () => {
      try {
        if (ttsPlaying) {
          stopTtsPlayback();
          setBusy(false);
          if (!stream) await ensureMic();
          if (recorder && recorder.state === "recording") {
            await stopRecording();
            return;
          }
          await startRecording();
          return;
        }
        if (busy) return;
        if (!stream) {
          await ensureMic();
          await loadNext(true);
          return;
        }
        if (!current) {
          await loadNext(true);
          return;
        }
        if (recorder && recorder.state === "recording") {
          await stopRecording();
          return;
        }
        await startRecording();
      } catch (error) {
        setStatus("Error: " + error.message);
      }
    });

    category.addEventListener("change", async () => {
      if (busy || recording) return;
      if (!stream) return;
      await loadNext(true);
    });

    function escapeHtml(value) {
      return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#039;");
    }

    loadStats();
  </script>
</body>
</html>`;
}

if (import.meta.main) {
  initEnrichedPATH();
  await Bun.$`mkdir -p ${DEFAULT_CONFIG.tempDir}`.quiet();
  const app = createVoiceReviewApp();
  const server = Bun.serve({
    hostname: DEFAULT_CONFIG.hostname,
    port: DEFAULT_CONFIG.port,
    fetch: app.fetch,
  });
  console.log(
    `VoiceReview web server listening on http://${server.hostname}:${server.port}`,
  );
}
