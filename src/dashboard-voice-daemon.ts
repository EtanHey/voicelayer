import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { hasClonedProfile, synthesizeCloned } from "./tts/qwen3";
import { initEnrichedPATH, resolveBinary } from "./resolve-binary";

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 8787;
const DEFAULT_SAMPLE_RATE = 16000;
const MAX_TURN_SECONDS = 75;
const THEO_VOICE = "theo-n4a";
const WHISPER_MODEL = join(
  homedir(),
  ".cache/whisper/ggml-large-v3-turbo.bin",
);
const TTS_RECIPE_ROOT =
  "/Users/etanheyman/Gits/voicelayer/docs.local/voice-clone-2026-06-06";
const TTS_RECIPE_PYTHON = join(TTS_RECIPE_ROOT, "tts-env/bin/python");
const TTS_RECIPE_VOICE = join(TTS_RECIPE_ROOT, "logs/night/voice-n4a.json");
const TTS_RECIPE_REF =
  "/Users/etanheyman/.voicelayer/voices/theo-n4a/reference-clips/theo-n4a-theo-2026-05-21-12990-13080.wav";
const TTS_RECIPE_MODEL = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit";
const DEFAULT_ARC_SECTIONS_PATH =
  "/Users/etanheyman/Gits/agent-html/host/htmls/gen16-learn-v5-voice-agent/sections.json";
const DEFAULT_OLLAMA_HOST = "http://127.0.0.1:11434";
const DEFAULT_EMBEDDING_MODEL = "nomic-embed-text";
const DEFAULT_REASONING_MODEL = "qwen2.5-coder:14b";
const DEFAULT_RAG_TOP_K = 8;

type JsonRecord = Record<string, unknown>;

export type ArcSection = {
  id: string;
  title: string;
  domain?: string;
  narration_text?: string;
  fork?: unknown;
};

type IndexedArcSection = {
  section: ArcSection;
  embedding: number[];
};

type ArcRagAnswer = {
  answer: string;
  citations: string[];
  refused: boolean;
  retrieved?: Array<{ id: string; score: number }>;
};

type ArcRagGeneratorInput = {
  question: string;
  sections: ArcSection[];
};

type ClientState = {
  id: string;
  chunks: Buffer[];
  sampleRate: number;
  activeTurnId: string | null;
  activeSpeechId: string | null;
  cancelledSpeechIds: Set<string>;
  busy: boolean;
};

type CommandResult = {
  exitCode: number;
  stdout: string;
  stderr: string;
  durationMs: number;
};

export type DashboardVoiceDaemonOptions = {
  host?: string;
  port?: number;
  whisperCliPath?: string;
  whisperModelPath?: string;
  tempDir?: string;
  arcSectionsPath?: string;
  ollamaHost?: string;
  embeddingModel?: string;
  reasoningModel?: string;
  ragTopK?: number;
};

export function rankArcSectionsByEmbedding(
  indexedSections: IndexedArcSection[],
  queryEmbedding: number[],
  topK = DEFAULT_RAG_TOP_K,
): Array<{ section: ArcSection; score: number }> {
  return indexedSections
    .map((item) => ({
      section: item.section,
      score: cosineSimilarity(queryEmbedding, item.embedding),
    }))
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      return a.section.id.localeCompare(b.section.id);
    })
    .slice(0, Math.max(1, topK));
}

export async function answerArcQuestionWithRag(input: {
  question: string;
  sections: ArcSection[];
  topK?: number;
  embedText: (text: string) => Promise<number[]>;
  generateAnswer: (input: ArcRagGeneratorInput) => Promise<ArcRagAnswer>;
}): Promise<ArcRagAnswer> {
  const indexed: IndexedArcSection[] = [];
  for (const section of input.sections) {
    indexed.push({
      section,
      embedding: await input.embedText(sectionToEmbeddingText(section)),
    });
  }
  const queryEmbedding = await input.embedText(input.question);
  const ranked = rankArcSectionsByEmbedding(indexed, queryEmbedding, input.topK);
  return generateGroundedArcAnswer({
    question: input.question,
    ranked,
    generateAnswer: input.generateAnswer,
  });
}

export function encodePcm16Wav(
  samples: Int16Array,
  sampleRate = DEFAULT_SAMPLE_RATE,
): Uint8Array {
  const channels = 1;
  const bitsPerSample = 16;
  const dataBytes = samples.length * 2;
  const wav = new Uint8Array(44 + dataBytes);
  const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);
  writeAscii(wav, 0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  writeAscii(wav, 8, "WAVE");
  writeAscii(wav, 12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * channels * 2, true);
  view.setUint16(32, channels * 2, true);
  view.setUint16(34, bitsPerSample, true);
  writeAscii(wav, 36, "data");
  view.setUint32(40, dataBytes, true);
  for (let i = 0; i < samples.length; i++) {
    view.setInt16(44 + i * 2, samples[i] || 0, true);
  }
  return wav;
}

export function buildWhisperCliArgs(options: {
  binary: string;
  modelPath: string;
  wavPath: string;
  outputPrefix: string;
  prompt?: string;
}): string[] {
  const args = [
    options.binary,
    "-m",
    options.modelPath,
    "-f",
    options.wavPath,
    "-l",
    "en",
    "-nt",
    "-np",
    "-otxt",
    "-of",
    options.outputPrefix,
  ];
  const prompt = (options.prompt || "").trim();
  if (prompt) args.push("--prompt", prompt);
  return args;
}

export function cleanWhisperTranscript(raw: string): string {
  return String(raw || "")
    .split("\n")
    .map((line) =>
      line
        .replace(/^\[[^\]]+\]\s*/g, "")
        .replace(/^\s*\([^)]+\)\s*/g, "")
        .trim(),
    )
    .filter(Boolean)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
}

export async function startDashboardVoiceDaemon(
  options: DashboardVoiceDaemonOptions = {},
): Promise<ReturnType<typeof Bun.serve>> {
  initEnrichedPATH();
  const host = options.host || process.env.ASK_ARC_VOICE_HOST || DEFAULT_HOST;
  const port = Number(options.port || process.env.ASK_ARC_VOICE_PORT || DEFAULT_PORT);
  const tempDir =
    options.tempDir ||
    process.env.ASK_ARC_VOICE_TEMP_DIR ||
    join(tmpdir(), "ask-arc-voice-daemon");
  const whisperCliPath =
    options.whisperCliPath ||
    process.env.ASK_ARC_WHISPER_CLI ||
    resolveBinary("whisper-cli", ["/opt/homebrew/bin/whisper-cli"]);
  const whisperModelPath =
    options.whisperModelPath || process.env.ASK_ARC_WHISPER_MODEL || WHISPER_MODEL;
  const arcRag = createArcRagService({
    sectionsPath:
      options.arcSectionsPath ||
      process.env.ASK_ARC_SECTIONS_PATH ||
      DEFAULT_ARC_SECTIONS_PATH,
    ollamaHost: options.ollamaHost || process.env.OLLAMA_HOST || DEFAULT_OLLAMA_HOST,
    embeddingModel:
      options.embeddingModel ||
      process.env.ASK_ARC_EMBEDDING_MODEL ||
      DEFAULT_EMBEDDING_MODEL,
    reasoningModel:
      options.reasoningModel ||
      process.env.ASK_ARC_REASONING_MODEL ||
      DEFAULT_REASONING_MODEL,
    topK: options.ragTopK || Number(process.env.ASK_ARC_RAG_TOP_K) || DEFAULT_RAG_TOP_K,
  });
  void arcRag.initialize().catch(() => {});

  await mkdir(tempDir, { recursive: true });

  const server = Bun.serve<ClientState>({
    hostname: host,
    port,
    fetch(req, server) {
      const url = new URL(req.url);
      if (url.pathname === "/health") {
        return Response.json({
          ok: true,
          local: true,
          stt: whisperCliPath && existsSync(whisperModelPath) ? "whisper.cpp" : "missing",
          tts: hasClonedProfile(THEO_VOICE) ? THEO_VOICE : "recipe-fallback",
          rag: arcRag.status(),
        });
      }
      if (server.upgrade(req, { data: createClientState() })) {
        return undefined;
      }
      return new Response("Ask Arc local voice daemon\n", {
        status: 200,
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    },
    websocket: {
      open(ws) {
        sendJson(ws, {
          type: "ready",
          local: true,
          sampleRate: DEFAULT_SAMPLE_RATE,
          stt: "whisper.cpp",
          tts: "theo-mlx",
        });
      },
      message(ws, message) {
        void handleSocketMessage(ws, message, {
          tempDir,
          whisperCliPath,
          whisperModelPath,
          arcRag,
        });
      },
      close(ws) {
        ws.data.chunks = [];
        ws.data.activeTurnId = null;
        ws.data.activeSpeechId = null;
        ws.data.cancelledSpeechIds.clear();
        ws.data.busy = false;
      },
    },
  });

  console.log(
    `[ask-arc-voice] local daemon listening on ws://${host}:${port} (health http://${host}:${port}/health)`,
  );
  return server;
}

async function handleSocketMessage(
  ws: Bun.ServerWebSocket<ClientState>,
  message: string | Buffer,
  config: {
    tempDir: string;
    whisperCliPath: string | null;
    whisperModelPath: string;
    arcRag: ReturnType<typeof createArcRagService>;
  },
): Promise<void> {
  if (typeof message !== "string") {
    if (!ws.data.activeTurnId || ws.data.busy) return;
    const next = Buffer.from(message);
    const maxBytes = ws.data.sampleRate * MAX_TURN_SECONDS * 2;
    const totalBytes = ws.data.chunks.reduce((sum, chunk) => sum + chunk.length, 0);
    if (totalBytes + next.length <= maxBytes) ws.data.chunks.push(next);
    return;
  }

  let data: JsonRecord;
  try {
    data = JSON.parse(message) as JsonRecord;
  } catch {
    sendJson(ws, { type: "error", error: "invalid json" });
    return;
  }

  if (data.type === "start") {
    ws.data.chunks = [];
    ws.data.sampleRate = safeSampleRate(data.sampleRate);
    ws.data.activeTurnId = String(data.turnId || crypto.randomUUID());
    ws.data.busy = false;
    sendJson(ws, { type: "listening", turnId: ws.data.activeTurnId });
    return;
  }

  if (data.type === "stop") {
    if (!ws.data.activeTurnId || ws.data.busy) return;
    const turnId = ws.data.activeTurnId;
    ws.data.busy = true;
    sendJson(ws, { type: "transcribing", turnId });
    try {
      const text = await transcribeChunks(ws.data.chunks, ws.data.sampleRate, {
        tempDir: config.tempDir,
        whisperCliPath: config.whisperCliPath,
        whisperModelPath: config.whisperModelPath,
      });
      sendJson(ws, {
        type: "transcript",
        turnId,
        text,
        local: true,
        backend: "whisper.cpp",
      });
    } catch (error) {
      sendJson(ws, {
        type: "error",
        turnId,
        stage: "stt",
        error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      ws.data.chunks = [];
      ws.data.activeTurnId = null;
      ws.data.busy = false;
    }
    return;
  }

  if (data.type === "ask") {
    const question = String(data.question || "").trim();
    const turnId = String(data.turnId || crypto.randomUUID());
    if (!question) {
      sendJson(ws, { type: "error", turnId, stage: "rag", error: "empty question" });
      return;
    }
    sendJson(ws, { type: "thinking", turnId, engine: "ollama-rag" });
    try {
      const answer = await config.arcRag.answer(question);
      sendJson(ws, {
        type: "arc_answer",
        turnId,
        answer: answer.answer,
        message: answer.answer,
        citations: answer.citations,
        refused: answer.refused,
        retrieved: answer.retrieved || [],
        engine: "ollama-rag",
        local: true,
      });
    } catch (error) {
      sendJson(ws, {
        type: "error",
        turnId,
        stage: "rag",
        recoverable: true,
        error: error instanceof Error ? error.message : String(error),
      });
    }
    return;
  }

  if (data.type === "speak") {
    const text = String(data.text || "").trim();
    const turnId = String(data.turnId || "");
    const speechId = String(data.speechId || turnId || crypto.randomUUID());
    if (!text) {
      sendJson(ws, { type: "error", turnId, stage: "tts", error: "empty text" });
      return;
    }
    ws.data.activeSpeechId = speechId;
    ws.data.cancelledSpeechIds.delete(speechId);
    sendJson(ws, { type: "speaking", turnId, speechId, engine: "theo-mlx" });
    try {
      const audio = await synthesizeTheo(text, config.tempDir);
      if (ws.data.cancelledSpeechIds.has(speechId)) {
        ws.data.cancelledSpeechIds.delete(speechId);
        if (ws.data.activeSpeechId === speechId) ws.data.activeSpeechId = null;
        sendJson(ws, { type: "tts_cancelled", turnId, speechId, local: true });
        return;
      }
      sendJson(ws, {
        type: "audio",
        turnId,
        speechId,
        mime: audio.mime,
        audioB64: audio.bytes.toString("base64"),
        engine: audio.engine,
        local: true,
      });
    } catch (error) {
      sendJson(ws, {
        type: "error",
        turnId,
        stage: "tts",
        recoverable: true,
        error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      if (ws.data.activeSpeechId === speechId) ws.data.activeSpeechId = null;
    }
    return;
  }

  if (data.type === "interrupt") {
    const speechId = String(data.speechId || ws.data.activeSpeechId || "");
    if (speechId) ws.data.cancelledSpeechIds.add(speechId);
    ws.data.chunks = [];
    ws.data.activeTurnId = null;
    ws.data.activeSpeechId = null;
    ws.data.busy = false;
    sendJson(ws, { type: "interrupted", speechId: speechId || null, local: true });
  }
}

function createArcRagService(config: {
  sectionsPath: string;
  ollamaHost: string;
  embeddingModel: string;
  reasoningModel: string;
  topK: number;
}) {
  let initialized: Promise<void> | null = null;
  let indexedSections: IndexedArcSection[] = [];
  let sectionCount = 0;
  let lastError: string | null = null;
  let ready = false;

  async function initialize(): Promise<void> {
    if (initialized) return initialized;
    initialized = (async () => {
      try {
        const sections = await loadArcSections(config.sectionsPath);
        sectionCount = sections.length;
        indexedSections = await loadOrBuildArcEmbeddings({
          sections,
          sectionsPath: config.sectionsPath,
          ollamaHost: config.ollamaHost,
          embeddingModel: config.embeddingModel,
        });
        ready = true;
        lastError = null;
      } catch (error) {
        ready = false;
        lastError = error instanceof Error ? error.message : String(error);
        initialized = null;
        throw error;
      }
    })();
    return initialized;
  }

  async function answer(question: string): Promise<ArcRagAnswer> {
    await initialize();
    const queryEmbedding = await ollamaEmbedText(question, {
      ollamaHost: config.ollamaHost,
      model: config.embeddingModel,
    });
    const ranked = rankArcSectionsByEmbedding(indexedSections, queryEmbedding, config.topK);
    return generateGroundedArcAnswer({
      question,
      ranked,
      generateAnswer: async ({ question, sections }) =>
        ollamaGenerateArcAnswer({
          question,
          sections,
          ollamaHost: config.ollamaHost,
          model: config.reasoningModel,
        }),
    });
  }

  function status() {
    return {
      ready,
      sections: sectionCount,
      embeddingModel: config.embeddingModel,
      reasoningModel: config.reasoningModel,
      topK: config.topK,
      error: lastError,
    };
  }

  return { initialize, answer, status };
}

async function generateGroundedArcAnswer(input: {
  question: string;
  ranked: Array<{ section: ArcSection; score: number }>;
  generateAnswer: (input: ArcRagGeneratorInput) => Promise<ArcRagAnswer>;
}): Promise<ArcRagAnswer> {
  const retrievedSections = input.ranked.map((item) => item.section);
  const retrievedIds = new Set(retrievedSections.map((section) => section.id));
  const generated = await input.generateAnswer({
    question: input.question,
    sections: retrievedSections,
  });
  const retrieved = input.ranked.map((item) => ({
    id: item.section.id,
    score: Number(item.score.toFixed(6)),
  }));
  if (generated.refused) {
    return {
      answer: generated.answer || "I don't have that in the arc.",
      citations: [],
      refused: true,
      retrieved,
    };
  }
  const citations = uniqueStrings(generated.citations).filter((id) => retrievedIds.has(id));
  if (citations.length === 0) {
    return {
      answer:
        "I don't have enough grounded citation support in the retrieved arc sections to answer that.",
      citations: [],
      refused: true,
      retrieved,
    };
  }
  return {
    answer: generated.answer || "I don't have that in the arc.",
    citations,
    refused: false,
    retrieved,
  };
}

async function loadArcSections(sectionsPath: string): Promise<ArcSection[]> {
  const raw = await readFile(sectionsPath, "utf8");
  const parsed = JSON.parse(raw) as ArcSection[];
  if (!Array.isArray(parsed)) throw new Error(`arc sections file is not an array: ${sectionsPath}`);
  return parsed.filter((section) => section && section.id && section.title);
}

async function loadOrBuildArcEmbeddings(input: {
  sections: ArcSection[];
  sectionsPath: string;
  ollamaHost: string;
  embeddingModel: string;
}): Promise<IndexedArcSection[]> {
  const sectionsHash = hashSectionsForEmbedding(input.sections);
  const cachePath = arcEmbeddingCachePath(input.sectionsPath, input.embeddingModel);
  const cached = await readEmbeddingCache(cachePath, {
    model: input.embeddingModel,
    sectionsHash,
    sectionCount: input.sections.length,
  });
  if (cached) return cached;

  const indexed: IndexedArcSection[] = [];
  for (const section of input.sections) {
    indexed.push({
      section,
      embedding: await ollamaEmbedText(sectionToEmbeddingText(section), {
        ollamaHost: input.ollamaHost,
        model: input.embeddingModel,
      }),
    });
  }
  await writeEmbeddingCache(cachePath, {
    model: input.embeddingModel,
    sectionsHash,
    indexedSections: indexed,
  });
  return indexed;
}

async function readEmbeddingCache(
  cachePath: string,
  expected: { model: string; sectionsHash: string; sectionCount: number },
): Promise<IndexedArcSection[] | null> {
  try {
    const parsed = JSON.parse(await readFile(cachePath, "utf8")) as {
      model?: string;
      sectionsHash?: string;
      vectors?: Array<{ section: ArcSection; embedding: number[] }>;
    };
    if (parsed.model !== expected.model) return null;
    if (parsed.sectionsHash !== expected.sectionsHash) return null;
    if (!Array.isArray(parsed.vectors) || parsed.vectors.length !== expected.sectionCount) {
      return null;
    }
    return parsed.vectors.map((item) => ({
      section: item.section,
      embedding: item.embedding,
    }));
  } catch {
    return null;
  }
}

async function writeEmbeddingCache(
  cachePath: string,
  data: {
    model: string;
    sectionsHash: string;
    indexedSections: IndexedArcSection[];
  },
): Promise<void> {
  await writeFile(
    cachePath,
    JSON.stringify(
      {
        model: data.model,
        sectionsHash: data.sectionsHash,
        vectors: data.indexedSections,
      },
      null,
      2,
    ),
  );
}

async function ollamaEmbedText(
  text: string,
  config: { ollamaHost: string; model: string },
): Promise<number[]> {
  const host = config.ollamaHost.replace(/\/+$/, "");
  const embedResponse = await fetch(`${host}/api/embed`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: config.model, input: text }),
  }).catch((error) => {
    throw new Error(`ollama embedding request failed: ${error.message}`);
  });

  if (embedResponse.ok) {
    const body = (await embedResponse.json()) as {
      embeddings?: number[][];
      embedding?: number[];
    };
    const embedding = Array.isArray(body.embeddings?.[0]) ? body.embeddings[0] : body.embedding;
    if (Array.isArray(embedding)) return embedding.map(Number);
  }

  const fallbackResponse = await fetch(`${host}/api/embeddings`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: config.model, prompt: text }),
  });
  if (!fallbackResponse.ok) {
    throw new Error(
      `ollama embedding failed (${embedResponse.status}/${fallbackResponse.status}); model=${config.model}`,
    );
  }
  const fallbackBody = (await fallbackResponse.json()) as { embedding?: number[] };
  if (!Array.isArray(fallbackBody.embedding)) {
    throw new Error(`ollama embedding response missing vector; model=${config.model}`);
  }
  return fallbackBody.embedding.map(Number);
}

async function ollamaGenerateArcAnswer(input: {
  question: string;
  sections: ArcSection[];
  ollamaHost: string;
  model: string;
}): Promise<ArcRagAnswer> {
  const host = input.ollamaHost.replace(/\/+$/, "");
  const response = await fetch(`${host}/api/generate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: input.model,
      stream: false,
      format: "json",
      prompt: buildArcAnswerPrompt(input.question, input.sections),
      options: {
        temperature: 0.1,
        top_p: 0.8,
      },
    }),
  });
  if (!response.ok) {
    throw new Error(`ollama generate failed ${response.status}; model=${input.model}`);
  }
  const body = (await response.json()) as { response?: string };
  return parseArcAnswerJson(body.response || "");
}

function buildArcAnswerPrompt(question: string, sections: ArcSection[]): string {
  const context = sections
    .map((section) =>
      [
        `ID: ${section.id}`,
        `TITLE: ${section.title}`,
        `DOMAIN: ${section.domain || ""}`,
        `TEXT: ${section.narration_text || ""}`,
      ].join("\n"),
    )
    .join("\n\n---\n\n");
  return [
    "You answer questions about an arc using ONLY the provided arc sections.",
    "Write natural, helpful prose. Synthesize when the answer is present.",
    "Cite the section id(s) you used in the citations array.",
    "If the answer is genuinely not contained in the provided sections, set refused true and say you do not have it in the arc.",
    "Return JSON only with this exact shape:",
    '{"answer":"natural answer or refusal","citations":["section-id"],"refused":false}',
    "",
    `QUESTION: ${question}`,
    "",
    "ARC SECTIONS:",
    context,
  ].join("\n");
}

function parseArcAnswerJson(raw: string): ArcRagAnswer {
  const cleaned = raw
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/i, "")
    .trim();
  const parsed = JSON.parse(cleaned) as {
    answer?: unknown;
    message?: unknown;
    citations?: unknown;
    refused?: unknown;
  };
  const citations = Array.isArray(parsed.citations)
    ? parsed.citations.map((item) => String(item)).filter(Boolean)
    : [];
  return {
    answer: String(parsed.answer || parsed.message || "").trim(),
    citations,
    refused: parsed.refused === true,
  };
}

function sectionToEmbeddingText(section: ArcSection): string {
  return [
    section.title || "",
    section.domain || "",
    section.narration_text || "",
    JSON.stringify(section.fork || ""),
  ]
    .join("\n")
    .trim();
}

function cosineSimilarity(a: number[], b: number[]): number {
  const n = Math.min(a.length, b.length);
  if (n === 0) return 0;
  let dot = 0;
  let aSq = 0;
  let bSq = 0;
  for (let i = 0; i < n; i++) {
    const av = Number(a[i] || 0);
    const bv = Number(b[i] || 0);
    dot += av * bv;
    aSq += av * av;
    bSq += bv * bv;
  }
  if (aSq === 0 || bSq === 0) return 0;
  return dot / (Math.sqrt(aSq) * Math.sqrt(bSq));
}

function hashSectionsForEmbedding(sections: ArcSection[]): string {
  return createHash("sha256")
    .update(
      JSON.stringify(
        sections.map((section) => ({
          id: section.id,
          title: section.title,
          domain: section.domain || "",
          narration_text: section.narration_text || "",
          fork: section.fork || null,
        })),
      ),
    )
    .digest("hex");
}

function arcEmbeddingCachePath(sectionsPath: string, model: string): string {
  const safeModel = model.replace(/[^a-z0-9_.-]+/gi, "_");
  return `${sectionsPath}.${safeModel}.embeddings.json`;
}

function uniqueStrings(values: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const value of values) {
    const next = String(value || "").trim();
    if (!next || seen.has(next)) continue;
    seen.add(next);
    out.push(next);
  }
  return out;
}

async function transcribeChunks(
  chunks: Buffer[],
  sampleRate: number,
  config: {
    tempDir: string;
    whisperCliPath: string | null;
    whisperModelPath: string;
  },
): Promise<string> {
  if (!config.whisperCliPath) throw new Error("whisper-cli not found");
  if (!existsSync(config.whisperModelPath)) {
    throw new Error(`whisper model not found: ${config.whisperModelPath}`);
  }
  if (chunks.length === 0) throw new Error("empty audio");

  const bytes = Buffer.concat(chunks);
  if (bytes.length < sampleRate * 0.15 * 2) throw new Error("audio too short");
  const samples = new Int16Array(bytes.buffer, bytes.byteOffset, Math.floor(bytes.length / 2));
  const id = crypto.randomUUID();
  const wavPath = join(config.tempDir, `${id}.wav`);
  const outPrefix = join(config.tempDir, id);
  const outTxt = `${outPrefix}.txt`;
  await Bun.write(wavPath, encodePcm16Wav(samples, sampleRate));
  try {
    const result = await runCommand(
      buildWhisperCliArgs({
        binary: config.whisperCliPath,
        modelPath: config.whisperModelPath,
        wavPath,
        outputPrefix: outPrefix,
        prompt: "Ask the Arc Happy Camper VoiceBar BrainLayer cmux golems Etan Theo",
      }),
      { cwd: process.cwd(), timeoutMs: 120_000 },
    );
    if (result.exitCode !== 0) {
      throw new Error(`whisper-cli exited ${result.exitCode}: ${result.stderr}`);
    }
    const transcriptFile = await readFile(outTxt, "utf8").catch(() => "");
    const text = cleanWhisperTranscript(transcriptFile || result.stdout);
    if (!text) throw new Error("empty transcript");
    return text;
  } finally {
    await Promise.allSettled([
      rm(wavPath, { force: true }),
      rm(outTxt, { force: true }),
    ]);
  }
}

async function synthesizeTheo(
  text: string,
  tempDir: string,
): Promise<{ bytes: Buffer; mime: string; engine: string }> {
  if (hasClonedProfile(THEO_VOICE)) {
    const daemonAudio = await synthesizeCloned(text, THEO_VOICE);
    if (daemonAudio) {
      return { bytes: Buffer.from(daemonAudio), mime: "audio/mpeg", engine: "theo-qwen3-daemon" };
    }
  }

  const recipe = await synthesizeTheoViaRecipe(text, tempDir);
  return { bytes: recipe, mime: "audio/wav", engine: "theo-mlx-recipe" };
}

async function synthesizeTheoViaRecipe(text: string, tempDir: string): Promise<Buffer> {
  if (!existsSync(TTS_RECIPE_PYTHON)) throw new Error(`Theo python missing: ${TTS_RECIPE_PYTHON}`);
  if (!existsSync(TTS_RECIPE_VOICE)) throw new Error(`Theo voice config missing: ${TTS_RECIPE_VOICE}`);
  if (!existsSync(TTS_RECIPE_REF)) throw new Error(`Theo reference clip missing: ${TTS_RECIPE_REF}`);

  const id = crypto.randomUUID();
  const outDir = join(tempDir, `tts-${id}`);
  await mkdir(outDir, { recursive: true });
  const refText = await loadTheoReferenceText();
  const prefix = "theo-live";
  try {
    const result = await runCommand(
      [
        TTS_RECIPE_PYTHON,
        "-m",
        "mlx_audio.tts.generate",
        "--model",
        TTS_RECIPE_MODEL,
        "--text",
        text.slice(0, 800),
        "--ref_audio",
        TTS_RECIPE_REF,
        "--ref_text",
        refText,
        "--output_path",
        outDir,
        "--file_prefix",
        prefix,
        "--audio_format",
        "wav",
        "--join_audio",
        "--temperature",
        "0.6",
        "--top_p",
        "0.8",
        "--top_k",
        "20",
      ],
      { cwd: TTS_RECIPE_ROOT, timeoutMs: 180_000 },
    );
    if (result.exitCode !== 0) {
      throw new Error(`Theo MLX render exited ${result.exitCode}: ${result.stderr || result.stdout}`);
    }
    const wavPath = join(outDir, `${prefix}.wav`);
    return Buffer.from(await readFile(wavPath));
  } finally {
    await rm(outDir, { recursive: true, force: true }).catch(() => {});
  }
}

async function loadTheoReferenceText(): Promise<string> {
  const config = JSON.parse(await readFile(TTS_RECIPE_VOICE, "utf8")) as {
    ref_text?: string;
  };
  const refText = String(config.ref_text || "").trim();
  if (!refText) throw new Error("Theo ref_text missing");
  return refText;
}

async function runCommand(
  args: string[],
  options: { cwd: string; timeoutMs: number },
): Promise<CommandResult> {
  const started = performance.now();
  const proc = Bun.spawn(args, {
    cwd: options.cwd,
    env: process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const timeout = setTimeout(() => {
    try {
      proc.kill();
    } catch {}
  }, options.timeoutMs);
  try {
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
  } finally {
    clearTimeout(timeout);
  }
}

function createClientState(): ClientState {
  return {
    id: crypto.randomUUID(),
    chunks: [],
    sampleRate: DEFAULT_SAMPLE_RATE,
    activeTurnId: null,
    activeSpeechId: null,
    cancelledSpeechIds: new Set(),
    busy: false,
  };
}

function safeSampleRate(value: unknown): number {
  const sampleRate = Number(value);
  if (!Number.isFinite(sampleRate)) return DEFAULT_SAMPLE_RATE;
  if (sampleRate < 8000 || sampleRate > 48000) return DEFAULT_SAMPLE_RATE;
  return Math.round(sampleRate);
}

function writeAscii(bytes: Uint8Array, offset: number, value: string): void {
  for (let i = 0; i < value.length; i++) bytes[offset + i] = value.charCodeAt(i);
}

function sendJson(ws: Bun.ServerWebSocket<ClientState>, data: JsonRecord): void {
  ws.send(JSON.stringify(data));
}

function isMain(): boolean {
  const invoked = process.argv[1] ? fileURLToPath(new URL(`file://${process.argv[1]}`)) : "";
  return dirname(invoked) === dirname(fileURLToPath(import.meta.url)) && invoked.endsWith("dashboard-voice-daemon.ts");
}

if (isMain()) {
  await startDashboardVoiceDaemon();
}
