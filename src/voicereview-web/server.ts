import { dlopen, FFIType } from "bun:ffi";
import {
  mkdir,
  open,
  readdir,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { initEnrichedPATH, resolveBinary } from "../resolve-binary";
import {
  hasClonedProfile,
  listClonedVoiceProfiles,
  synthesizeCloned,
} from "../tts/qwen3";

export type ReviewAction = "merge" | "keep" | "mixed" | "skip" | "question";
export type InterpretAction = ReviewAction | "update";
export type MemberDecision = "merge" | "keep" | "prune";
export type MemberUnderstanding = "irrelevant" | "merge" | "keep" | "undecided";

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
  question?: string;
  note: string;
  source: "voice";
}

export interface UnderstandingDelta {
  action: InterpretAction;
  canonical_id?: string;
  members?: Record<string, MemberDecision>;
  member_updates?: Record<string, MemberUnderstanding>;
  remaining_question?: string;
  question?: string;
  note: string;
  source: "voice";
}

export type VoiceInterpretation = VoiceDecision | UnderstandingDelta;

export interface UnderstandingState {
  cluster_id: string;
  member_updates: Record<string, MemberUnderstanding>;
  notes: string[];
  remaining_question?: string;
  canonical_id?: string;
}

export interface ConversationTurn {
  question: string;
  answer: string;
}

export interface InterruptionContext {
  agent_speech_spoken_so_far: string;
  agent_speech_unspoken_remainder: string;
  interrupted_at_ms: number;
}

export interface WordBoundary {
  offset_ms: number;
  duration_ms: number;
  text: string;
}

export interface EvidenceSnippet {
  chunk_id: string;
  project: string | null;
  content_type: string | null;
  source: string | null;
  created_at: string | null;
  relevance: number | null;
  context: string | null;
  text: string;
}

export interface ConversationEvidenceMember extends ReviewMember {
  snippets: EvidenceSnippet[];
}

export interface ConversationEvidence {
  members: ConversationEvidenceMember[];
}

export interface QueueState {
  kind: "complete" | "empty" | "error";
  category: string;
  decided: number;
  message: string;
}

export interface CommandCall {
  args: string[];
  cwd: string;
  env: Record<string, string>;
  signal?: AbortSignal;
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
  brainlayerDbPath: string;
  batchPath: string;
  decisionsPath: string;
  sttVocabularyPath: string;
  ffmpegPath: string | null;
  whisperCliPath: string | null;
  whisperModelPath: string;
  liteRtUrl: string;
  liteRtModel: string;
  deepLiteRtModel: string;
  tempDir: string;
  ttsVoice: string;
  ttsRate: string;
  requestTimeoutMs: number;
  finishCommand: string;
}

export const KG_FLAG_DECISIONS_SCHEMA = "kg-flag-decisions-v1";
const FAILED_TRANSCRIBE_CAP = 20;
const SUBPROCESS_ABORT_GRACE_MS = 1000;

type FetchLike = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

type CommandRunner = (call: CommandCall) => Promise<CommandResult>;
export interface VoiceReviewTtsEngines {
  hasClonedProfile: (voice: string) => boolean;
  synthesizeCloned: (text: string, voice: string) => Promise<Buffer | null>;
  listClonedProfiles: () => string[];
}

const DEFAULT_TTS_ENGINES: VoiceReviewTtsEngines = {
  hasClonedProfile,
  synthesizeCloned,
  listClonedProfiles: listClonedVoiceProfiles,
};
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
  brainlayerDbPath:
    process.env.BRAINLAYER_DB ||
    join(HOME, ".local/share/brainlayer/brainlayer.db"),
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
    resolveBinary("ffmpeg", [
      "/opt/homebrew/bin/ffmpeg",
      "/usr/local/bin/ffmpeg",
    ]),
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
  deepLiteRtModel:
    process.env.VOICE_REVIEW_DEEP_LITERT_MODEL ||
    process.env.VOICE_REVIEW_LITERT_MODEL ||
    "gemma4-e4b,gpu",
  tempDir:
    process.env.VOICE_REVIEW_TEMP_DIR || join(tmpdir(), "voicereview-web"),
  ttsVoice: process.env.VOICE_REVIEW_TTS_VOICE || "en-US-GuyNeural",
  ttsRate: process.env.VOICE_REVIEW_TTS_RATE || "-8%",
  requestTimeoutMs: Number(process.env.VOICE_REVIEW_TIMEOUT_MS || "60000"),
  finishCommand: process.env.VOICE_REVIEW_FINISH_CMD || "",
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
  const args = [
    options.pythonBinary || "python3",
    options.pythonScript,
    command,
  ];

  if (command === "next") {
    args.push(
      `--batch=${options.batchPath}`,
      `--decisions=${options.decisionsPath}`,
    );
    if (options.category) args.push(`--category=${options.category}`);
    return args;
  }

  if (command === "stats") {
    args.push(
      `--batch=${options.batchPath}`,
      `--decisions=${options.decisionsPath}`,
    );
    return args;
  }

  if (!options.clusterId || !options.decisionJson) {
    throw new Error("record requires clusterId and decisionJson");
  }
  args.push(
    `--batch=${options.batchPath}`,
    `--decisions=${options.decisionsPath}`,
    `--cluster-id=${options.clusterId}`,
    `--decision-json=${options.decisionJson}`,
  );
  return args;
}

export function buildEvidenceArgs(options: {
  pythonBinary?: string;
  pythonScript: string;
  dbPath: string;
  members: ReviewMember[];
  perMember?: number;
  snippetChars?: number;
  question?: string;
  deep?: boolean;
}): string[] {
  const args = [
    options.pythonBinary || "python3",
    options.pythonScript,
    `--db=${options.dbPath}`,
    `--members-json=${JSON.stringify(options.members)}`,
    `--per-member=${String(options.perMember || 3)}`,
  ];
  if (options.snippetChars) {
    args.push(`--snippet-chars=${String(options.snippetChars)}`);
  }
  if (options.question?.trim()) {
    args.push(`--question=${options.question.trim()}`);
  }
  if (options.deep) args.push("--deep");
  return args;
}

export function buildWhisperPrompt(terms: unknown[], maxTokens = 224): string {
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

function isWebmContentType(contentType: string | null): boolean {
  const mediaType = (contentType || "").toLowerCase().split(";")[0].trim();
  return mediaType.endsWith("/webm");
}

async function hasEbmlHeader(audio: Blob): Promise<boolean> {
  if (audio.size < 4) return false;
  const header = new Uint8Array(await audio.slice(0, 4).arrayBuffer());
  return (
    header[0] === 0x1a &&
    header[1] === 0x45 &&
    header[2] === 0xdf &&
    header[3] === 0xa3
  );
}

export const BROWSER_VAD_CHUNK_SAMPLES = 512;
export const BROWSER_VAD_CONTEXT_SAMPLES = 64;
export const BROWSER_VAD_INPUT_SAMPLES =
  BROWSER_VAD_CHUNK_SAMPLES + BROWSER_VAD_CONTEXT_SAMPLES;

export function createSileroVadInput(
  chunk: Float32Array,
  context: Float32Array,
): { input: Float32Array; dims: [1, 576]; nextContext: Float32Array } {
  if (chunk.length !== BROWSER_VAD_CHUNK_SAMPLES) {
    throw new Error("Silero VAD chunk must contain 512 samples");
  }
  if (context.length !== BROWSER_VAD_CONTEXT_SAMPLES) {
    throw new Error("Silero VAD context must contain 64 samples");
  }
  const input = new Float32Array(BROWSER_VAD_INPUT_SAMPLES);
  input.set(context, 0);
  input.set(chunk, BROWSER_VAD_CONTEXT_SAMPLES);
  return {
    input,
    dims: [1, 576],
    nextContext: input.slice(
      BROWSER_VAD_INPUT_SAMPLES - BROWSER_VAD_CONTEXT_SAMPLES,
    ),
  };
}

export interface TurnTakingConfig {
  settleMs: number;
  frameMs: number;
  playbackBargeInFrames: number;
}

export interface TurnTakingState {
  phase: "LISTENING" | "SETTLING" | "THINKING" | "SPEAKING";
  config: TurnTakingConfig;
  hasSpeechInTurn: boolean;
  settleElapsedMs: number;
  settleProgress: number;
  showSettlingRing: boolean;
  playbackSpeechFrames: number;
  pausePlayback: boolean;
  turnTaken: boolean;
}

export function createTurnTakingState(
  overrides: Partial<TurnTakingConfig> = {},
): TurnTakingState {
  return {
    phase: "LISTENING",
    config: {
      settleMs: overrides.settleMs ?? 1300,
      frameMs: overrides.frameMs ?? 32,
      playbackBargeInFrames: overrides.playbackBargeInFrames ?? 3,
    },
    hasSpeechInTurn: false,
    settleElapsedMs: 0,
    settleProgress: 0,
    showSettlingRing: false,
    playbackSpeechFrames: 0,
    pausePlayback: false,
    turnTaken: false,
  };
}

export function advanceTurnTakingFrame(
  current: TurnTakingState,
  frame: { speech: boolean },
): TurnTakingState {
  const state: TurnTakingState = {
    ...current,
    config: { ...current.config },
    pausePlayback: false,
    turnTaken: false,
  };
  const frameMs = state.config.frameMs;

  if (state.phase === "SPEAKING") {
    if (frame.speech) {
      state.playbackSpeechFrames += 1;
      if (state.playbackSpeechFrames >= state.config.playbackBargeInFrames) {
        state.phase = "LISTENING";
        state.hasSpeechInTurn = true;
        state.settleElapsedMs = 0;
        state.settleProgress = 0;
        state.showSettlingRing = false;
        state.playbackSpeechFrames = 0;
        state.pausePlayback = true;
      }
    } else {
      state.playbackSpeechFrames = 0;
    }
    return state;
  }

  if (state.phase === "THINKING") {
    if (frame.speech) {
      state.phase = "LISTENING";
      state.hasSpeechInTurn = true;
    }
    return state;
  }

  if (frame.speech) {
    state.phase = "LISTENING";
    state.hasSpeechInTurn = true;
    state.settleElapsedMs = 0;
    state.settleProgress = 0;
    state.showSettlingRing = false;
    return state;
  }

  if (!state.hasSpeechInTurn) {
    state.phase = "LISTENING";
    return state;
  }

  state.phase = "SETTLING";
  state.settleElapsedMs += frameMs;
  state.settleProgress = Math.min(
    1,
    state.settleElapsedMs / state.config.settleMs,
  );
  state.showSettlingRing = state.settleProgress >= 0.6;
  if (state.settleElapsedMs >= state.config.settleMs) {
    state.phase = "THINKING";
    state.turnTaken = true;
    state.hasSpeechInTurn = false;
    state.settleElapsedMs = 0;
    state.settleProgress = 1;
    state.showSettlingRing = false;
  }
  return state;
}

export function createUnderstandingState(
  cluster: ReviewCluster,
  seed?: Partial<UnderstandingState>,
): UnderstandingState {
  const memberUpdates: Record<string, MemberUnderstanding> = {};
  for (const member of cluster.members) {
    memberUpdates[member.id] = seed?.member_updates?.[member.id] || "undecided";
  }
  return {
    cluster_id: cluster.cluster_id,
    member_updates: memberUpdates,
    notes: Array.isArray(seed?.notes) ? [...seed.notes] : [],
    remaining_question: seed?.remaining_question,
    canonical_id: seed?.canonical_id,
  };
}

export function applyUnderstandingDelta(
  current: UnderstandingState,
  delta: UnderstandingDelta,
  cluster: ReviewCluster,
): { state: UnderstandingState; terminalDecision: VoiceDecision | null } {
  const state = createUnderstandingState(cluster, current);
  if (delta.canonical_id) state.canonical_id = delta.canonical_id;
  if (delta.remaining_question) {
    state.remaining_question = delta.remaining_question;
  }
  if (delta.note.trim()) state.notes.push(delta.note.trim());

  if (delta.member_updates) {
    const memberIds = new Set(cluster.members.map((member) => member.id));
    for (const [id, value] of Object.entries(delta.member_updates)) {
      if (!memberIds.has(id)) throw new Error(`unknown member id: ${id}`);
      if (!isMemberUnderstanding(value)) {
        throw new Error(`invalid member understanding for ${id}`);
      }
      if (value !== "undecided") state.member_updates[id] = value;
    }
  }

  if (
    delta.action !== "update" &&
    delta.action !== "question" &&
    isVoiceDecision(delta)
  ) {
    return { state, terminalDecision: delta };
  }

  return {
    state,
    terminalDecision: composeFinalDecisionFromUnderstanding(state, cluster),
  };
}

export function composeFinalDecisionFromUnderstanding(
  state: UnderstandingState,
  cluster: ReviewCluster,
): VoiceDecision | null {
  const statuses = cluster.members.map(
    (member) => state.member_updates[member.id],
  );
  if (
    statuses.some((status) => status === "undecided" || status === undefined)
  ) {
    return null;
  }

  const note =
    state.notes.join("\n").trim() || "Resolved by voice conversation";
  if (statuses.every((status) => status === "keep")) {
    return { action: "keep", note, source: "voice" };
  }
  if (statuses.every((status) => status === "irrelevant")) {
    return { action: "skip", note, source: "voice" };
  }
  if (statuses.every((status) => status === "merge")) {
    return {
      action: "merge",
      canonical_id: selectCanonicalForUnderstanding(state, cluster),
      note,
      source: "voice",
    };
  }

  const members: Record<string, MemberDecision> = {};
  for (const member of cluster.members) {
    const status = state.member_updates[member.id];
    members[member.id] =
      status === "irrelevant" ? "prune" : status === "keep" ? "keep" : "merge";
  }
  return { action: "mixed", members, note, source: "voice" };
}

export function splitInterruptedSpeech(
  text: string,
  wordBoundaries: WordBoundary[],
  interruptedAtMs: number,
): InterruptionContext {
  const words = String(text || "")
    .trim()
    .split(/\s+/)
    .filter(Boolean);
  const safeInterruptedAtMs = Math.max(0, Math.round(interruptedAtMs || 0));
  let spokenWordCount = 0;

  if (wordBoundaries.length) {
    spokenWordCount = wordBoundaries.filter(
      (word) => word.offset_ms <= safeInterruptedAtMs,
    ).length;
  } else {
    const approximateChars = Math.floor(safeInterruptedAtMs * 0.013);
    let chars = 0;
    for (const word of words) {
      const next = chars + word.length + 1;
      if (next > approximateChars) break;
      spokenWordCount += 1;
      chars = next;
    }
  }

  spokenWordCount = Math.max(0, Math.min(words.length, spokenWordCount));
  return {
    agent_speech_spoken_so_far: words.slice(0, spokenWordCount).join(" "),
    agent_speech_unspoken_remainder: words.slice(spokenWordCount).join(" "),
    interrupted_at_ms: safeInterruptedAtMs,
  };
}

export function humanizeSpokenText(input: string): string {
  const tableNarration = humanizeMembersTable(input);
  if (tableNarration) return tableNarration;

  const normalized = dedupeSpokenLines(
    String(input || "")
      .replace(/\bas\s+[a-z0-9_-]+\s+with\s+\d+\s+chunks?\.?\s*/gi, " ")
      .replace(
        /\s*\((?:context|evidence|metadata|snippet|chunk)[^)]*\d+\s+chunks?\)/gi,
        "",
      )
      .replace(/\s*\([^()\n,]{1,80},\s*\d+\s+chunks?\)/gi, ""),
  )
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/<\/?[^>]+>/g, "")
    .replace(/^#{1,6}\s*/gm, "")
    .replace(/^\s*[-*]\s+/gm, "")
    .replace(/\brt-[a-z0-9-]{6,}\b/gi, "")
    .replace(/\bchunk\s+\d+\b/gi, "")
    .replace(/\btype=[a-z0-9_-]+:?\s*/gi, "")
    .replace(/_/g, " ")
    .replace(/[ \t]*\n+[ \t]*/g, ". ")
    .replace(/\s+([.,:;!?])/g, "$1")
    .replace(/:\s*\./g, ".")
    .replace(/\.\s*\./g, ".")
    .replace(/([!?])\s*\./g, "$1")
    .replace(/\s+/g, " ")
    .trim();
  return dedupeSpokenSegments(normalized);
}

function dedupeSpokenLines(input: string): string {
  const seen = new Set<string>();
  const output: string[] = [];
  for (const line of input.split(/\n+/)) {
    const clean = line.replace(/\s+/g, " ").trim();
    if (!clean) continue;
    const key = clean.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    output.push(clean);
  }
  return output.join("\n");
}

function dedupeSpokenSegments(input: string): string {
  const seen = new Set<string>();
  const segments = input.match(/[^.!?]+[.!?]+|[^.!?]+$/g) || [];
  const output: string[] = [];
  for (const segment of segments) {
    const clean = segment.replace(/\s+/g, " ").trim();
    if (!clean) continue;
    const key = normalizeSpokenSegmentKey(clean);
    if (key.length >= 48) {
      if (seen.has(key)) continue;
      seen.add(key);
    }
    output.push(clean);
  }
  return output.join(" ").trim();
}

function normalizeSpokenSegmentKey(input: string): string {
  return input
    .toLowerCase()
    .replace(/[.!?]+$/g, "")
    .replace(/^all named\s+/i, "")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function humanizeMembersTable(input: string): string | null {
  const memberRows = String(input || "")
    .split(/\n+/)
    .map((line) =>
      line.match(/^\s*[-*]\s*(.+?)\s+\(([^,()]+),\s*\d+\s+chunks?\)\s*$/i),
    )
    .filter((match): match is RegExpMatchArray => Boolean(match))
    .map((match) => ({
      name: match[1].trim(),
      type: match[2].trim().toLowerCase(),
    }));

  if (memberRows.length < 2) return null;

  const byType = new Map<string, string[]>();
  for (const row of memberRows) {
    byType.set(row.type, [...(byType.get(row.type) || []), row.name]);
  }

  const parts = [...byType.entries()].map(([type, names]) => {
    const count = names.length;
    const entryLabel = count === 1 ? "entry" : "entries";
    const similar =
      count > 1 &&
      new Set(names.map((name) => name.toLowerCase().replace(/[^a-z0-9]/g, "")))
        .size <= 1;
    return [
      numberWord(count),
      type,
      entryLabel,
      similar ? "with similar names" : "",
    ]
      .filter(Boolean)
      .join(" ");
  });

  return `${capitalize(numberWord(memberRows.length))} entries: ${joinNaturalList(
    parts,
  )}.`;
}

function joinNaturalList(parts: string[]): string {
  if (parts.length <= 1) return parts[0] || "";
  if (parts.length === 2) return `${parts[0]}, and ${parts[1]}`;
  return `${parts.slice(0, -1).join(", ")}, and ${parts.at(-1)}`;
}

function numberWord(value: number): string {
  const words = [
    "zero",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
  ];
  return words[value] || String(value);
}

function capitalize(value: string): string {
  return value ? value[0].toUpperCase() + value.slice(1) : value;
}

function selectCanonicalForUnderstanding(
  state: UnderstandingState,
  cluster: ReviewCluster,
): string {
  if (
    state.canonical_id &&
    cluster.members.some((member) => member.id === state.canonical_id)
  ) {
    return state.canonical_id;
  }
  const firstMerge = cluster.members.find(
    (member) => state.member_updates[member.id] === "merge",
  );
  return firstMerge?.id || cluster.members[0]?.id || "";
}

function isVoiceDecision(value: UnderstandingDelta): value is VoiceDecision {
  return (
    value.action === "merge" ||
    value.action === "keep" ||
    value.action === "mixed" ||
    value.action === "skip" ||
    value.action === "question"
  );
}

function isMemberUnderstanding(value: unknown): value is MemberUnderstanding {
  return (
    value === "irrelevant" ||
    value === "merge" ||
    value === "keep" ||
    value === "undecided"
  );
}

export function buildInterpretMessages(options: {
  transcript: string;
  cluster: ReviewCluster;
  understanding?: Partial<UnderstandingState>;
  interruption?: InterruptionContext | null;
}): Array<{ role: "system" | "user"; content: string }> {
  const system = [
    "STRICT KG voice-review interpreter.",
    "Map one free-form spoken reviewer turn to exactly one JSON object.",
    "Allowed action values: update|merge|keep|mixed|skip|question.",
    "Use update when the user resolved only part of the cluster; include member_updates, remaining_question, and note.",
    'member_updates maps member ids to exactly one of: "irrelevant", "merge", "keep", "undecided".',
    "Only emit merge, keep, mixed, or skip when every member is resolved.",
    "For update, ask the next narrow remaining_question about ONLY unresolved members.",
    "Use question when the transcript asks for information, comparison, evidence, consequences, clarification, or ideation instead of deciding the cluster.",
    "For merge, canonical_id must be one id from cluster.members.",
    "For update where a merge canonical is already clear, include canonical_id additively.",
    "For keep and skip, omit canonical_id and members.",
    "For mixed, members must map member id to merge|keep|prune.",
    "For question, include question equal to the user's question in the same language, omit canonical_id and members.",
    "If interruption context is present, interpret the transcript as a barge-in response to what the agent had already said. The unspoken remainder may be moot.",
    "Every action must carry note equal to the verbatim transcript.",
    "If the transcript is ambiguous or non-deterministic, choose skip with the verbatim transcript as note. Never force a clean merge/keep/mixed disposition from unclear speech.",
    "Return exactly one JSON object. No markdown, no prose.",
    "",
    "few-shot examples:",
    'Transcript: "the person is not relevant, I am deciding between company and project"',
    '{"action":"update","member_updates":{"<person-member-id>":"irrelevant","<company-member-id>":"undecided","<project-member-id>":"undecided"},"remaining_question":"Should the company and project merge, or stay separate?","note":"the person is not relevant, I am deciding between company and project"}',
    'Transcript: "merge them all, the company one is the real one"',
    '{"action":"merge","canonical_id":"<company-member-id>","note":"merge them all, the company one is the real one"}',
    'Transcript: "keep these separate"',
    '{"action":"keep","note":"keep these separate"}',
    'Transcript: "mixed, merge the tool and project, prune the person"',
    '{"action":"mixed","members":{"<tool-id>":"merge","<project-id>":"merge","<person-id>":"prune"},"note":"mixed, merge the tool and project, prune the person"}',
    'Transcript: "which chunks does the company one have?"',
    '{"action":"question","question":"which chunks does the company one have?","note":"which chunks does the company one have?"}',
    'Transcript: "מה ההבדל בין ה-company וה-project?"',
    '{"action":"question","question":"מה ההבדל בין ה-company וה-project?","note":"מה ההבדל בין ה-company וה-project?"}',
    'Transcript: "I am not sure, maybe this is one thing but maybe not"',
    '{"action":"skip","note":"I am not sure, maybe this is one thing but maybe not"}',
  ].join("\n");

  const memberLines = options.cluster.members
    .map(
      (member) =>
        `- ${member.id}: ${member.name} (${member.type}, ${member.chunks} chunks)`,
    )
    .join("\n");
  const understanding =
    options.understanding || createUnderstandingState(options.cluster);
  const currentUnderstanding = options.cluster.members
    .map((member) => {
      const status = understanding.member_updates?.[member.id] || "undecided";
      return `- ${member.id}: ${status}`;
    })
    .join("\n");
  const notes =
    Array.isArray(understanding.notes) && understanding.notes.length
      ? understanding.notes.slice(-6).join("\n")
      : "No prior understanding notes.";
  const interruption = options.interruption
    ? [
        "Interruption context:",
        `agent_speech_spoken_so_far: ${JSON.stringify(options.interruption.agent_speech_spoken_so_far)}`,
        `agent_speech_unspoken_remainder: ${JSON.stringify(options.interruption.agent_speech_unspoken_remainder)}`,
        `interrupted_at_ms: ${options.interruption.interrupted_at_ms}`,
      ].join("\n")
    : "Interruption context: none.";
  const user = [
    `Cluster: ${options.cluster.cluster_id}`,
    `Stem: ${options.cluster.stem}`,
    `Category: ${options.cluster.category}`,
    "Members:",
    memberLines,
    "Current understanding:",
    currentUnderstanding,
    "Prior notes:",
    notes,
    interruption,
    `Transcript: ${JSON.stringify(options.transcript)}`,
  ].join("\n");

  return [
    { role: "system", content: system },
    { role: "user", content: user },
  ];
}

export function buildConverseMessages(options: {
  question: string;
  cluster: ReviewCluster;
  history: ConversationTurn[];
  evidence: ConversationEvidence;
  evidenceDepth?: "shallow" | "deep";
  interruption?: InterruptionContext | null;
}): Array<{ role: "system" | "user"; content: string }> {
  const system = [
    "Grounded KG voice-review conversation assistant.",
    "You help a reviewer reason about whether the current cluster's members should be merged, kept separate, mixed, or skipped.",
    "You must answer ONLY from the provided evidence snippets and cluster facts.",
    options.evidenceDepth === "deep"
      ? 'If the deeper evidence still does not answer the question, say "I looked deeper, but I still do not see evidence about that" rather than invent.'
      : 'If the provided evidence does not answer the question, do not say "I don\'t see evidence about that"; say exactly NEED_DEEPER_EVIDENCE.',
    "If interruption context is present, answer the interruption directly and decide whether the paused remainder is still useful.",
    "Use short spoken-style answers, 2-4 sentences, because the answer will be read aloud with TTS.",
    "Mention member names and types when useful. Do not include markdown.",
  ].join("\n");

  const clusterFacts = [
    `Cluster: ${options.cluster.cluster_id}`,
    `Stem: ${options.cluster.stem}`,
    `Category: ${options.cluster.category}`,
    `Size: ${options.cluster.size}`,
    "Members:",
    ...options.cluster.members.map(
      (member) =>
        `- ${member.id}: ${member.name} (${member.type}, ${member.chunks} chunks)`,
    ),
  ].join("\n");

  const history = options.history.length
    ? options.history
        .slice(-6)
        .map(
          (turn, index) =>
            `Turn ${index + 1} Q: ${turn.question}\nTurn ${index + 1} A: ${turn.answer}`,
        )
        .join("\n")
    : "No prior Q&A turns.";
  const interruption = options.interruption
    ? [
        "Interruption context:",
        `agent_speech_spoken_so_far: ${JSON.stringify(options.interruption.agent_speech_spoken_so_far)}`,
        `agent_speech_unspoken_remainder: ${JSON.stringify(options.interruption.agent_speech_unspoken_remainder)}`,
        `interrupted_at_ms: ${options.interruption.interrupted_at_ms}`,
      ].join("\n")
    : "Interruption context: none.";

  const evidence = options.evidence.members
    .map((member) => {
      const snippets = member.snippets.length
        ? member.snippets
            .map((snippet, index) =>
              [
                `  ${index + 1}. chunk ${snippet.chunk_id}`,
                `     meta: project=${snippet.project || "unknown"}, type=${snippet.content_type || "unknown"}, source=${snippet.source || "unknown"}, created_at=${snippet.created_at || "unknown"}, relevance=${snippet.relevance ?? "unknown"}`,
                snippet.context ? `     context: ${snippet.context}` : null,
                `     text: ${snippet.text}`,
              ]
                .filter(Boolean)
                .join("\n"),
            )
            .join("\n")
        : "  No snippets found.";
      return [
        `${member.id}: ${member.name} (${member.type}, ${member.chunks} chunks)`,
        snippets,
      ].join("\n");
    })
    .join("\n\n");

  const user = [
    clusterFacts,
    "",
    "Conversation history:",
    history,
    "",
    interruption,
    "",
    "Evidence snippets:",
    evidence || "No evidence snippets found.",
    "",
    `Current question: ${options.question}`,
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
): VoiceInterpretation {
  const parsed = parseJsonObject(rawContent);
  if (!isRecord(parsed)) throw new Error("LiteRT response was not an object");

  const action = normalizeInterpretAction(parsed.action);

  const memberIds = new Set(cluster.members.map((member) => member.id));
  const decision: UnderstandingDelta = {
    action,
    note: transcript.trim(),
    source: "voice",
  };

  if (typeof parsed.canonical_id === "string") {
    if (!memberIds.has(parsed.canonical_id)) {
      throw new Error("canonical_id is not a member of this cluster");
    }
    decision.canonical_id = parsed.canonical_id;
  }

  if (isRecord(parsed.member_updates)) {
    const updates: Record<string, MemberUnderstanding> = {};
    for (const [id, value] of Object.entries(parsed.member_updates)) {
      if (!memberIds.has(id)) throw new Error(`unknown member id: ${id}`);
      if (!isMemberUnderstanding(value)) {
        throw new Error(`invalid member understanding for ${id}`);
      }
      updates[id] = value;
    }
    decision.member_updates = updates;
  }

  if (typeof parsed.remaining_question === "string") {
    decision.remaining_question = parsed.remaining_question.trim();
  }

  if (action === "update") {
    if (!decision.member_updates) {
      throw new Error("update interpretation requires member_updates");
    }
    return decision;
  }

  if (action === "question") {
    decision.question =
      typeof parsed.question === "string" && parsed.question.trim()
        ? parsed.question.trim()
        : transcript.trim();
    return decision;
  }

  if (action === "merge") {
    if (typeof decision.canonical_id !== "string") {
      throw new Error("merge interpretation requires canonical_id");
    }
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
  decision: VoiceInterpretation,
  cluster: ReviewCluster,
): string | null {
  if (decision.action === "update") return decision.remaining_question || null;
  if (decision.action === "question") return null;
  if (decision.action === "merge") {
    const canonical = cluster.members.find(
      (member) => member.id === decision.canonical_id,
    );
    if (canonical)
      return `Merge all into ${canonical.name}, ${canonical.type}.`;
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

  const byClusterId = new Map(
    clusters.map((cluster) => [cluster.cluster_id, cluster]),
  );
  for (const [clusterId, rawDecision] of Object.entries(data.decisions)) {
    if (!isRecord(rawDecision)) continue;
    const cluster = byClusterId.get(clusterId);
    if (!cluster) {
      throw new Error(
        `legacy decision references unknown cluster ${clusterId}`,
      );
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
      const canonical = selectCanonicalMember(
        cluster,
        rawDecision.canonical_id,
      );
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
  ttsEngines?: VoiceReviewTtsEngines;
}): { fetch: (request: Request) => Promise<Response> } {
  const config = mergeConfig(options?.config);
  const runCommand = options?.runCommand || runShellCommand;
  const fetchImpl = options?.fetchImpl || fetch;
  const lockDecisionFile = options?.lockDecisionFile || withDecisionFileLock;
  const ttsEngines = options?.ttsEngines || DEFAULT_TTS_ENGINES;

  return {
    fetch: async (request: Request): Promise<Response> => {
      try {
        const url = new URL(request.url);
        if (request.method === "GET" && url.pathname === "/") {
          return htmlResponse(
            renderNaturalConversationPage(
              config,
              await loadAvailableCategories(config),
              ttsEngines,
            ),
          );
        }
        if (
          request.method === "GET" &&
          url.pathname === "/models/silero_vad.onnx"
        ) {
          return await handleSileroModel();
        }
        if (
          request.method === "GET" &&
          url.pathname.startsWith("/vendor/onnxruntime-web/")
        ) {
          return await handleOnnxRuntimeAsset(url);
        }
        if (request.method === "GET" && url.pathname === "/api/next") {
          return await handleNext(url, config, runCommand, lockDecisionFile);
        }
        if (request.method === "GET" && url.pathname === "/api/stats") {
          return await handleStats(config, runCommand, lockDecisionFile);
        }
        if (request.method === "GET" && url.pathname === "/api/health") {
          return await handleHealth(config, fetchImpl);
        }
        if (request.method === "POST" && url.pathname === "/api/decide") {
          return await handleDecide(
            request,
            config,
            runCommand,
            lockDecisionFile,
          );
        }
        if (request.method === "POST" && url.pathname === "/api/interpret") {
          return await handleInterpret(request, config, fetchImpl);
        }
        if (request.method === "POST" && url.pathname === "/api/converse") {
          return await handleConverse(request, config, runCommand, fetchImpl);
        }
        if (request.method === "POST" && url.pathname === "/api/transcribe") {
          return await handleTranscribe(request, config, runCommand);
        }
        if (request.method === "POST" && url.pathname === "/api/tts") {
          return await handleTts(request, config, runCommand, ttsEngines);
        }
        if (
          request.method === "POST" &&
          url.pathname === "/api/session/finish"
        ) {
          return await handleSessionFinish(request, config, runCommand);
        }
        return jsonResponse({ error: "not found" }, 404);
      } catch (error) {
        if (isAbortError(error)) {
          return jsonResponse({ error: "request aborted" }, 499);
        }
        return jsonResponse({ error: errorMessage(error) }, 500);
      }
    },
  };
}

async function handleSessionFinish(
  request: Request,
  config: VoiceReviewConfig,
  runCommand: CommandRunner,
): Promise<Response> {
  if (!isValidSessionFinishRequest(request)) {
    return jsonResponse({ error: "forbidden" }, 403);
  }
  const command = config.finishCommand.trim();
  if (!command) {
    return jsonResponse(
      { error: "VOICE_REVIEW_FINISH_CMD is not configured" },
      501,
    );
  }
  const result = await runCommand({
    args: ["/bin/zsh", "-lc", command],
    cwd: config.brainlayerWorktree,
    env: driverEnv(config),
    signal: request.signal,
  });
  return jsonResponse(
    {
      ok: result.exitCode === 0,
      exit_code: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
      duration_ms: result.durationMs,
    },
    result.exitCode === 0 ? 200 : 500,
  );
}

function isValidSessionFinishRequest(request: Request): boolean {
  if (request.headers.get("x-voicereview-finish") !== "1") return false;
  const requestOrigin = new URL(request.url).origin;
  const origin = request.headers.get("origin");
  if (origin && origin !== requestOrigin) return false;
  const referer = request.headers.get("referer");
  if (!origin && referer) {
    try {
      return new URL(referer).origin === requestOrigin;
    } catch (_error) {
      return false;
    }
  }
  return Boolean(origin || referer);
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
  const timings: Record<string, number> = { driver_ms: result.durationMs };
  if (!payload.cluster) {
    const statsResult = await runCommand({
      args: buildDriverArgs("stats", {
        pythonScript: driverScript(config),
        batchPath: config.batchPath,
        decisionsPath: config.decisionsPath,
      }),
      cwd: config.brainlayerWorktree,
      env: driverEnv(config),
    });
    timings.stats_ms = statsResult.durationMs;
    if (statsResult.exitCode !== 0) {
      payload.queue_state = describeQueueStatsError(
        category,
        commandFailureMessage(statsResult, "kg_review_session.py"),
      );
    } else {
      const stats = parseDriverJson(statsResult);
      const decisions = await loadDecisionsJson(config.decisionsPath);
      payload.queue_state = describeQueueState(
        decorateStatsWithSkippedCounts(stats, decisions),
        category,
      );
    }
  }
  return jsonResponse({ ...payload, timings });
}

async function handleSileroModel(): Promise<Response> {
  const modelPath = join(
    import.meta.dir,
    "..",
    "..",
    "models",
    "silero_vad.onnx",
  );
  const file = Bun.file(modelPath);
  if (!(await file.exists())) {
    return jsonResponse({ error: "silero_vad.onnx not found" }, 404);
  }
  return new Response(file, {
    status: 200,
    headers: {
      "content-type": "application/octet-stream",
      "content-length": String(file.size),
      "cache-control": "public, max-age=3600",
    },
  });
}

async function handleOnnxRuntimeAsset(url: URL): Promise<Response> {
  const name = url.pathname.split("/").pop() || "";
  if (!/^[a-zA-Z0-9._-]+$/.test(name)) {
    return jsonResponse({ error: "invalid asset path" }, 400);
  }
  const assetPath = join(
    import.meta.dir,
    "..",
    "..",
    "node_modules",
    "onnxruntime-web",
    "dist",
    name,
  );
  const file = Bun.file(assetPath);
  if (!(await file.exists())) return jsonResponse({ error: "not found" }, 404);
  return new Response(file, {
    status: 200,
    headers: {
      "content-type": contentTypeForAsset(name),
      "content-length": String(file.size),
      "cache-control": "public, max-age=3600",
    },
  });
}

async function handleHealth(
  config: VoiceReviewConfig,
  fetchImpl: FetchLike,
): Promise<Response> {
  const legs: Record<string, { ok: boolean; error?: string }> = {
    litert: { ok: false },
  };
  const timeoutMs = Math.max(1, Math.min(config.requestTimeoutMs, 4000));
  const timeout = Symbol("litert-health-timeout");
  try {
    const probe = fetchImpl(liteRtModelsUrl(config.liteRtUrl), {
      method: "GET",
      headers: { accept: "application/json" },
    }).catch((error: unknown) => error);
    const result = await Promise.race([
      probe,
      new Promise<typeof timeout>((resolve) =>
        setTimeout(() => resolve(timeout), timeoutMs),
      ),
    ]);
    if (result === timeout) {
      legs.litert = {
        ok: false,
        error: `LiteRT-LM health timed out after ${timeoutMs}ms`,
      };
      return jsonResponse(
        { ok: false, message: "brain offline — retrying", legs },
        503,
      );
    }
    if (result instanceof Error) throw result;
    if (!(result instanceof Response)) {
      throw new Error("LiteRT-LM health returned non-response");
    }
    const response = result;
    if (!response.ok) {
      legs.litert = {
        ok: false,
        error: `LiteRT-LM failed: ${response.status} ${response.statusText}`,
      };
      return jsonResponse(
        { ok: false, message: "brain offline — retrying", legs },
        503,
      );
    }
    legs.litert = { ok: true };
    return jsonResponse({ ok: true, message: "ready", legs });
  } catch (error) {
    legs.litert = { ok: false, error: errorMessage(error) };
    return jsonResponse(
      { ok: false, message: "brain offline — retrying", legs },
      503,
    );
  }
}

function liteRtModelsUrl(chatCompletionsUrl: string): string {
  const url = new URL(chatCompletionsUrl);
  url.search = "";
  url.hash = "";
  url.pathname = url.pathname.replace(/\/chat\/completions\/?$/, "/models");
  if (!url.pathname.endsWith("/models")) {
    url.pathname = url.pathname.replace(/\/$/, "") + "/models";
  }
  return url.toString();
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
  if (result.exitCode !== 0) {
    return jsonResponse({
      stats: null,
      degraded: true,
      error: `stats unavailable: ${commandFailureMessage(result, "kg_review_session.py")}`,
      timings: { driver_ms: result.durationMs },
    });
  }
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
    signal: request.signal,
  });
  throwIfAborted(request.signal);
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
  const interruption = normalizeInterruptionContext(body.interruption);
  const messages = buildInterpretMessages({
    transcript: body.transcript,
    cluster: body.cluster,
    understanding: isRecord(body.understanding)
      ? normalizeUnderstandingState(body.understanding, body.cluster)
      : undefined,
    interruption,
  });
  const response = await fetchImpl(config.liteRtUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: config.liteRtModel,
      messages,
      temperature: 0,
      max_tokens: 420,
      stream: false,
    }),
    signal: request.signal,
  });
  if (!response.ok) {
    throw new Error(
      `LiteRT-LM failed: ${response.status} ${response.statusText}`,
    );
  }
  const raw = await response.json();
  const content = extractChatContent(raw);
  const decision = parseInterpretDecision(
    content,
    body.cluster,
    body.transcript,
  );
  return jsonResponse({
    decision,
    confirmation: buildConfirmation(decision, body.cluster),
    timings: { llm_ms: Math.round(performance.now() - started) },
  });
}

async function handleConverse(
  request: Request,
  config: VoiceReviewConfig,
  runCommand: CommandRunner,
  fetchImpl: FetchLike,
): Promise<Response> {
  const body = await request.json();
  if (
    !isRecord(body) ||
    typeof body.question !== "string" ||
    !body.question.trim() ||
    !isReviewCluster(body.cluster)
  ) {
    return jsonResponse(
      { error: "question, cluster, and optional history are required" },
      400,
    );
  }

  let history: ConversationTurn[] = [];
  if (body.history !== undefined) {
    if (!isConversationHistory(body.history)) {
      return jsonResponse(
        { error: "question, cluster, and optional history are required" },
        400,
      );
    }
    history = body.history;
  }
  const question = body.question.trim();
  const interruption = normalizeInterruptionContext(body.interruption);
  const evidenceResult = await runCommand({
    args: buildEvidenceArgs({
      pythonScript: evidenceScript(),
      dbPath: config.brainlayerDbPath,
      members: body.cluster.members,
      perMember: 3,
    }),
    cwd: process.cwd(),
    env: processEnv(),
    signal: request.signal,
  });
  throwIfAborted(request.signal);
  assertSuccess(evidenceResult, "kg_evidence.py");
  const evidence = parseConversationEvidence(
    evidenceResult.stdout,
    body.cluster,
  );

  const llmStarted = performance.now();
  const shallow = await fetchConverseAnswer({
    config,
    fetchImpl,
    model: config.liteRtModel,
    signal: request.signal,
    messages: buildConverseMessages({
      question,
      cluster: body.cluster,
      history,
      evidence,
      evidenceDepth: "shallow",
      interruption,
    }),
  });

  if (!isInsufficientEvidenceAnswer(shallow)) {
    return jsonResponse({
      answer: shallow,
      evidence,
      evidence_depth: "shallow",
      timings: {
        evidence_ms: evidenceResult.durationMs,
        llm_ms: Math.round(performance.now() - llmStarted),
      },
    });
  }

  const deepEvidenceResult = await runCommand({
    args: buildEvidenceArgs({
      pythonScript: evidenceScript(),
      dbPath: config.brainlayerDbPath,
      members: body.cluster.members,
      perMember: 8,
      snippetChars: 1800,
      question,
      deep: true,
    }),
    cwd: process.cwd(),
    env: processEnv(),
    signal: request.signal,
  });
  throwIfAborted(request.signal);
  assertSuccess(deepEvidenceResult, "kg_evidence.py");
  const deepEvidence = parseConversationEvidence(
    deepEvidenceResult.stdout,
    body.cluster,
  );
  const deep = await fetchConverseAnswer({
    config,
    fetchImpl,
    model: config.deepLiteRtModel,
    signal: request.signal,
    messages: buildConverseMessages({
      question,
      cluster: body.cluster,
      history,
      evidence: deepEvidence,
      evidenceDepth: "deep",
      interruption,
    }),
  });

  return jsonResponse({
    answer: isInsufficientEvidenceAnswer(deep)
      ? "I looked deeper, but I still do not see evidence about that."
      : deep,
    preface: "Let me look deeper.",
    evidence: deepEvidence,
    evidence_depth: "deep",
    deep_model: config.deepLiteRtModel,
    timings: {
      evidence_ms: evidenceResult.durationMs,
      deep_evidence_ms: deepEvidenceResult.durationMs,
      llm_ms: Math.round(performance.now() - llmStarted),
    },
  });
}

async function fetchConverseAnswer(options: {
  config: VoiceReviewConfig;
  fetchImpl: FetchLike;
  model: string;
  signal?: AbortSignal;
  messages: Array<{ role: "system" | "user"; content: string }>;
}): Promise<string> {
  const response = await options.fetchImpl(options.config.liteRtUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: options.model,
      messages: options.messages,
      temperature: 0,
      max_tokens: 220,
      stream: false,
    }),
    signal: options.signal,
  });
  if (!response.ok) {
    throw new Error(
      `LiteRT-LM failed: ${response.status} ${response.statusText}`,
    );
  }
  const raw = await response.json();
  return extractChatContent(raw).replace(/\s+/g, " ").trim();
}

function isInsufficientEvidenceAnswer(answer: string): boolean {
  const normalized = answer.trim().toLowerCase();
  return (
    normalized === "need_deeper_evidence" ||
    normalized.includes("need_deeper_evidence") ||
    normalized.includes("i don't see evidence") ||
    normalized.includes("i don’t see evidence") ||
    normalized.includes("provided snippets") ||
    normalized.includes("not enough evidence")
  );
}

async function handleTranscribe(
  request: Request,
  config: VoiceReviewConfig,
  runCommand: CommandRunner,
): Promise<Response> {
  const started = performance.now();
  const audio = await request.blob();
  if (audio.size === 0) return jsonResponse({ error: "empty audio" }, 400);
  const contentType = request.headers.get("content-type");
  if (isWebmContentType(contentType) && !(await hasEbmlHeader(audio))) {
    console.warn(
      JSON.stringify({
        level: "warn",
        event: "voicereview_transcribe_invalid_webm",
        code: "invalid_webm_header",
        bytes: audio.size,
      }),
    );
    return jsonResponse(
      {
        error: "invalid webm audio",
        code: "invalid_webm_header",
        recoverable: true,
      },
      422,
    );
  }

  const id = crypto.randomUUID();
  const inputPath = join(
    config.tempDir,
    `${id}.${extensionForContentType(contentType)}`,
  );
  const wavPath = join(config.tempDir, `${id}.wav`);
  await mkdir(config.tempDir, { recursive: true });
  await Bun.write(inputPath, audio);

  let preservedFailedInput = false;
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
      signal: request.signal,
    });
    throwIfAborted(request.signal);
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
      signal: request.signal,
    });
    throwIfAborted(request.signal);
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
  } catch (error) {
    if (isAbortError(error)) throw error;
    preservedFailedInput = await preserveFailedTranscribeInput(
      inputPath,
      config.tempDir,
    ).catch(() => false);
    throw error;
  } finally {
    await Promise.allSettled([
      preservedFailedInput ? Promise.resolve() : rm(inputPath, { force: true }),
      rm(wavPath, { force: true }),
    ]);
  }
}

async function preserveFailedTranscribeInput(
  inputPath: string,
  tempDir: string,
): Promise<boolean> {
  const extension = inputPath.split(".").pop() || "blob";
  const failedDir = join(tempDir, "failed");
  await mkdir(failedDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const failedPath = join(
    failedDir,
    `${stamp}-${crypto.randomUUID()}.${extension}`,
  );
  await rename(inputPath, failedPath);
  await pruneFailedTranscribeInputs(failedDir, FAILED_TRANSCRIBE_CAP);
  return true;
}

async function pruneFailedTranscribeInputs(
  failedDir: string,
  cap: number,
): Promise<void> {
  const entries = await Promise.all(
    (await readdir(failedDir)).map(async (name) => {
      const path = join(failedDir, name);
      const info = await stat(path).catch(() => null);
      return info?.isFile() ? { path, mtimeMs: info.mtimeMs } : null;
    }),
  );
  const files = entries
    .filter((entry): entry is { path: string; mtimeMs: number } =>
      Boolean(entry),
    )
    .sort((a, b) => a.mtimeMs - b.mtimeMs);
  const excess = Math.max(0, files.length - cap);
  await Promise.allSettled(
    files.slice(0, excess).map((entry) => rm(entry.path, { force: true })),
  );
}

async function handleTts(
  request: Request,
  config: VoiceReviewConfig,
  runCommand: CommandRunner,
  ttsEngines: VoiceReviewTtsEngines,
): Promise<Response> {
  const body = await request.json();
  if (!isRecord(body) || typeof body.text !== "string" || !body.text.trim()) {
    return jsonResponse({ error: "text is required" }, 400);
  }
  const started = performance.now();
  const id = crypto.randomUUID();
  const mp3Path = join(config.tempDir, `${id}.mp3`);
  const metadataPath = join(config.tempDir, `${id}.meta.ndjson`);
  const text = humanizeSpokenText(body.text).slice(0, 4000);
  const requestedVoice = typeof body.voice === "string" ? body.voice : "";
  const isClonedVoice =
    isSafeClonedVoiceName(requestedVoice) &&
    ttsEngines.hasClonedProfile(requestedVoice);
  const voice = isClonedVoice
    ? requestedVoice
    : typeof body.voice === "string" && isSafeEdgeTtsVoice(body.voice)
      ? body.voice
      : config.ttsVoice;
  const rate =
    typeof body.rate === "string" && isSafeEdgeTtsRate(body.rate)
      ? body.rate
      : config.ttsRate;
  await mkdir(config.tempDir, { recursive: true });
  try {
    if (isClonedVoice) {
      const audio = await ttsEngines.synthesizeCloned(text, voice);
      throwIfAborted(request.signal);
      if (!audio) {
        return jsonResponse(
          {
            error: "theo engine offline",
            fallback_voice: config.ttsVoice,
          },
          503,
        );
      }
      return new Response(new Uint8Array(audio), {
        status: 200,
        headers: {
          "content-type": "audio/mpeg",
          "cache-control": "no-store",
          "x-tts-ms": String(Math.round(performance.now() - started)),
          "x-tts-engine": "qwen3",
          "x-word-boundaries": "[]",
        },
      });
    }

    const python = resolveBinary("python3", [
      "/opt/homebrew/bin/python3",
      "/usr/local/bin/python3",
      "/usr/bin/python3",
    ]);
    if (!python) throw new Error("python3 not found");
    const result = await runCommand({
      args: [
        python,
        edgeTtsWordsScript(),
        `--text=${text}`,
        `--voice=${voice}`,
        `--rate=${rate}`,
        `--write-media=${mp3Path}`,
        `--write-metadata=${metadataPath}`,
      ],
      cwd: process.cwd(),
      env: processEnv(),
      signal: request.signal,
    });
    throwIfAborted(request.signal);
    assertSuccess(result, "edge-tts");
    const bytes = await readFile(mp3Path);
    const wordBoundaries = parseWordBoundaryMetadata(
      await readFile(metadataPath, "utf8").catch(() => ""),
    );
    return new Response(bytes, {
      status: 200,
      headers: {
        "content-type": "audio/mpeg",
        "cache-control": "no-store",
        "x-tts-ms": String(Math.round(performance.now() - started)),
        "x-tts-engine": "edge-tts",
        "x-word-boundaries": JSON.stringify(wordBoundaries),
      },
    });
  } finally {
    await Promise.allSettled([
      rm(mp3Path, { force: true }),
      rm(metadataPath, { force: true }),
    ]);
  }
}

function isSafeEdgeTtsVoice(value: string): boolean {
  return /^[a-z]{2,3}-[A-Z]{2,3}-[A-Za-z0-9]+Neural$/.test(value);
}

function isSafeClonedVoiceName(value: string): boolean {
  return /^[a-z0-9][a-z0-9-]{0,63}$/.test(value);
}

function isSafeEdgeTtsRate(value: string): boolean {
  return /^[+-](?:[0-9]|[1-9][0-9]|100)%$/.test(value);
}

export async function runShellCommand(
  call: CommandCall,
): Promise<CommandResult> {
  const started = performance.now();
  if (call.signal?.aborted) throw abortError();
  const proc = Bun.spawn(call.args, {
    cwd: call.cwd,
    env: call.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  let abortHandler: (() => void) | null = null;
  const completed = Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  const aborted = call.signal
    ? new Promise<never>((_resolve, reject) => {
        abortHandler = () => {
          void terminateProcessForAbort(proc).then(
            () => reject(abortError()),
            reject,
          );
        };
        call.signal?.addEventListener("abort", abortHandler, { once: true });
      })
    : null;
  try {
    const [stdout, stderr, exitCode] = aborted
      ? await Promise.race([completed, aborted])
      : await completed;
    throwIfAborted(call.signal);
    return {
      exitCode,
      stdout,
      stderr,
      durationMs: Math.round(performance.now() - started),
    };
  } finally {
    if (abortHandler) call.signal?.removeEventListener("abort", abortHandler);
  }
}

async function terminateProcessForAbort(
  proc: ReturnType<typeof Bun.spawn>,
): Promise<void> {
  proc.kill("SIGTERM");
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const exited = proc.exited.then(
    () => "exited" as const,
    () => "exited" as const,
  );
  const elapsed = new Promise<"timeout">((resolve) => {
    timeout = setTimeout(() => resolve("timeout"), SUBPROCESS_ABORT_GRACE_MS);
  });
  const result = await Promise.race([exited, elapsed]);
  if (timeout) clearTimeout(timeout);
  if (result === "timeout") {
    proc.kill("SIGKILL");
    await proc.exited.catch(() => undefined);
  }
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
    if (isRecord(preflight) && preflight.schema === KG_FLAG_DECISIONS_SCHEMA)
      return;
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
  const skipped =
    isRecord(decisions) && Array.isArray(decisions.skipped)
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

export function describeQueueState(
  stats: unknown,
  category: string,
): QueueState {
  const bucket =
    isRecord(stats) && isRecord(stats.per_category)
      ? stats.per_category[category]
      : null;
  if (!isRecord(bucket) || numericStat(bucket.total) <= 0) {
    return {
      kind: "empty",
      category,
      decided: 0,
      message: `No items found for category ${category}.`,
    };
  }

  const total = numericStat(bucket.total);
  const undecided = numericStat(bucket.undecided);
  const countedDecisions =
    numericStat(bucket.explicit) +
    numericStat(bucket.by_rule) +
    numericStat(bucket.skipped);
  const decided = Math.max(total - undecided, countedDecisions, 0);
  if (undecided <= 0) {
    return {
      kind: "complete",
      category,
      decided,
      message: `All items in this queue are complete 🎉 ${decided} decided.`,
    };
  }

  return {
    kind: "empty",
    category,
    decided,
    message: `No items found for category ${category}.`,
  };
}

function describeQueueStatsError(category: string, error: string): QueueState {
  return {
    kind: "error",
    category,
    decided: 0,
    message: `Stats unavailable: ${error}`,
  };
}

function numericStat(value: unknown): number {
  const numeric = typeof value === "number" ? value : Number(value || 0);
  return Number.isFinite(numeric) ? numeric : 0;
}

async function loadVocabularyPrompt(path: string): Promise<string> {
  try {
    const raw = await readFile(path, "utf8");
    const parsed = JSON.parse(raw);
    const terms =
      isRecord(parsed) && Array.isArray(parsed.prompt_terms)
        ? parsed.prompt_terms
        : [];
    return buildWhisperPrompt(terms, 224);
  } catch {
    return buildWhisperPrompt(
      ["VoiceLayer", "BrainLayer", "Cantaloupe AI"],
      224,
    );
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
  const basename =
    batchPath.split("/").pop() || "kg-phase1-flag-batch-2026-06-05.json";
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

function normalizeInterpretAction(action: unknown): InterpretAction {
  if (action === "update") return "update";
  if (action === "merge" || action === "merge_all") return "merge";
  if (action === "keep" || action === "keep_all") return "keep";
  if (action === "mixed" || action === "skip" || action === "question")
    return action;
  throw new Error(`invalid interpreted action: ${String(action)}`);
}

function normalizeLegacySource(
  source: unknown,
): "voice" | "explicit" | "rule" | "voice-rule" {
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
    const canonical = cluster.members.find(
      (member) => member.id === canonicalId,
    );
    if (canonical) return canonical;
    throw new Error(
      `canonical_id ${canonicalId} is not in ${cluster.cluster_id}`,
    );
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
    throw new Error(commandFailureMessage(result, label));
  }
}

function commandFailureMessage(result: CommandResult, label: string): string {
  return `${label} failed with exit ${result.exitCode}: ${result.stderr.slice(0, 800)}`;
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

export function parseWordBoundaryMetadata(raw: string): WordBoundary[] {
  return raw
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const parsed = JSON.parse(line);
      if (!isRecord(parsed) || parsed.type !== "WordBoundary") return null;
      const offset = Number(parsed.offset);
      const duration = Number(parsed.duration);
      const text = typeof parsed.text === "string" ? parsed.text : "";
      if (!Number.isFinite(offset) || !Number.isFinite(duration) || !text) {
        return null;
      }
      return {
        offset_ms: Math.round(offset / 10_000),
        duration_ms: Math.round(duration / 10_000),
        text,
      };
    })
    .filter((item): item is WordBoundary => Boolean(item));
}

function normalizeInterruptionContext(
  value: unknown,
): InterruptionContext | null {
  if (!isRecord(value)) return null;
  const spoken =
    typeof value.agent_speech_spoken_so_far === "string"
      ? value.agent_speech_spoken_so_far.trim()
      : "";
  const remainder =
    typeof value.agent_speech_unspoken_remainder === "string"
      ? value.agent_speech_unspoken_remainder.trim()
      : "";
  const interruptedAtMs = Number(value.interrupted_at_ms);
  if (!spoken && !remainder) return null;
  if (!Number.isFinite(interruptedAtMs) || interruptedAtMs < 0) return null;
  return {
    agent_speech_spoken_so_far: spoken,
    agent_speech_unspoken_remainder: remainder,
    interrupted_at_ms: Math.round(interruptedAtMs),
  };
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

function evidenceScript(): string {
  return join(import.meta.dir, "kg_evidence.py");
}

function edgeTtsWordsScript(): string {
  return join(import.meta.dir, "../../scripts/edge-tts-words.py");
}

function driverEnv(config: VoiceReviewConfig): Record<string, string> {
  return {
    ...processEnv(),
    PYTHONPATH: join(config.brainlayerWorktree, "src"),
  };
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

function contentTypeForAsset(name: string): string {
  if (name.endsWith(".wasm")) return "application/wasm";
  if (name.endsWith(".mjs") || name.endsWith(".js")) {
    return "text/javascript; charset=utf-8";
  }
  if (name.endsWith(".map")) return "application/json; charset=utf-8";
  return "application/octet-stream";
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

function isConversationHistory(value: unknown): value is ConversationTurn[] {
  return (
    Array.isArray(value) &&
    value.every(
      (turn) =>
        isRecord(turn) &&
        typeof turn.question === "string" &&
        typeof turn.answer === "string",
    )
  );
}

function normalizeUnderstandingState(
  value: Record<string, unknown>,
  cluster: ReviewCluster,
): UnderstandingState {
  const memberUpdates: Record<string, MemberUnderstanding> = {};
  if (isRecord(value.member_updates)) {
    for (const [id, update] of Object.entries(value.member_updates)) {
      if (isMemberUnderstanding(update)) memberUpdates[id] = update;
    }
  }
  const notes = Array.isArray(value.notes)
    ? value.notes.filter((note): note is string => typeof note === "string")
    : [];
  return createUnderstandingState(cluster, {
    cluster_id: cluster.cluster_id,
    member_updates: memberUpdates,
    notes,
    remaining_question:
      typeof value.remaining_question === "string"
        ? value.remaining_question
        : undefined,
    canonical_id:
      typeof value.canonical_id === "string" ? value.canonical_id : undefined,
  });
}

function parseConversationEvidence(
  stdout: string,
  cluster: ReviewCluster,
): ConversationEvidence {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch (error) {
    throw new Error(
      `evidence helper returned invalid JSON: ${errorMessage(error)}`,
    );
  }
  if (!isRecord(parsed) || !Array.isArray(parsed.members)) {
    throw new Error("evidence helper returned invalid evidence payload");
  }

  const membersById = new Map(
    cluster.members.map((member) => [member.id, member]),
  );
  const evidenceMembers: ConversationEvidenceMember[] = [];
  for (const rawMember of parsed.members) {
    if (!isRecord(rawMember) || typeof rawMember.id !== "string") continue;
    const clusterMember = membersById.get(rawMember.id);
    if (!clusterMember) continue;
    const snippets = Array.isArray(rawMember.snippets)
      ? rawMember.snippets.filter(isEvidenceSnippet)
      : [];
    evidenceMembers.push({ ...clusterMember, snippets });
  }

  return { members: evidenceMembers };
}

function isEvidenceSnippet(value: unknown): value is EvidenceSnippet {
  if (!isRecord(value)) return false;
  return (
    typeof value.chunk_id === "string" &&
    typeof value.text === "string" &&
    (value.project === null || typeof value.project === "string") &&
    (value.content_type === null || typeof value.content_type === "string") &&
    (value.source === null || typeof value.source === "string") &&
    (value.created_at === null || typeof value.created_at === "string") &&
    (value.relevance === null || typeof value.relevance === "number") &&
    (value.context === null || typeof value.context === "string")
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isAbortError(error: unknown): boolean {
  if (error instanceof DOMException && error.name === "AbortError") return true;
  if (error instanceof Error && error.name === "AbortError") return true;
  return false;
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw abortError();
}

function abortError(): DOMException {
  return new DOMException("request aborted", "AbortError");
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

const DEFAULT_REVIEW_CATEGORIES = [
  "diagnosis-flag",
  "sep-variants",
  "identical-name",
  "case-only",
  "prefix-variants",
];

async function loadAvailableCategories(
  config: VoiceReviewConfig,
): Promise<string[]> {
  const categories = new Set<string>([
    config.defaultCategory,
    ...DEFAULT_REVIEW_CATEGORIES,
  ]);
  try {
    const parsed = JSON.parse(await readFile(config.batchPath, "utf8"));
    if (isRecord(parsed)) {
      for (const category of Object.keys(parsed)) {
        if (category.trim()) categories.add(category);
      }
    }
  } catch {
    // Keep the page usable with defaults when the batch is unavailable.
  }
  return [...categories];
}

const FRIENDLY_VOICE_NAMES: Record<string, string> = {
  "en-US-GuyNeural": "Guy — US English",
  "en-US-JennyNeural": "Jenny — US English",
  "en-US-AndrewNeural": "Andrew — US English",
  "en-US-BrianMultilingualNeural": "Brian — Multilingual",
  "en-US-AvaNeural": "Ava — US English",
  "en-US-AriaNeural": "Aria — US English",
};

function friendlyVoiceName(voice: string): string {
  return FRIENDLY_VOICE_NAMES[voice] || voice;
}

function escapeHtmlAttribute(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function renderNaturalConversationPage(
  config: VoiceReviewConfig,
  availableCategories: string[],
  ttsEngines: VoiceReviewTtsEngines = DEFAULT_TTS_ENGINES,
): string {
  const defaultCategory = config.defaultCategory;
  const ttsVoices = [
    "en-US-GuyNeural",
    "en-US-JennyNeural",
    "en-US-AndrewNeural",
    "en-US-BrianMultilingualNeural",
    "en-US-AvaNeural",
    "en-US-AriaNeural",
  ];
  const clonedVoices = ttsEngines.listClonedProfiles();
  const clonedVoiceSetJson = JSON.stringify(clonedVoices);
  const edgeFallbackVoice = ttsVoices.includes(config.ttsVoice)
    ? config.ttsVoice
    : DEFAULT_CONFIG.ttsVoice;
  const selectedVoice =
    ttsVoices.includes(config.ttsVoice) ||
    clonedVoices.includes(config.ttsVoice)
      ? config.ttsVoice
      : DEFAULT_CONFIG.ttsVoice;
  const parsedRate = Number.parseInt(config.ttsRate.replace("%", ""), 10);
  const selectedRate = Number.isFinite(parsedRate)
    ? Math.max(-30, Math.min(10, parsedRate))
    : -8;
  const selectedRateLabel = `${selectedRate >= 0 ? "+" : ""}${selectedRate}%`;
  const finishSessionEnabled = Boolean(config.finishCommand.trim());
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Voice Review</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Newsreader:ital,opsz,wght@0,6..72,400..700;1,6..72,400..700&family=Schibsted+Grotesk:wght@400..700&display=swap" rel="stylesheet">
  <script>
    // Theme boot: apply persisted manual override before first paint.
    (function () {
      try {
        var stored = localStorage.getItem("vr-theme");
        if (stored === "light" || stored === "dark") {
          document.documentElement.setAttribute("data-theme", stored);
        }
      } catch (_error) {}
    })();
  </script>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #F6F5F1;
      --surface: #FFFFFF;
      --surface-2: #FBFAF8;
      --line: #E6E3DC;
      --line-soft: #EFEDE7;
      --ink: #1C2024;
      --ink-2: #5A636C;
      --ink-3: #8A929A;
      --voice: #0E7C72;
      --voice-deep: #0A574F;
      --voice-bright: #43BBAD;
      --voice-soft: #E4F2F0;
      --user: #2563EB;
      --user-soft: #EDF3FE;
      --settle: #C2801F;
      --settle-soft: #FBF3E4;
      --error: #AE4434;
      --error-soft: #FBEFEC;
      --good: #2E7D4F;
      --good-soft: #E9F5EE;
      --r-card: 16px;
      --shadow-1: 0 1px 2px rgb(28 32 36 / .05);
      --shadow-2: 0 16px 40px -20px rgb(28 32 36 / .18);
      --orb-glow: .18;
      --wash-a: rgb(14 124 114 / .07);
      --wash-b: rgb(37 99 235 / .04);
      --font-ui: "Schibsted Grotesk", ui-sans-serif, system-ui, -apple-system, sans-serif;
      --font-display: "Newsreader", ui-serif, Georgia, serif;
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --bg: #14171A;
        --surface: #1C2024;
        --surface-2: #181C1F;
        --line: #2B3137;
        --line-soft: #23282D;
        --ink: #ECEEF0;
        --ink-2: #9BA4AD;
        --ink-3: #7A838C;
        --voice: #17988B;
        --voice-deep: #0E6B61;
        --voice-bright: #4FD1C5;
        --voice-soft: #12302D;
        --user: #5B8DEF;
        --user-soft: #1A2436;
        --settle: #D99A3D;
        --settle-soft: #2E2417;
        --error: #D06A57;
        --error-soft: #321D19;
        --good: #4CAF7A;
        --good-soft: #16281E;
        --shadow-1: 0 1px 2px rgb(0 0 0 / .35);
        --shadow-2: 0 16px 40px -20px rgb(0 0 0 / .55);
        --orb-glow: .25;
        --wash-a: rgb(23 152 139 / .10);
        --wash-b: rgb(91 141 239 / .06);
      }
    }
    [data-theme="dark"] {
      --bg: #14171A;
      --surface: #1C2024;
      --surface-2: #181C1F;
      --line: #2B3137;
      --line-soft: #23282D;
      --ink: #ECEEF0;
      --ink-2: #9BA4AD;
      --ink-3: #7A838C;
      --voice: #17988B;
      --voice-deep: #0E6B61;
      --voice-bright: #4FD1C5;
      --voice-soft: #12302D;
      --user: #5B8DEF;
      --user-soft: #1A2436;
      --settle: #D99A3D;
      --settle-soft: #2E2417;
      --error: #D06A57;
      --error-soft: #321D19;
      --good: #4CAF7A;
      --good-soft: #16281E;
      --shadow-1: 0 1px 2px rgb(0 0 0 / .35);
      --shadow-2: 0 16px 40px -20px rgb(0 0 0 / .55);
      --orb-glow: .25;
      --wash-a: rgb(23 152 139 / .10);
      --wash-b: rgb(91 141 239 / .06);
    }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    html, body { height: 100%; }
    body {
      margin: 0;
      font-family: var(--font-ui);
      font-size: 15px;
      line-height: 1.5;
      background:
        radial-gradient(900px 600px at 18% -8%, var(--wash-a), transparent 60%),
        radial-gradient(700px 520px at 94% 10%, var(--wash-b), transparent 55%),
        var(--bg);
      background-attachment: fixed;
      color: var(--ink);
    }
    h1, h2, h3, p { margin: 0; }
    button, select, input { font: inherit; color: inherit; }
    :is(button, select, summary, input, a):focus-visible {
      outline: 2px solid var(--voice);
      outline-offset: 2px;
      border-radius: 6px;
    }
    .sr-only {
      position: absolute;
      width: 1px;
      height: 1px;
      overflow: hidden;
      clip: rect(0 0 0 0);
      white-space: nowrap;
    }

    /* ── Header (quiet chrome) ─────────────────────────────── */
    header {
      display: grid;
      grid-template-columns: 1fr auto 1fr;
      align-items: center;
      gap: 12px;
      padding: 14px clamp(16px, 3vw, 28px);
    }
    .wordmark {
      font-family: var(--font-display);
      font-style: italic;
      font-weight: 600;
      font-size: 19px;
      letter-spacing: 0.01em;
    }
    .session-meta {
      justify-self: center;
      color: var(--ink-2);
      font-size: 13px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .header-actions {
      justify-self: end;
      display: flex;
      align-items: center;
      gap: 10px;
      position: relative;
    }
    .end-pill {
      padding: 7px 16px;
      border: 1px solid var(--line);
      border-radius: 999px;
      background: var(--surface);
      color: var(--ink-2);
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
      transition: color 140ms ease, border-color 140ms ease;
    }
    .end-pill:hover { color: var(--error); border-color: var(--error); }
    .end-pill:disabled { opacity: .6; cursor: wait; }

    /* ── Gear popover ──────────────────────────────────────── */
    details.gear { position: relative; }
    details.gear > summary {
      list-style: none;
      display: grid;
      place-items: center;
      width: 34px;
      height: 34px;
      border: 1px solid var(--line);
      border-radius: 999px;
      background: var(--surface);
      color: var(--ink-2);
      cursor: pointer;
    }
    details.gear > summary::-webkit-details-marker { display: none; }
    details.gear[open] > summary { color: var(--voice); border-color: var(--voice); }
    .gear-panel {
      position: absolute;
      right: 0;
      top: 42px;
      z-index: 60;
      width: 300px;
      display: grid;
      gap: 14px;
      padding: 16px;
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: var(--r-card);
      box-shadow: var(--shadow-2);
    }
    .gear-field { display: grid; gap: 5px; }
    .gear-label {
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--ink-3);
    }
    .gear-panel select {
      width: 100%;
      padding: 8px 10px;
      border: 1px solid var(--line);
      border-radius: 10px;
      background: var(--surface-2);
    }
    .gear-panel select option:disabled { color: var(--ink-3); font-style: italic; }
    .voice-engine-note { font-size: 13px; color: var(--settle); }
    .rate-row { display: flex; gap: 8px; align-items: center; }
    .rate-row input[type="range"] { flex: 1; accent-color: var(--voice); }
    .rate-row output { min-width: 36px; font-size: 13px; color: var(--ink-2); text-align: right; }
    .theme-row { display: flex; gap: 6px; }
    .theme-row button {
      flex: 1;
      padding: 7px 0;
      border: 1px solid var(--line);
      border-radius: 999px;
      background: var(--surface-2);
      color: var(--ink-2);
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
    }
    .theme-row button[aria-pressed="true"] {
      background: var(--voice-soft);
      border-color: var(--voice);
      color: var(--voice);
    }
    .status-dots { display: grid; gap: 6px; font-size: 13px; color: var(--ink-2); }
    .status-dots .dot-row { display: flex; gap: 8px; align-items: baseline; }
    .status-dots .dot {
      width: 8px;
      height: 8px;
      border-radius: 999px;
      background: var(--ink-3);
      flex: none;
      align-self: center;
    }
    .status-dots .pill { color: var(--ink-2); }
    .status-dots .pill.basic { color: var(--settle); }
    .status-dots .pill.basic ~ * { color: var(--settle); }

    /* ── Stage ─────────────────────────────────────────────── */
    main {
      display: grid;
      justify-items: center;
      gap: 18px;
      padding: 0 20px 48px;
      max-width: 860px;
      margin: 0 auto;
    }
    .stage {
      display: grid;
      justify-items: center;
      gap: 14px;
      text-align: center;
      padding: clamp(24px, 5vh, 56px) 0 clamp(16px, 3vh, 32px);
      width: 100%;
    }
    .stage[data-state="idle"], .stage[data-state="complete"], .stage[data-state="empty"], .stage[data-state="error"] {
      min-height: 52vh;
      align-content: center;
    }
    .orb-wrap {
      position: relative;
      width: 112px;
      height: 112px;
      display: grid;
      place-items: center;
      margin-bottom: 6px;
    }
    .orb {
      --level: 0;
      position: relative;
      width: 112px;
      height: 112px;
      border-radius: 50%;
      background: radial-gradient(circle at 32% 28%, var(--voice-bright), var(--voice) 58%, var(--voice-deep) 100%);
      box-shadow: var(--shadow-2), 0 0 0 calc(var(--level) * 14px) rgb(14 124 114 / var(--orb-glow));
      transition: transform 90ms linear, filter 300ms ease, background 300ms ease, box-shadow 90ms linear;
      display: grid;
      place-items: center;
    }
    .orb-glyph {
      opacity: 0;
      transition: opacity 400ms ease 150ms;
      color: #fff;
      display: grid;
      place-items: center;
    }
    .orb-glyph svg { width: 44px; height: 44px; }
    .orb-glyph.glyph-error {
      font-family: var(--font-display);
      font-size: 46px;
      font-weight: 600;
      line-height: 1;
    }
    .orb-ring {
      --settle-progress: 0;
      position: absolute;
      inset: -11px;
      border-radius: 50%;
      background: conic-gradient(var(--settle) calc(var(--settle-progress) * 1turn), transparent 0);
      -webkit-mask: radial-gradient(farthest-side, transparent calc(100% - 5px), #000 calc(100% - 4px));
      mask: radial-gradient(farthest-side, transparent calc(100% - 5px), #000 calc(100% - 4px));
      opacity: 0;
      transition: opacity 200ms ease;
      pointer-events: none;
    }
    .orb-arc {
      position: absolute;
      inset: -13px;
      border-radius: 50%;
      border: 2px solid transparent;
      border-top-color: var(--voice);
      opacity: 0;
      transition: opacity 200ms ease;
      pointer-events: none;
    }
    .ripple, .ripple::after { pointer-events: none; }
    .ripple {
      position: absolute;
      inset: 0;
      border-radius: 50%;
      opacity: 0;
    }
    .ripple::before, .ripple::after {
      content: "";
      position: absolute;
      inset: 0;
      border-radius: 50%;
      border: 2px solid var(--voice-bright);
      opacity: 0;
    }
    @keyframes orb-breathe {
      0%, 100% { transform: scale(1); }
      50% { transform: scale(1.045); }
    }
    @keyframes orb-ripple {
      from { transform: scale(1); opacity: .45; }
      to { transform: scale(1.9); opacity: 0; }
    }
    @keyframes orb-spin {
      to { transform: rotate(1turn); }
    }
    @keyframes orb-arrive {
      from { transform: scale(.7); opacity: 0; }
      to { transform: scale(1); opacity: 1; }
    }
    /* state choreography — driven ONLY by [data-state] from renderState() */
    .stage[data-state="idle"] .orb { animation: orb-breathe 4.5s ease-in-out infinite; }
    .stage[data-state="listening"] .orb { transform: scale(calc(0.96 + var(--level) * 0.10)); }
    .stage[data-state="listening"] .ripple { opacity: 1; }
    .stage[data-state="listening"] .ripple::before { animation: orb-ripple 2s ease-out infinite; }
    .stage[data-state="listening"] .ripple::after { animation: orb-ripple 2s ease-out infinite 1s; }
    .stage[data-state="settling"] .orb { filter: saturate(.75); }
    .stage[data-state="settling"] .orb-ring { opacity: 1; }
    .stage[data-state="thinking"] .orb { transform: scale(.86); filter: saturate(.6); }
    .stage[data-state="thinking"] .orb-arc { opacity: 1; animation: orb-spin 1.4s linear infinite; }
    .stage[data-state="speaking"] .orb {
      filter: saturate(1.12) brightness(1.05);
      transform: scale(calc(0.98 + var(--level) * 0.06));
    }
    .stage[data-state="error"] .orb {
      background: radial-gradient(circle at 32% 28%, #B9BDC1, #8A929A 58%, #5A636C 100%);
      animation: none;
    }
    .stage[data-state="error"] .glyph-error { opacity: 1; }
    .stage[data-state="complete"] .orb {
      background: radial-gradient(circle at 32% 28%, #7FD8A4, var(--good) 58%, #1D5637 100%);
      animation: orb-arrive 420ms ease-out;
    }
    .stage[data-state="complete"] .glyph-check { opacity: 1; }
    .stage[data-state="empty"] .orb { filter: saturate(.55); opacity: .85; }
    @media (prefers-reduced-motion: reduce) {
      .orb, .orb-ring, .orb-arc, .ripple::before, .ripple::after { animation: none !important; }
      .orb { transition: opacity 200ms ease, background 200ms ease; transform: none !important; }
    }
    .status-line {
      min-height: 22px;
      font-size: 15px;
      line-height: 1.45;
      color: var(--ink-2);
      overflow-wrap: anywhere;
    }
    .caption {
      font-family: var(--font-display);
      font-size: clamp(22px, 3.4vw, 31px);
      font-weight: 500;
      line-height: 1.22;
      max-width: 24em;
      overflow-wrap: anywhere;
    }
    .caption .w { opacity: .42; transition: opacity 120ms ease; }
    .caption .w.spoken { opacity: 1; }
    .hint {
      min-height: 20px;
      font-size: 13px;
      color: var(--ink-3);
    }
    .stage-banner {
      display: inline-flex;
      align-items: center;
      gap: 9px;
      padding: 9px 16px;
      border-radius: 999px;
      background: var(--error-soft);
      color: var(--error);
      font-size: 14px;
      font-weight: 600;
      max-width: 100%;
      overflow-wrap: anywhere;
    }
    .stage-banner.notice { background: var(--settle-soft); color: var(--settle); }
    .banner-dot {
      width: 8px;
      height: 8px;
      border-radius: 999px;
      background: currentColor;
      flex: none;
      animation: banner-pulse 1.6s ease-in-out infinite;
    }
    @keyframes banner-pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: .35; }
    }
    @media (prefers-reduced-motion: reduce) {
      .banner-dot { animation: none; }
    }
    .stage-stats {
      display: flex;
      gap: 8px;
      font-size: 14px;
      color: var(--ink-2);
    }
    .begin {
      margin-top: 6px;
      padding: 13px 28px;
      border: 0;
      border-radius: 999px;
      background: var(--voice);
      color: #fff;
      font-size: 15px;
      font-weight: 600;
      cursor: pointer;
      box-shadow: var(--shadow-2);
      transition: transform 120ms ease, background 140ms ease;
    }
    .begin:hover { background: var(--voice-deep); transform: translateY(-1px); }
    .begin:disabled { opacity: .6; cursor: wait; transform: none; }
    .stage-secondary {
      margin-top: 6px;
      padding: 10px 22px;
      border: 1px solid var(--line);
      border-radius: 999px;
      background: var(--surface);
      color: var(--ink-2);
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
    }
    .stage-secondary:hover { color: var(--voice); border-color: var(--voice); }

    /* ── Workbench ─────────────────────────────────────────── */
    .workbench {
      width: 100%;
      display: grid;
      gap: 18px;
    }
    .card {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: var(--r-card);
      box-shadow: var(--shadow-1);
      padding: 20px 22px;
    }
    .card-head {
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      gap: 12px;
      margin-bottom: 6px;
    }
    .card-title {
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--ink-3);
    }
    .cluster-meta { font-size: 13px; color: var(--ink-2); white-space: nowrap; }
    h2#stem {
      font-family: var(--font-display);
      font-size: clamp(26px, 4vw, 34px);
      font-weight: 600;
      line-height: 1.1;
      overflow-wrap: anywhere;
      margin-bottom: 8px;
    }
    .members { display: grid; }
    .member {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 12px;
      align-items: center;
      padding: 11px 0;
      border-top: 1px solid var(--line-soft);
      transition: opacity 140ms ease;
    }
    .member:first-child { border-top: 0; }
    .member.is-resolved { opacity: .62; }
    .member-name { font-weight: 600; overflow-wrap: anywhere; }
    .member.not-relevant .member-name { text-decoration: line-through; color: var(--ink-2); }
    .member-meta { margin-top: 1px; color: var(--ink-3); font-size: 13px; overflow-wrap: anywhere; }
    .member-tag {
      justify-self: end;
      padding: 4px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 600;
      background: var(--surface-2);
      border: 1px solid var(--line-soft);
      color: var(--ink-2);
      white-space: nowrap;
    }
    .member-tag.keep { background: var(--good-soft); border-color: transparent; color: var(--good); }
    .member-tag.merge { background: var(--user-soft); border-color: transparent; color: var(--user); }
    .member-tag.irrelevant { background: var(--error-soft); border-color: transparent; color: var(--error); }

    .log { display: grid; gap: 10px; }
    .turn {
      max-width: 82%;
      padding: 10px 14px;
      border-radius: 14px;
      line-height: 1.45;
      overflow-wrap: anywhere;
      box-shadow: var(--shadow-1);
    }
    .turn.agent {
      justify-self: start;
      background: var(--surface);
      border: 1px solid var(--line);
      border-bottom-left-radius: 5px;
    }
    .turn.user {
      justify-self: end;
      background: var(--user-soft);
      color: var(--ink);
      border-bottom-right-radius: 5px;
    }
    .turn.system {
      justify-self: center;
      max-width: 92%;
      background: transparent;
      box-shadow: none;
      color: var(--ink-3);
      font-size: 13px;
      text-align: center;
      padding: 2px 8px;
    }
    .turn-label { display: none; }
    .turn.system .turn-label { display: none; }
    .bubble.paused {
      justify-self: start;
      max-width: 82%;
      padding: 10px 14px;
      border-radius: 14px;
      border-bottom-left-radius: 5px;
      border: 1px dashed var(--line);
      background: var(--surface-2);
      color: var(--ink-2);
      line-height: 1.45;
      overflow-wrap: anywhere;
    }
    .resume-chip {
      margin-top: 8px;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 5px 12px;
      border: 1px solid var(--voice);
      border-radius: 999px;
      background: var(--voice-soft);
      color: var(--voice);
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
    }

    details.disclosure {
      border: 1px solid var(--line);
      border-radius: 12px;
      background: var(--surface-2);
      padding: 12px 16px;
    }
    details.disclosure > summary {
      cursor: pointer;
      font-size: 13px;
      font-weight: 600;
      color: var(--ink-2);
      list-style-position: inside;
    }
    .disclosure-body { display: grid; gap: 10px; margin-top: 10px; font-size: 13px; color: var(--ink-2); }
    .evidence-item { border-top: 1px solid var(--line-soft); padding-top: 10px; overflow-wrap: anywhere; }
    .evidence-item:first-child { border-top: 0; padding-top: 0; }
    .evidence-text { color: var(--ink); }
    .evidence-meta { margin-top: 3px; font-size: 12px; color: var(--ink-3); }
    .decision-sentence { color: var(--ink); }
    pre.decision-json {
      margin: 0;
      white-space: pre-wrap;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      color: var(--ink-2);
      overflow-wrap: anywhere;
    }

    /* ── Debug strip (?debug=1) ────────────────────────────── */
    .debug-strip {
      position: fixed;
      left: 10px;
      bottom: 10px;
      z-index: 80;
      display: flex;
      gap: 6px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 11px;
      color: var(--ink-2);
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 5px 8px;
      box-shadow: var(--shadow-1);
    }
    audio { display: none; }
    @media (max-width: 700px) {
      header { grid-template-columns: auto 1fr auto; }
      .session-meta { justify-self: start; }
      .gear-panel { right: -52px; width: min(300px, calc(100vw - 28px)); }
      .turn { max-width: 92%; }
    }
  </style>
</head>
<body>
  <header>
    <div class="wordmark">Voice Review</div>
    <div id="sessionMeta" class="session-meta">${escapeHtmlAttribute(defaultCategory)}</div>
    <div class="header-actions">
      <details id="gearPopover" class="gear">
        <summary aria-label="Settings" role="button">
          <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/></svg>
        </summary>
        <div class="gear-panel">
          <div class="gear-field">
            <span class="gear-label">Category</span>
            <select id="category" aria-label="Category">
              ${availableCategories
                .map(
                  (category) =>
                    `<option value="${escapeHtmlAttribute(category)}"${category === defaultCategory ? " selected" : ""}>${escapeHtmlAttribute(category)}</option>`,
                )
                .join("")}
            </select>
          </div>
          <div class="gear-field">
            <span class="gear-label">Voice</span>
            <select id="ttsVoice" class="tts-voice-picker" aria-label="TTS voice">
              ${
                clonedVoices.length
                  ? `<optgroup label="Theo (cloned)" class="tts-voice-group tts-voice-group-cloned">${clonedVoices
                      .map(
                        (voice) =>
                          `<option class="tts-voice-option tts-voice-option-cloned" value="${escapeHtmlAttribute(voice)}"${voice === selectedVoice ? " selected" : ""}>${escapeHtmlAttribute(voice)}</option>`,
                      )
                      .join("")}</optgroup>`
                  : ""
              }
              <optgroup label="Edge voices" class="tts-voice-group tts-voice-group-edge">
                ${ttsVoices
                  .map(
                    (voice) =>
                      `<option class="tts-voice-option tts-voice-option-edge" value="${voice}"${voice === selectedVoice ? " selected" : ""}>${friendlyVoiceName(voice)}</option>`,
                  )
                  .join("")}
              </optgroup>
            </select>
            <span id="voiceEngineNote" class="voice-engine-note" hidden></span>
          </div>
          <div class="gear-field">
            <span class="gear-label">Rate</span>
            <span class="rate-row">
              <input id="ttsRate" type="range" min="-30" max="10" step="1" value="${selectedRate}" aria-label="TTS rate">
              <output id="ttsRateValue">${selectedRateLabel}</output>
            </span>
          </div>
          <div class="gear-field">
            <span class="gear-label">Appearance</span>
            <span class="theme-row" role="group" aria-label="Theme">
              <button id="themeSystem" type="button" aria-pressed="true">System</button>
              <button id="themeLight" type="button" aria-pressed="false">Light</button>
              <button id="themeDark" type="button" aria-pressed="false">Dark</button>
            </span>
          </div>
          <div class="gear-field">
            <span class="gear-label">Status</span>
            <div class="status-dots">
              <div class="dot-row"><span class="dot" aria-hidden="true"></span><span id="healthMode" class="pill">Local brain</span></div>
              <div class="dot-row"><span class="dot" aria-hidden="true"></span><span id="vadMode" class="pill">Voice detection</span></div>
            </div>
          </div>
        </div>
      </details>
      <button id="sessionButton" class="end-pill" type="button" hidden>Start session</button>
    </div>
  </header>

  <main>
    <section id="stage" class="stage" data-state="idle" aria-label="Conversation stage">
      <div class="orb-wrap" aria-hidden="true">
        <div class="ripple"></div>
        <div id="settleRing" class="orb-ring"></div>
        <div class="orb-arc"></div>
        <div id="orb" class="orb">
          <span class="orb-glyph glyph-error">!</span>
          <span class="orb-glyph glyph-check">
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>
          </span>
        </div>
      </div>
      <span id="phaseAnnouncer" class="sr-only" role="status" aria-live="polite"></span>
      <div id="status" class="status-line" role="status" aria-live="polite"></div>
      <div id="caption" class="caption">Review knowledge-graph clusters by voice.</div>
      <div id="hint" class="hint"></div>
      <div id="stageBanner" class="stage-banner" hidden><span class="banner-dot" aria-hidden="true"></span><span id="stageBannerText"></span></div>
      <div id="stageStats" class="stage-stats" hidden></div>
      <button id="beginButton" class="begin" type="button">Begin review</button>
      <button id="stageAction" class="stage-secondary" type="button" hidden></button>
    </section>

    <section id="workbench" class="workbench" hidden aria-label="Review workbench">
      <div class="card">
        <div class="card-head">
          <span class="card-title">Current cluster</span>
          <span id="clusterMeta" class="cluster-meta"></span>
        </div>
        <h2 id="stem"></h2>
        <div id="members" class="members"></div>
      </div>

      <div id="pausedUtterance" class="bubble paused" aria-label="paused utterance" hidden>
        <div id="pausedText"></div>
        <button id="resumePlayback" class="resume-chip" type="button">&#9654; Resume</button>
      </div>
      <div id="turnLog" class="log" aria-live="polite"></div>

      <details id="evidencePanel" class="disclosure">
        <summary>Evidence</summary>
        <div class="disclosure-body">
          <div id="evidenceStatus">No evidence fetched.</div>
          <div id="evidenceBody"></div>
        </div>
      </details>

      <details id="decisionPanel" class="disclosure">
        <summary>Last decision</summary>
        <div class="disclosure-body">
          <div id="decisionSentence" class="decision-sentence">Waiting for a resolved cluster.</div>
          <pre id="decision" class="decision-json"></pre>
        </div>
      </details>
    </section>
  </main>

  <div id="debugStrip" class="debug-strip" hidden></div>
  <audio id="audio" preload="auto"></audio>

  <script type="module">
    import * as ort from "/vendor/onnxruntime-web/ort.wasm.min.mjs";

    const TURN_STATE_DEFAULTS = {
      settleMs: 1300,
      frameMs: 32,
      playbackBargeInFrames: 3
    };
    const BROWSER_VAD_CHUNK_SAMPLES = 512;
    const BROWSER_VAD_CONTEXT_SAMPLES = 64;
    const BROWSER_VAD_INPUT_SAMPLES = 576;
    const SILERO_SPEECH_THRESHOLD = 0.5;
    const BASIC_RMS_THRESHOLD = 0.018;
    const PAUSE_INTENT_EXTENDED_SILENCE_MS = 10000;
    const HEALTH_FAILURE_ANNOUNCE_THRESHOLD = 3;
    const THINKING_PAUSE_PHRASES = ["wait", "hold on", "let me think", "hmm", "one sec", "רגע"];
    const CLONED_TTS_VOICES = new Set(${clonedVoiceSetJson});
    const EDGE_FALLBACK_VOICE = "${escapeHtmlAttribute(edgeFallbackVoice)}";

    function createTurnTakingState(overrides = {}) {
      return {
        phase: "LISTENING",
        config: Object.assign({}, TURN_STATE_DEFAULTS, overrides),
        hasSpeechInTurn: false,
        settleElapsedMs: 0,
        settleProgress: 0,
        showSettlingRing: false,
        playbackSpeechFrames: 0,
        pausePlayback: false,
        turnTaken: false
      };
    }

    function advanceTurnTakingFrame(current, frame) {
      const state = Object.assign({}, current, {
        config: Object.assign({}, current.config),
        pausePlayback: false,
        turnTaken: false
      });
      const speech = Boolean(frame.speech);
      if (state.phase === "SPEAKING") {
        if (speech) {
          state.playbackSpeechFrames += 1;
          if (state.playbackSpeechFrames >= state.config.playbackBargeInFrames) {
            state.phase = "LISTENING";
            state.hasSpeechInTurn = true;
            state.settleElapsedMs = 0;
            state.settleProgress = 0;
            state.showSettlingRing = false;
            state.playbackSpeechFrames = 0;
            state.pausePlayback = true;
          }
        } else {
          state.playbackSpeechFrames = 0;
        }
        return state;
      }
      if (state.phase === "THINKING") {
        if (speech) {
          state.phase = "LISTENING";
          state.hasSpeechInTurn = true;
        }
        return state;
      }
      if (speech) {
        state.phase = "LISTENING";
        state.hasSpeechInTurn = true;
        state.settleElapsedMs = 0;
        state.settleProgress = 0;
        state.showSettlingRing = false;
        return state;
      }
      if (!state.hasSpeechInTurn) {
        state.phase = "LISTENING";
        return state;
      }
      state.phase = "SETTLING";
      state.settleElapsedMs += state.config.frameMs;
      state.settleProgress = Math.min(1, state.settleElapsedMs / state.config.settleMs);
      state.showSettlingRing = state.settleProgress >= 0.6;
      if (state.settleElapsedMs >= state.config.settleMs) {
        state.phase = "THINKING";
        state.turnTaken = true;
        state.hasSpeechInTurn = false;
        state.settleElapsedMs = 0;
        state.settleProgress = 1;
        state.showSettlingRing = false;
      }
      return state;
    }

    function createSileroVadInput(chunk, context) {
      if (chunk.length !== BROWSER_VAD_CHUNK_SAMPLES) {
        throw new Error("Silero VAD chunk must contain 512 samples");
      }
      if (context.length !== BROWSER_VAD_CONTEXT_SAMPLES) {
        throw new Error("Silero VAD context must contain 64 samples");
      }
      const input = new Float32Array(BROWSER_VAD_INPUT_SAMPLES);
      input.set(context, 0);
      input.set(chunk, BROWSER_VAD_CONTEXT_SAMPLES);
      return {
        input,
        dims: [1, BROWSER_VAD_INPUT_SAMPLES],
        nextContext: input.slice(BROWSER_VAD_INPUT_SAMPLES - BROWSER_VAD_CONTEXT_SAMPLES)
      };
    }

    function createUnderstandingState(cluster, seed = {}) {
      const member_updates = {};
      for (const member of cluster?.members || []) {
        member_updates[member.id] = seed.member_updates?.[member.id] || "undecided";
      }
      return {
        cluster_id: cluster?.cluster_id || "",
        member_updates,
        notes: Array.isArray(seed.notes) ? seed.notes.slice() : [],
        remaining_question: seed.remaining_question || "",
        canonical_id: seed.canonical_id || ""
      };
    }

    function applyUnderstandingDelta(currentState, delta, cluster) {
      const state = createUnderstandingState(cluster, currentState);
      if (delta.canonical_id) state.canonical_id = delta.canonical_id;
      if (delta.remaining_question) state.remaining_question = delta.remaining_question;
      if (delta.note && String(delta.note).trim()) state.notes.push(String(delta.note).trim());
      for (const [id, value] of Object.entries(delta.member_updates || {})) {
        if (state.member_updates[id] && value !== "undecided") {
          state.member_updates[id] = value;
        }
      }
      if (delta.action !== "update" && delta.action !== "question") {
        return { state, terminalDecision: delta };
      }
      return { state, terminalDecision: composeFinalDecisionFromUnderstanding(state, cluster) };
    }

    function composeFinalDecisionFromUnderstanding(state, cluster) {
      const statuses = (cluster?.members || []).map((member) => state.member_updates[member.id]);
      if (!statuses.length || statuses.some((status) => !status || status === "undecided")) return null;
      const note = state.notes.join("\\n").trim() || "Resolved by voice conversation";
      if (statuses.every((status) => status === "keep")) return { action: "keep", note, source: "voice" };
      if (statuses.every((status) => status === "irrelevant")) return { action: "skip", note, source: "voice" };
      if (statuses.every((status) => status === "merge")) {
        return {
          action: "merge",
          canonical_id: state.canonical_id || cluster.members[0].id,
          note,
          source: "voice"
        };
      }
      const members = {};
      for (const member of cluster.members) {
        const status = state.member_updates[member.id];
        members[member.id] = status === "irrelevant" ? "prune" : status === "keep" ? "keep" : "merge";
      }
      return { action: "mixed", members, note, source: "voice" };
    }

    const $ = (id) => document.getElementById(id);
    const sessionButton = $("sessionButton");
    const category = $("category");
    const ttsVoice = $("ttsVoice");
    const ttsRate = $("ttsRate");
    const ttsRateValue = $("ttsRateValue");
    const audio = $("audio");
    let sessionActive = false;
    let current = null;
    let currentSpeak = "";
    let understanding = null;
    let stream = null;
    let audioContext = null;
    let processor = null;
    let micSource = null;
    let mediaRecorder = null;
    let collectingTurn = false;
    let flushingTurn = false;
    let turnChunks = [];
    let processingTurn = false;
    let vadState = {
      mode: "pending",
      session: null,
      state: null,
      sr: null,
      context: new Float32Array(BROWSER_VAD_CONTEXT_SAMPLES),
      pendingSamples: new Float32Array(0),
      queue: [],
      busy: false
    };
    let turnState = createTurnTakingState();
    let activePlayback = null;
    let pausedUtterance = null;
    let pendingInterruption = null;
    let systemSpeechActive = false;
    let systemSpeechToken = 0;
    let heldTranscript = "";
    let conversationHistory = [];
    let healthRetryTimer = null;
    let healthFailureStreak = 0;
    let nextHealthAnnouncementAt = 0;
    let healthAnnouncementBackoffMs = 3000;
    let healthRetryBackoffMs = 3000;
    let liteRtWorkInFlight = 0;
    let sessionAbortController = null;
    let finishingSession = false;
    let teardownPromise = null;
    let ttsFallbackAnnounced = false;
    // Stage view-state (presentation only — machine state lives in the vars above).
    let stageView = null; // { kind: "complete"|"empty"|"error", category, decided, message }
    let statusNote = "";
    let currentQuestion = "";
    let captionPlayback = null;
    let captionFrameHandle = null;
    let speakPulseLevel = 0;
    let voiceNoticeText = "";
    let voiceNoticeTimer = null;
    const debugEnabled = (() => {
      try {
        return new URLSearchParams(window.location?.search || "").get("debug") === "1";
      } catch (_error) {
        return false;
      }
    })();
    const finishSessionEnabled = ${JSON.stringify(finishSessionEnabled)};

    function setStatus(text, urgent = false) {
      // State words never write the DOM directly — renderState() is the only
      // writer of state-derived UI. Free-text notes ride along in statusNote.
      if (text === "LISTENING" || text === "SETTLING" || text === "THINKING" || text === "SPEAKING") {
        renderState();
        return;
      }
      statusNote = text || "";
      if (urgent && statusNote && !stageView) {
        stageView = { kind: "error", category: category.value, decided: 0, message: statusNote };
      }
      renderState();
    }

    function setCaption(text) {
      currentQuestion = String(text || "");
      renderState();
    }

    // Maps the real machine state (#256 explicit states + turn-taking phase)
    // onto the stage's data-state. If the machine doesn't have a state, the
    // UI does not display it.
    function machineState() {
      if (stageView) return stageView.kind;
      if (!sessionActive) return "idle";
      if (turnState.phase === "SETTLING") return "settling";
      if (turnState.phase === "THINKING") return "thinking";
      if (turnState.phase === "SPEAKING") return "speaking";
      return "listening";
    }

    const STATE_COPY = {
      idle: { status: "", caption: "Review knowledge-graph clusters by voice.", hint: "" },
      listening: { status: "Listening", hint: "Pause when you're done — I'll pick it up." },
      settling: { status: "Got it — finishing up?", hint: "Keep talking to add more." },
      thinking: { status: "One sec…", hint: "" },
      speaking: { status: "", hint: "Just start talking to interrupt." },
    };

    // THE single writer. Nothing else sets data-state or state-derived copy.
    function renderState() {
      const state = machineState();
      const stage = $("stage");
      stage.setAttribute("data-state", state);
      $("settleRing").style.setProperty("--settle-progress", String(turnState.settleProgress || 0));
      $("phaseAnnouncer").textContent = state;

      const copy = STATE_COPY[state] || {};
      let status = copy.status || "";
      let caption = copy.caption || currentQuestion || "";
      let hint = copy.hint || "";
      let banner = "";
      let stats = "";
      let action = "";
      let showBegin = state === "idle";

      if (state === "error") {
        caption = "I'll pick up right where we left off.";
        banner = (stageView && stageView.message) || "Something went wrong.";
        showBegin = true;
      } else if (state === "complete") {
        status = "All caught up";
        caption = "Every cluster in " + ((stageView && stageView.category) || category.value) + " is resolved.";
        stats = String((stageView && stageView.decided) || 0) + " decided";
        action = "Review another category";
      } else if (state === "empty") {
        caption = "Nothing left to review in " + ((stageView && stageView.category) || category.value) + ".";
        hint = "Pick another category to keep going.";
        action = "Switch category";
      }

      if (!captionPlayback) $("caption").textContent = caption;
      $("status").textContent = state === "error" ? "" : (statusNote || status);
      $("hint").textContent = hint;

      const bannerNode = $("stageBanner");
      const noticeText = !banner && voiceNoticeText ? voiceNoticeText : "";
      if (banner || noticeText) {
        bannerNode.hidden = false;
        bannerNode.classList.toggle("notice", Boolean(noticeText));
        $("stageBannerText").textContent = banner || noticeText;
      } else {
        bannerNode.hidden = true;
      }

      const statsNode = $("stageStats");
      statsNode.hidden = !stats;
      statsNode.textContent = stats;

      const actionNode = $("stageAction");
      actionNode.hidden = !action;
      actionNode.textContent = action;

      const beginNode = $("beginButton");
      beginNode.hidden = !showBegin;
      beginNode.textContent = state === "error" ? "Try again" : "Begin review";

      sessionButton.hidden = !sessionActive;
      if (state === "complete") sessionButton.textContent = "Done";

      $("workbench").hidden = !(sessionActive && current && !stageView);

      if (debugEnabled) {
        const strip = $("debugStrip");
        strip.hidden = false;
        strip.textContent =
          state + " · phase=" + turnState.phase +
          " · settle=" + Number(turnState.settleProgress || 0).toFixed(2) +
          " · ring=" + String(Boolean(turnState.showSettlingRing));
      }
    }

    function updateMicLevel(probability) {
      const state = machineState();
      if (state !== "listening" && state !== "settling") return;
      const raw = Number(probability || 0);
      const level = vadState.mode === "silero" ? raw : Math.min(1, raw * 8);
      $("orb").style.setProperty("--level", String(Math.max(0, Math.min(1, level))));
    }

    const scheduleFrame = (fn) =>
      typeof requestAnimationFrame === "function" ? requestAnimationFrame(fn) : setTimeout(fn, 50);
    const cancelScheduledFrame = (handle) => {
      if (typeof cancelAnimationFrame === "function") cancelAnimationFrame(handle);
      else clearTimeout(handle);
    };

    // Word-sync caption: highlights ride the real x-word-boundaries payload;
    // each word boundary also pulses --level so the orb moves with speech.
    function startCaptionSync(playback) {
      captionPlayback = playback;
      const captionNode = $("caption");
      const words = String(playback.displayText || "").trim().split(/\\s+/).filter(Boolean);
      captionNode.innerHTML = words
        .map((word) => "<span class='w'>" + escapeHtml(word) + "</span>")
        .join(" ");
      const spans = typeof captionNode.querySelectorAll === "function"
        ? Array.from(captionNode.querySelectorAll(".w"))
        : [];
      const boundaries = Array.isArray(playback.wordBoundaries) ? playback.wordBoundaries : [];
      let lastTarget = -1;
      speakPulseLevel = 0;
      const frame = () => {
        if (captionPlayback !== playback) return;
        const atMs = Math.round((audio.currentTime || 0) * 1000);
        let spokenBoundaries = 0;
        while (
          spokenBoundaries < boundaries.length &&
          Number(boundaries[spokenBoundaries].offset_ms || 0) <= atMs
        ) {
          spokenBoundaries += 1;
        }
        const target = boundaries.length
          ? Math.min(spans.length, Math.round((spokenBoundaries / boundaries.length) * spans.length))
          : Math.min(spans.length, Math.floor(atMs / 280));
        for (let index = 0; index < spans.length; index += 1) {
          spans[index].classList.toggle("spoken", index < target);
        }
        if (target > lastTarget) {
          speakPulseLevel = 1;
          lastTarget = target;
        }
        speakPulseLevel *= 0.9;
        $("orb").style.setProperty("--level", String(Math.max(0, Math.min(1, speakPulseLevel))));
        captionFrameHandle = scheduleFrame(frame);
      };
      captionFrameHandle = scheduleFrame(frame);
    }

    function stopCaptionSync() {
      if (!captionPlayback) return;
      captionPlayback = null;
      if (captionFrameHandle !== null) cancelScheduledFrame(captionFrameHandle);
      captionFrameHandle = null;
      $("orb").style.setProperty("--level", "0");
      renderState();
    }

    // Calm voice-fallback moment (one banner, no toast stack). E9's theo
    // cloned-voice routing calls this when its engine drops mid-session.
    function showVoiceFallbackNotice(message) {
      voiceNoticeText = String(message || "Theo's voice is unavailable — switching to a standard voice.");
      clearTimeout(voiceNoticeTimer);
      voiceNoticeTimer = setTimeout(() => {
        voiceNoticeText = "";
        renderState();
      }, 6000);
      renderState();
    }
    try { window.voiceReviewFallbackNotice = showVoiceFallbackNotice; } catch (_error) {}

    function applyTheme(mode) {
      const root = document.documentElement;
      if (root && root.setAttribute) {
        if (mode === "light" || mode === "dark") root.setAttribute("data-theme", mode);
        else if (root.removeAttribute) root.removeAttribute("data-theme");
      }
      try {
        if (mode === "light" || mode === "dark") localStorage.setItem("vr-theme", mode);
        else localStorage.removeItem("vr-theme");
      } catch (_error) {}
      const states = [["themeSystem", "system"], ["themeLight", "light"], ["themeDark", "dark"]];
      for (const [id, value] of states) {
        const node = $(id);
        if (node && node.setAttribute) {
          node.setAttribute("aria-pressed", String(value === mode));
        }
      }
    }

    function storedTheme() {
      try {
        const value = localStorage.getItem("vr-theme");
        return value === "light" || value === "dark" ? value : "system";
      } catch (_error) {
        return "system";
      }
    }

    function setVadMode(mode, detail) {
      const node = $("vadMode");
      node.textContent = mode === "basic" ? "basic mode" : mode === "silero" ? "Silero VAD" : detail || "VAD pending";
      node.classList.toggle("basic", mode === "basic");
    }

    function selectedTtsVoice() {
      return ttsVoice?.value || "en-US-GuyNeural";
    }

    function isClonedTtsVoice(voice) {
      return CLONED_TTS_VOICES.has(String(voice || ""));
    }

    function restoreStoredTtsVoice() {
      try {
        const stored = localStorage.getItem("voicereview.ttsVoice");
        const hasOption = Array.from(ttsVoice?.options || []).some(
          (option) => option.value === stored
        );
        if (stored && hasOption) {
          ttsVoice.value = stored;
        }
      } catch (_error) {}
    }

    function persistSelectedTtsVoice() {
      try {
        localStorage.setItem("voicereview.ttsVoice", selectedTtsVoice());
      } catch (_error) {}
    }

    function selectedTtsRate() {
      const value = Number(ttsRate?.value || -8);
      const prefix = value >= 0 ? "+" : "";
      return prefix + String(value) + "%";
    }

    function updateTtsRateLabel() {
      if (ttsRateValue) ttsRateValue.textContent = selectedTtsRate();
    }

    function splitInterruptedSpeech(text, wordBoundaries, interruptedAtMs) {
      const words = String(text || "").trim().split(/\\s+/).filter(Boolean);
      const safeInterruptedAtMs = Math.max(0, Math.round(interruptedAtMs || 0));
      let spokenWordCount = 0;
      if (Array.isArray(wordBoundaries) && wordBoundaries.length) {
        spokenWordCount = wordBoundaries.filter((word) => Number(word.offset_ms || 0) <= safeInterruptedAtMs).length;
      } else {
        const approximateChars = Math.floor(safeInterruptedAtMs * 0.013);
        let chars = 0;
        for (const word of words) {
          const next = chars + word.length + 1;
          if (next > approximateChars) break;
          spokenWordCount += 1;
          chars = next;
        }
      }
      spokenWordCount = Math.max(0, Math.min(words.length, spokenWordCount));
      return {
        agent_speech_spoken_so_far: words.slice(0, spokenWordCount).join(" "),
        agent_speech_unspoken_remainder: words.slice(spokenWordCount).join(" "),
        interrupted_at_ms: safeInterruptedAtMs
      };
    }

    function humanizeSpokenText(input) {
      return String(input || "")
        .replace(/<\\/?[^>]+>/g, "")
        .replace(/^#{1,6}\\s*/gm, "")
        .replace(/^\\s*[-*]\\s+/gm, "")
        .replace(/\\brt-[a-z0-9-]{6,}\\b/gi, "")
        .replace(/\\bchunk\\s+\\d+\\b/gi, "")
        .replace(/\\btype=[a-z0-9_-]+:?\\s*/gi, "")
        .replace(/_/g, " ")
        .replace(/[ \\t]*\\n+[ \\t]*/g, ". ")
        .replace(/\\s+([.,:;!?])/g, "$1")
        .replace(/:\\s*\\./g, ".")
        .replace(/\\.\\s*\\./g, ".")
        .replace(/\\s+/g, " ")
        .trim();
    }

    async function api(path, options = {}) {
      const requestOptions = Object.assign({}, options);
      if (!requestOptions.signal && sessionAbortController) {
        requestOptions.signal = sessionAbortController.signal;
      }
      const response = await fetch(path, requestOptions);
      const type = response.headers.get("content-type") || "";
      if (!response.ok) {
        let message = response.statusText;
        if (type.includes("application/json")) {
          const body = await response.json();
          message = body.error || body.message || message;
        }
        throw new Error(message);
      }
      return response;
    }

    async function withLiteRtWork(work) {
      liteRtWorkInFlight += 1;
      try {
        return await work();
      } finally {
        liteRtWorkInFlight = Math.max(0, liteRtWorkInFlight - 1);
      }
    }

    async function startSession() {
      if (finishingSession) return;
      sessionButton.disabled = true;
      // Never start over a teardown still releasing the recorder/context.
      if (teardownPromise) {
        await teardownPromise.catch(() => undefined);
        teardownPromise = null;
      }
      if (sessionAbortController) sessionAbortController.abort();
      sessionAbortController = new AbortController();
      try {
        await healthCheck(false);
        await ensureMicOpen();
        await initVad();
        sessionActive = true;
        stageView = null;
        statusNote = "";
        sessionButton.textContent = finishSessionEnabled ? "Finish session" : "End session";
        sessionButton.classList.add("is-active");
        category.disabled = true;
        turnState = createTurnTakingState();
        renderState();
        await loadNext(true);
      } catch (error) {
        if (!isAbortError(error)) showLegFailure("Session failed: " + error.message);
      } finally {
        sessionButton.disabled = false;
      }
    }

    async function endSession() {
      teardownPromise = teardownSessionRuntime("Session ended.");
      await teardownPromise;
    }

    function finishSummary(result) {
      const output = [result.stdout, result.stderr].filter(Boolean).join("\\n").trim();
      if (!output) {
        return result.ok ? "Finish command completed." : "Finish command failed with no output.";
      }
      return output;
    }

    async function finishSession() {
      if (finishingSession) return;
      finishingSession = true;
      sessionButton.disabled = true;
      try {
        teardownPromise = teardownSessionRuntime("Finishing session...");
        await teardownPromise;
        const response = await fetch("/api/session/finish", {
          method: "POST",
          headers: { "x-voicereview-finish": "1" }
        });
        const result = await response.json();
        if (!response.ok && result.error) throw new Error(result.error);
        const summary = finishSummary(result);
        setStatus(result.ok ? "Session finished." : "Session finish failed.", !result.ok);
        addTurn("system", result.ok ? "finish" : "finish failed", summary);
      } catch (error) {
        const message = "Session finish failed: " + error.message;
        setStatus(message, true);
        addTurn("system", "finish failed", message);
      } finally {
        finishingSession = false;
        sessionButton.disabled = false;
      }
    }

    async function teardownSessionRuntime(message, options = {}) {
      sessionActive = false;
      clearTimeout(healthRetryTimer);
      healthRetryBackoffMs = 3000;
      liteRtWorkInFlight = 0;
      if (sessionAbortController) {
        sessionAbortController.abort();
        sessionAbortController = null;
      }
      systemSpeechToken += 1;
      systemSpeechActive = false;
      try { window.speechSynthesis?.cancel(); } catch (_error) {}
      stopActivePlayback();
      clearPausedUtterance();
      if (mediaRecorder && mediaRecorder.state !== "inactive") mediaRecorder.stop();
      mediaRecorder = null;
      if (processor) processor.disconnect();
      if (micSource) micSource.disconnect();
      const contextToClose = audioContext;
      for (const track of stream?.getTracks() || []) track.stop();
      stream = null;
      audioContext = null;
      processor = null;
      micSource = null;
      collectingTurn = false;
      flushingTurn = false;
      processingTurn = false;
      turnChunks = [];
      vadState.queue = [];
      vadState.pendingSamples = new Float32Array(0);
      vadState.busy = false;
      vadState.state = null;
      vadState.sr = null;
      vadState.context = new Float32Array(BROWSER_VAD_CONTEXT_SAMPLES);
      vadState.mode = "pending";
      if (contextToClose) await contextToClose.close().catch(() => undefined);
      if (options.unload) return;
      stageView = null;
      turnState = createTurnTakingState();
      renderState();
      sessionButton.textContent = "Start session";
      sessionButton.classList.remove("is-active");
      category.disabled = false;
      if (message) setStatus(message, Boolean(options.urgent));
      if (options.log && message) addTurn("system", "system", message);
    }

    async function healthCheck(silent) {
      if (liteRtWorkInFlight > 0) {
        $("healthMode").textContent = "brain busy";
        scheduleHealthRetry({ backoff: false });
        return true;
      }
      try {
        const response = await api("/api/health");
        const body = await response.json();
        $("healthMode").textContent = body.ok ? "brain online" : "brain offline";
        healthFailureStreak = 0;
        nextHealthAnnouncementAt = 0;
        healthAnnouncementBackoffMs = 3000;
        healthRetryBackoffMs = 3000;
        return true;
      } catch (error) {
        healthFailureStreak += 1;
        $("healthMode").textContent = "brain offline";
        if (!silent && canAnnounceHealthFailure()) showLegFailure("brain offline — retrying");
        scheduleHealthRetry();
        return false;
      }
    }

    function canAnnounceHealthFailure() {
      if (document.visibilityState !== "visible") return false;
      if (healthFailureStreak < HEALTH_FAILURE_ANNOUNCE_THRESHOLD) return false;
      const now = Date.now();
      if (now < nextHealthAnnouncementAt) return false;
      nextHealthAnnouncementAt = now + healthAnnouncementBackoffMs;
      healthAnnouncementBackoffMs = Math.min(60000, healthAnnouncementBackoffMs * 2);
      return true;
    }

    function scheduleHealthRetry(options = {}) {
      clearTimeout(healthRetryTimer);
      if (!sessionActive) return;
      healthRetryTimer = setTimeout(() => healthCheck(true), healthRetryBackoffMs);
      if (options.backoff !== false) {
        healthRetryBackoffMs = Math.min(60000, healthRetryBackoffMs * 2);
      }
    }

    function showLegFailure(message) {
      // One failure, one voice: the stage banner. No log echo, no pill flip.
      const text = message.includes("brain offline") ? "Reconnecting to the local brain…" : message;
      teardownPromise = teardownSessionRuntime(text, { urgent: true });
      void teardownPromise;
    }

    function isAbortError(error) {
      return error?.name === "AbortError" || String(error?.message || error).toLowerCase().includes("aborted");
    }

    function speakSystemText(text) {
      const previousPhase = turnState.phase;
      const token = systemSpeechToken + 1;
      const finish = () => {
        if (systemSpeechToken !== token) return;
        systemSpeechActive = false;
        if (turnState.phase === "SPEAKING") {
          turnState.phase = previousPhase;
          renderState();
        }
      };
      try {
        if (!window.speechSynthesis) return;
        if (document.visibilityState !== "visible") return;
        window.speechSynthesis.cancel();
        systemSpeechToken = token;
        systemSpeechActive = true;
        turnState.phase = "SPEAKING";
        turnState.playbackSpeechFrames = 0;
        renderState();
        const utterance = new SpeechSynthesisUtterance(text);
        utterance.rate = 1;
        utterance.onend = finish;
        utterance.onerror = finish;
        window.speechSynthesis.speak(utterance);
      } catch (_error) {
        finish();
        // Visible error state remains the source of truth.
      }
    }

    async function ensureMicOpen() {
      if (stream) return;
      stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: false,
          channelCount: 1
        }
      });
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      audioContext = new AudioContextClass();
      if (audioContext.state === "suspended") await audioContext.resume();
      micSource = audioContext.createMediaStreamSource(stream);
      processor = audioContext.createScriptProcessor(2048, 1, 1);
      const silentGain = audioContext.createGain();
      silentGain.gain.value = 0;
      processor.onaudioprocess = (event) => {
        if (!sessionActive) return;
        const input = event.inputBuffer.getChannelData(0);
        enqueueAudioForVad(input, audioContext.sampleRate);
      };
      micSource.connect(processor);
      processor.connect(silentGain);
      silentGain.connect(audioContext.destination);
    }

    async function initVad() {
      try {
        ort.env.wasm.wasmPaths = "/vendor/onnxruntime-web/";
        vadState.session = await ort.InferenceSession.create("/models/silero_vad.onnx", {
          executionProviders: ["wasm"]
        });
        vadState.state = new ort.Tensor("float32", new Float32Array(2 * 1 * 128), [2, 1, 128]);
        vadState.sr = new ort.Tensor("int64", BigInt64Array.from([BigInt(16000)]), []);
        vadState.context = new Float32Array(BROWSER_VAD_CONTEXT_SAMPLES);
        vadState.mode = "silero";
        setVadMode("silero");
      } catch (error) {
        vadState.mode = "basic";
        setVadMode("basic");
        addTurn("system", "system", "Using simple voice detection.");
      }
    }

    function createTurnRecorder() {
      const options = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
        ? { mimeType: "audio/webm;codecs=opus" }
        : {};
      const recorder = new MediaRecorder(stream, options);
      recorder.ondataavailable = (event) => {
        if (event.data.size > 0 && (collectingTurn || flushingTurn)) {
          turnChunks.push(event.data);
        }
      };
      return recorder;
    }

    async function startTurnRecorder() {
      if (mediaRecorder && mediaRecorder.state !== "inactive") return;
      mediaRecorder = createTurnRecorder();
      mediaRecorder.start(250);
    }

    async function stopTurnRecorderAndBuildBlob() {
      const recorder = mediaRecorder;
      const mimeType = recorder?.mimeType || "audio/webm";
      if (!recorder || recorder.state === "inactive") {
        const blob = new Blob(turnChunks, { type: mimeType });
        turnChunks = [];
        if (mediaRecorder === recorder) mediaRecorder = null;
        return blob;
      }

      const stopped = new Promise((resolve) => {
        recorder.addEventListener("stop", resolve, { once: true });
      });
      recorder.stop();
      await stopped;
      if (mediaRecorder === recorder) mediaRecorder = null;
      const blob = new Blob(turnChunks, { type: mimeType });
      turnChunks = [];
      return blob;
    }

    function enqueueAudioForVad(input, sampleRate) {
      const downsampled = downsampleTo16k(input, sampleRate);
      const combined = new Float32Array(vadState.pendingSamples.length + downsampled.length);
      combined.set(vadState.pendingSamples, 0);
      combined.set(downsampled, vadState.pendingSamples.length);
      let offset = 0;
      while (combined.length - offset >= BROWSER_VAD_CHUNK_SAMPLES) {
        vadState.queue.push(combined.slice(offset, offset + BROWSER_VAD_CHUNK_SAMPLES));
        offset += BROWSER_VAD_CHUNK_SAMPLES;
      }
      vadState.pendingSamples = combined.slice(offset);
      void processVadQueue();
    }

    function downsampleTo16k(input, sampleRate) {
      if (Math.round(sampleRate) === 16000) return new Float32Array(input);
      const ratio = sampleRate / 16000;
      const length = Math.max(1, Math.floor(input.length / ratio));
      const output = new Float32Array(length);
      for (let index = 0; index < length; index += 1) {
        output[index] = input[Math.min(input.length - 1, Math.floor(index * ratio))] || 0;
      }
      return output;
    }

    async function processVadQueue() {
      if (vadState.busy) return;
      vadState.busy = true;
      try {
        while (sessionActive && vadState.queue.length) {
          const chunk = vadState.queue.shift();
          const result = await detectSpeech(chunk);
          updateMicLevel(result.probability);
          handleVadFrame(result.speech, result.probability);
        }
      } finally {
        vadState.busy = false;
      }
    }

    async function detectSpeech(chunk) {
      if (vadState.mode === "silero" && vadState.session) {
        const prepared = createSileroVadInput(chunk, vadState.context);
        const result = await vadState.session.run({
          input: new ort.Tensor("float32", prepared.input, prepared.dims),
          state: vadState.state,
          sr: vadState.sr
        });
        vadState.state = result.stateN;
        vadState.context = prepared.nextContext;
        const probability = Number(result.output.data[0] || 0);
        return { speech: probability >= SILERO_SPEECH_THRESHOLD, probability };
      }
      let sum = 0;
      for (const sample of chunk) sum += sample * sample;
      const rms = Math.sqrt(sum / chunk.length);
      return { speech: rms >= BASIC_RMS_THRESHOLD, probability: rms };
    }

    function handleVadFrame(speech) {
      if (!sessionActive) return;
      if (systemSpeechActive) return;
      // Terminal frames (complete/empty) keep the mic open for an instant
      // category switch, but no turn may be captured or processed under them.
      if (stageView) return;
      const previousPhase = turnState.phase;
      turnState = advanceTurnTakingFrame(turnState, { speech });
      renderState();

      if (flushingTurn) return;
      if (turnState.pausePlayback) {
        pendingInterruption = pausePlaybackForInterruption();
        void beginTurnCapture();
        setStatus("LISTENING");
        return;
      }
      if (processingTurn && !turnState.pausePlayback) {
        if (speech && !collectingTurn) {
          void beginTurnCapture();
          setStatus("LISTENING");
        }
        return;
      }
      if (speech && (turnState.phase === "LISTENING" || previousPhase === "THINKING")) {
        void beginTurnCapture();
        setStatus("LISTENING");
      }
      if (turnState.phase === "SETTLING") {
        setStatus(turnState.showSettlingRing ? "SETTLING" : "LISTENING");
      }
      if (turnState.turnTaken) {
        void finishAndProcessTurn();
      }
    }

    async function beginTurnCapture() {
      if (collectingTurn || flushingTurn) return;
      turnChunks = [];
      collectingTurn = true;
      try {
        await startTurnRecorder();
      } catch (error) {
        collectingTurn = false;
        showLegFailure("Recorder failed: " + error.message);
      }
    }

    async function finishAndProcessTurn() {
      if (processingTurn || !collectingTurn) return;
      processingTurn = true;
      collectingTurn = false;
      flushingTurn = true;
      try {
        await sleep(80);
        const blob = await stopTurnRecorderAndBuildBlob();
        flushingTurn = false;
        await processTurnBlob(blob);
        turnState = createTurnTakingState();
        renderState();
      } catch (error) {
        showLegFailure("Turn failed: " + error.message);
        processingTurn = false;
      } finally {
        flushingTurn = false;
      }
    }

    async function processTurnBlob(blob) {
      if (!current || !sessionActive) {
        processingTurn = false;
        return;
      }
      turnState.phase = "THINKING";
      renderState();
      setStatus("THINKING");
      try {
        const transcribeResponse = await withLiteRtWork(async () => api("/api/transcribe", {
          method: "POST",
          headers: { "content-type": blob.type || "audio/webm" },
          body: blob
        }));
        const transcribe = await transcribeResponse.json();
        const transcript = String(transcribe.text || "").trim();
        if (!transcript) throw new Error("empty transcript");
        addTurn("user", "you", transcript);

        const pause = applyThinkingPauseHold(transcript);
        if (pause.shouldHold) {
          heldTranscript = pause.transcript;
          setCaption("Take your time.");
          setStatus("");
          processingTurn = false;
          return;
        }

        const transcriptForInterpret = pause.transcript;
        const interruptionForTurn = pendingInterruption;
        const interpretResponse = await withLiteRtWork(async () => api("/api/interpret", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            transcript: transcriptForInterpret,
            cluster: current,
            understanding,
            interruption: interruptionForTurn
          })
        }));
        const interpreted = await interpretResponse.json();
        await handleInterpretation(interpreted.decision, transcriptForInterpret, interruptionForTurn);
        if (pendingInterruption === interruptionForTurn) pendingInterruption = null;
      } catch (error) {
        if (!sessionActive || isAbortError(error)) return;
        showLegFailure(error.message.includes("LiteRT") ? "brain offline — retrying" : "Turn failed: " + error.message);
      } finally {
        processingTurn = false;
      }
    }

    async function handleInterpretation(decision, transcript, interruption) {
      if (decision.action === "question") {
        await answerQuestion(decision.question || transcript, interruption);
        return;
      }

      const applied = applyUnderstandingDelta(understanding, decision, current);
      understanding = applied.state;
      renderUnderstanding();

      if (decision.action === "update" && !applied.terminalDecision) {
        renderDecision(decision);
        const question = decision.remaining_question || "What remains unresolved?";
        setCaption(question);
        await speakAgent(question);
        return;
      }

      const terminal = applied.terminalDecision || decision;
      await recordDecision(terminal);
    }

    async function answerQuestion(question, interruption = null) {
      setEvidenceStatus("checking evidence");
      const response = await withLiteRtWork(async () => api("/api/converse", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          question,
          cluster: current,
          history: conversationHistory,
          interruption
        })
      }));
      const body = await response.json();
      const answer = String(body.answer || "I don't see evidence about that").trim();
      if (body.preface) {
        setEvidenceStatus("fetching deeper evidence");
        addTurn("system", "system", String(body.preface));
        await speakAgent(String(body.preface), { log: false });
      }
      renderEvidence(body.evidence, body.evidence_depth || "shallow");
      conversationHistory.push({ question, answer });
      addTurn("agent", "agent", answer);
      await speakAgent(answer, { log: false });
    }

    async function recordDecision(decision) {
      renderDecision(decision);
      setStatus("THINKING");
      await api("/api/decide", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ cluster_id: current.cluster_id, decision })
      });
      const confirmation = confirmationText(decision);
      await speakAgent(confirmation);
      await loadNext(true);
    }

    function confirmationText(decision) {
      if (decision.action === "merge") return "Decision recorded: merge.";
      if (decision.action === "keep") return "Decision recorded: keep separate.";
      if (decision.action === "mixed") return "Decision recorded: mixed.";
      if (decision.action === "skip") return "Decision recorded: skip.";
      return "Decision recorded.";
    }

    async function speakAgent(text, options = {}) {
      if (!sessionActive || !text) return "skipped";
      stopActivePlayback();
      turnState.phase = "SPEAKING";
      turnState.playbackSpeechFrames = 0;
      renderState();
      const displayText = String(text);
      const spokenText = humanizeSpokenText(displayText);
      if (options.log !== false) addTurn("agent", "agent", displayText);
      try {
        const selectedVoice = selectedTtsVoice();
        let response;
        try {
          response = await requestTtsAudio(spokenText, selectedVoice);
        } catch (error) {
          if (
            sessionActive &&
            !isAbortError(error) &&
            isClonedTtsVoice(selectedVoice) &&
            !ttsFallbackAnnounced &&
            String(error?.message || "").includes("theo engine offline")
          ) {
            ttsFallbackAnnounced = true;
            const fallbackMessage = "Theo voice is unavailable; switching to the fallback voice.";
            // One calm moment on the stage — not a status flip + log echo stack.
            showVoiceFallbackNotice(fallbackMessage);
            const engineNote = $("voiceEngineNote");
            engineNote.hidden = false;
            engineNote.textContent = "Theo's engine is offline — using Edge voices.";
            response = await requestTtsAudio(spokenText, EDGE_FALLBACK_VOICE);
          } else {
            throw error;
          }
        }
        const wordBoundaries = JSON.parse(response.headers.get("x-word-boundaries") || "[]");
        const blob = await response.blob();
        const url = URL.createObjectURL(blob);
        return await playAudioUrl({
          url,
          displayText,
          spokenText,
          wordBoundaries,
          startTime: 0
        });
      } catch (error) {
        if (!sessionActive || isAbortError(error)) return "stopped";
        showLegFailure("TTS failed: " + error.message);
        turnState = createTurnTakingState();
        renderState();
        return "failed";
      }
    }

    async function requestTtsAudio(text, voice) {
      return await withLiteRtWork(async () => api("/api/tts", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          text,
          voice,
          rate: selectedTtsRate()
        })
      }));
    }

    function playAudioUrl(playbackInput) {
      const { url, displayText, spokenText, wordBoundaries, startTime } = playbackInput;
      audio.src = url;
      setStatus("SPEAKING");
      turnState.phase = "SPEAKING";
      turnState.playbackSpeechFrames = 0;
      renderState();
      return new Promise((resolve) => {
        const playback = {
          url,
          resolve,
          displayText,
          spokenText,
          wordBoundaries: Array.isArray(wordBoundaries) ? wordBoundaries : [],
          cleanup: null
        };
        const cleanup = (result, keepUrl = false) => {
          audio.removeEventListener("ended", ended);
          audio.removeEventListener("error", failed);
          if (!keepUrl) URL.revokeObjectURL(url);
          if (activePlayback === playback) activePlayback = null;
          stopCaptionSync();
          if (turnState.phase === "SPEAKING") {
            turnState = createTurnTakingState();
            renderState();
          }
          resolve(result);
        };
        playback.cleanup = cleanup;
        activePlayback = playback;
        startCaptionSync(playback);
        const ended = () => cleanup("ended");
        const failed = () => cleanup("failed");
        const start = () => {
          try {
            if (startTime) audio.currentTime = startTime;
          } catch (_error) {}
          audio.play().catch(() => cleanup("failed"));
        };
        audio.addEventListener("ended", ended, { once: true });
        audio.addEventListener("error", failed, { once: true });
        if (audio.readyState >= 1) start();
        else audio.addEventListener("loadedmetadata", start, { once: true });
      });
    }

    function stopActivePlayback() {
      if (!activePlayback && audio.paused) return "none";
      const playback = activePlayback;
      audio.pause();
      audio.removeAttribute("src");
      audio.src = "";
      audio.load();
      if (playback) {
        playback.cleanup("stopped");
      }
      turnState.phase = "LISTENING";
      turnState.playbackSpeechFrames = 0;
      renderState();
      return "stopped";
    }

    function pausePlaybackForInterruption() {
      if (!activePlayback) return null;
      const playback = activePlayback;
      const interruptedAtMs = Math.max(0, Math.round((audio.currentTime || 0) * 1000));
      audio.pause();
      const interruption = splitInterruptedSpeech(
        playback.spokenText,
        playback.wordBoundaries,
        interruptedAtMs
      );
      pausedUtterance = {
        url: playback.url,
        currentTime: audio.currentTime || 0,
        displayText: playback.displayText,
        spokenText: playback.spokenText,
        wordBoundaries: playback.wordBoundaries,
        interruption
      };
      playback.cleanup("paused", true);
      renderPausedUtterance();
      return interruption;
    }

    function renderPausedUtterance() {
      if (!pausedUtterance) {
        $("pausedUtterance").hidden = true;
        $("pausedText").textContent = "";
        return;
      }
      $("pausedUtterance").hidden = false;
      $("pausedText").textContent = pausedUtterance.displayText;
    }

    function clearPausedUtterance() {
      pendingInterruption = null;
      if (pausedUtterance?.url) URL.revokeObjectURL(pausedUtterance.url);
      pausedUtterance = null;
      renderPausedUtterance();
    }

    async function resumePausedUtterance() {
      if (!sessionActive || !pausedUtterance) return;
      stopActivePlayback();
      const paused = pausedUtterance;
      pendingInterruption = null;
      pausedUtterance = null;
      renderPausedUtterance();
      await playAudioUrl({
        url: paused.url,
        displayText: paused.displayText,
        spokenText: paused.spokenText,
        wordBoundaries: paused.wordBoundaries,
        startTime: paused.currentTime
      });
    }

    async function loadNext(play) {
      setStatus("Finding the next cluster…");
      const response = await api("/api/next?category=" + encodeURIComponent(category.value));
      const body = await response.json();
      current = body.cluster || null;
      currentSpeak = body.speak || "";
      conversationHistory = [];
      heldTranscript = "";
      pendingInterruption = null;
      clearPausedUtterance();
      setEvidenceStatus("No evidence fetched.");
      $("evidenceBody").innerHTML = "";
      if (!current) {
        renderQueueState(body.queue_state);
        return;
      }
      understanding = createUnderstandingState(current);
      renderCluster();
      renderUnderstanding();
      if (currentSpeak) currentQuestion = currentSpeak;
      setStatus("");
      if (play && currentSpeak) await speakAgent(currentSpeak);
    }

    function renderQueueState(queueState) {
      const state = queueState || {};
      const stateCategory = state.category || category.value;
      const decided = Number.isFinite(Number(state.decided)) ? Number(state.decided) : 0;
      const kind = state.kind === "complete" ? "complete" : state.kind === "error" ? "error" : "empty";
      const message = state.message || (
        kind === "complete"
          ? "All items in this queue are complete 🎉 " + String(decided) + " decided."
          : kind === "error"
            ? "Stats unavailable for " + stateCategory + "."
            : "No items found for category " + stateCategory + "."
      );
      understanding = null;
      current = null;
      currentQuestion = "";
      statusNote = "";
      $("sessionMeta").textContent = stateCategory;
      if (kind === "error") {
        $("healthMode").textContent = "stats error";
        $("healthMode").classList.add("basic");
        // A queue error ends the session runtime so "Try again" is a real
        // restart (startSession), not a dead control under sessionActive.
        teardownPromise = teardownSessionRuntime(message, { urgent: true });
        void teardownPromise;
        return;
      }
      // Terminal frames keep the session runtime alive so switching category
      // resumes instantly — but the category picker must be usable for that.
      category.disabled = false;
      stageView = { kind, category: stateCategory, decided, message };
      renderState();
    }

    function renderCluster() {
      stageView = null;
      $("stem").textContent = current.stem;
      $("sessionMeta").textContent = current.category;
      renderUnderstanding();
    }

    function memberStatusLabel(status) {
      if (status === "irrelevant") return "not relevant";
      if (status === "merge") return "merging";
      if (status === "keep") return "keeping";
      return "deciding";
    }

    function renderUnderstanding() {
      if (!current || !understanding) return;
      const unresolved = [];
      let resolved = 0;
      $("members").innerHTML = current.members.map((member) => {
        const status = understanding.member_updates[member.id] || "undecided";
        const isResolved = status !== "undecided";
        if (isResolved) resolved += 1;
        else unresolved.push(member);
        const classes = ["member"];
        if (isResolved) classes.push("is-resolved");
        if (status === "irrelevant") classes.push("not-relevant");
        return "<div class='" + classes.join(" ") + "' title='" + escapeHtml(member.id) + "'>" +
          "<div><div class='member-name'>" + escapeHtml(member.name) + "</div>" +
          "<div class='member-meta'>" + escapeHtml(member.type) + " · " + String(member.chunks || 0) + " chunks</div></div>" +
          "<div class='member-tag " + escapeHtml(status) + "'>" + memberStatusLabel(status) + "</div>" +
          "</div>";
      }).join("");
      const total = current.members.length || 1;
      $("clusterMeta").textContent = String(resolved) + " of " + String(total) + " resolved";
      currentQuestion =
        understanding.remaining_question ||
        (unresolved.length
          ? "Resolve " + unresolved.map((member) => member.name + " (" + member.type + ")").join(" vs ") + "."
          : "All members resolved.");
      renderState();
    }

    function describeDecision(decision) {
      if (!decision) return "";
      const nameOf = (id) => {
        const member = (current?.members || []).find((entry) => entry.id === id);
        return member ? member.name + " (" + member.type + ")" : id;
      };
      if (decision.action === "update") {
        const parts = Object.entries(decision.member_updates || {})
          .filter(([, status]) => status && status !== "undecided")
          .map(([id, status]) => "Marked " + nameOf(id) + " as " + memberStatusLabel(status));
        if (!parts.length) return decision.note || "Noted.";
        return parts.join("; ") + (decision.remaining_question ? " — still deciding the rest." : ".");
      }
      if (decision.action === "merge") {
        return "Merging everything into " + nameOf(decision.canonical_id || (current?.members?.[0]?.id ?? "")) + ".";
      }
      if (decision.action === "keep") return "Keeping all members separate.";
      if (decision.action === "skip") return "Skipped this cluster.";
      if (decision.action === "mixed") {
        const parts = Object.entries(decision.members || {}).map(([id, what]) =>
          nameOf(id) + ": " + (what === "prune" ? "not relevant" : what));
        return "Mixed decision — " + parts.join(", ") + ".";
      }
      return decision.note || "";
    }

    function renderDecision(decision) {
      $("decisionSentence").textContent = describeDecision(decision);
      $("decision").textContent = JSON.stringify(decision, null, 2);
    }

    function setEvidenceStatus(text) {
      $("evidenceStatus").textContent = text;
    }

    function renderEvidence(evidence, depth) {
      const members = Array.isArray(evidence?.members) ? evidence.members : [];
      const totalSnippets = members.reduce(
        (sum, member) => sum + (Array.isArray(member.snippets) ? member.snippets.length : 0),
        0,
      );
      $("evidenceStatus").textContent = totalSnippets
        ? String(totalSnippets) + (totalSnippets === 1 ? " snippet" : " snippets") +
          (depth === "deep" ? " · deeper pass" : "")
        : "No evidence found.";
      $("evidenceBody").innerHTML = members.map((member) => {
        const snippets = Array.isArray(member.snippets) ? member.snippets : [];
        const rows = snippets.map((snippet) =>
          "<div class='evidence-item'>" +
          "<div class='evidence-text'>" + escapeHtml(snippet.text || "") + "</div>" +
          "<div class='evidence-meta'>" + escapeHtml(member.name || member.id) + " · " +
          escapeHtml(member.type || "") + " · " + escapeHtml(snippet.project || "unknown") + " · " +
          escapeHtml(snippet.chunk_id || "") + "</div>" +
          "</div>"
        ).join("");
        return rows ||
          "<div class='evidence-item'><div class='evidence-meta'>" +
          escapeHtml(member.name || member.id) + ": no snippets</div></div>";
      }).join("");
    }

    function addTurn(kind, label, text) {
      const row = document.createElement("div");
      row.className = "turn " + kind;
      row.innerHTML =
        "<div class='turn-label'>" + escapeHtml(label) + "</div>" +
        "<div>" + escapeHtml(text) + "</div>";
      $("turnLog").appendChild(row);
      $("turnLog").scrollTop = $("turnLog").scrollHeight;
    }

    function applyThinkingPauseHold(transcript) {
      const incoming = String(transcript || "").trim();
      const combined = [heldTranscript, incoming].filter(Boolean).join(" ").replace(/\\s+/g, " ").trim();
      const intent = classifyPauseIntent(heldTranscript ? incoming : combined);
      if (heldTranscript && intent.intent === "content") {
        heldTranscript = "";
        return { shouldHold: false, transcript: combined };
      }
      if (intent.intent === "pause" || intent.intent === "prompt") {
        return {
          shouldHold: true,
          transcript: combined,
          nextTrailingSilenceMs: PAUSE_INTENT_EXTENDED_SILENCE_MS
        };
      }
      heldTranscript = "";
      return { shouldHold: false, transcript: combined || incoming };
    }

    function classifyPauseIntent(transcript) {
      const normalized = String(transcript || "")
        .trim()
        .replace(/[.,!?;:…"'()\\[\\]{}״׳]+/g, " ")
        .replace(/\\s+/g, " ")
        .toLowerCase();
      const tokens = normalized ? normalized.split(" ").filter(Boolean) : [];
      for (const phrase of THINKING_PAUSE_PHRASES) {
        const parts = phrase.split(" ");
        for (let index = 0; index <= tokens.length - parts.length; index += 1) {
          const same = parts.every((part, offset) => tokens[index + offset] === part);
          if (!same) continue;
          const trailing = index + parts.length === tokens.length;
          if (tokens.length <= 4 && trailing) return { intent: "pause" };
          if (tokens.length <= 4) return { intent: "prompt" };
          return { intent: "content" };
        }
      }
      return { intent: "content" };
    }

    function teardownAbandonedSession() {
      void teardownSessionRuntime("", { unload: true });
    }

    function resetAfterBfcacheRestore(event) {
      if (!event.persisted) return;
      finishingSession = false;
      turnState = createTurnTakingState();
      renderState();
      sessionButton.disabled = false;
      sessionButton.textContent = "Start session";
      sessionButton.classList.remove("is-active");
      category.disabled = false;
      if (!sessionActive) setStatus("Session ended.");
    }

    function sleep(ms) {
      return new Promise((resolve) => setTimeout(resolve, ms));
    }

    function escapeHtml(value) {
      return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#039;");
    }

    sessionButton.addEventListener("click", async () => {
      if (finishingSession) return;
      if (sessionActive && finishSessionEnabled) await finishSession();
      else if (sessionActive) await endSession();
      else await startSession();
    });

    $("beginButton").addEventListener("click", async () => {
      if (sessionActive) return;
      await startSession();
    });

    $("stageAction").addEventListener("click", () => {
      // Complete/empty frames route to the category picker in the gear popover.
      const gear = $("gearPopover");
      gear.open = true;
      if (typeof category.focus === "function") category.focus();
    });

    category.addEventListener("change", async () => {
      $("sessionMeta").textContent = category.value;
      if (!sessionActive) return;
      const gear = $("gearPopover");
      gear.open = false;
      await loadNext(false).catch((error) => showLegFailure(error.message));
    });

    $("themeSystem").addEventListener("click", () => applyTheme("system"));
    $("themeLight").addEventListener("click", () => applyTheme("light"));
    $("themeDark").addEventListener("click", () => applyTheme("dark"));

    window.addEventListener("pagehide", teardownAbandonedSession);
    window.addEventListener("beforeunload", teardownAbandonedSession);
    window.addEventListener("pageshow", resetAfterBfcacheRestore);

    ttsVoice?.addEventListener("change", persistSelectedTtsVoice);
    ttsRate?.addEventListener("input", updateTtsRateLabel);
    $("resumePlayback").addEventListener("click", async (event) => {
      event.preventDefault();
      await resumePausedUtterance();
    });

    restoreStoredTtsVoice();
    updateTtsRateLabel();
    applyTheme(storedTheme());
    renderState();
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
