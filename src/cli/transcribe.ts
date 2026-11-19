#!/usr/bin/env bun
/**
 * `voicelayer transcribe <file.wav> [--language auto|en|he] [--json]`
 *
 * A thin wrapper over the dictation path: the backend `getBackend()` picks,
 * then the same dictation finalize stage (dictionary rules, punctuation,
 * polish, paragraphs) a VoiceBar History re-transcribe of a VAD recording runs.
 * No new engine and no new settings. Every sidecar this process launched is
 * stopped before it exits; an adopted resident server is detached, never killed.
 */
import { existsSync, readFileSync, statSync } from "fs";
import { basename, resolve } from "path";
import type { STTBackend } from "../stt";

export const TRANSCRIPT_FORMAT = "voicelayer-transcript/1";

const LANGUAGE_MODES = { auto: "auto", en: "english", he: "hebrew" } as const;
type LanguageFlag = keyof typeof LANGUAGE_MODES;

const USAGE = `Usage: voicelayer transcribe <file.wav> [--language auto|en|he] [--json]

Transcribes a 16 kHz mono 16-bit PCM WAV with the speech-to-text backend and
text processing a dictation uses. Prints the text; with --json prints one line:
{"format":"${TRANSCRIPT_FORMAT}","text":...,"backend":...,"model":...,"language":...}
Without --language the dictation language setting applies (QA_VOICE_WHISPER_LANG, default auto).
Exit 0 with text; 1 on a missing or unsupported file, an empty result or a backend failure; 2 on bad arguments.
Convert other audio first: ffmpeg -i in.m4a -ac 1 -ar 16000 -c:a pcm_s16le out.wav
`;

export interface TranscribeCliDeps {
  stdout?: (text: string) => void;
  stderr?: (text: string) => void;
  /** Test seam; defaults to the dictation backend selector. */
  getBackend?: () => Promise<STTBackend>;
  /** Test seam; defaults to stopping this process's polish and STT sidecars. */
  shutdown?: () => Promise<void>;
}

interface ParsedArgs { file: string; language: LanguageFlag | null; json: boolean }

function parseArgs(argv: string[]): ParsedArgs | "help" | string {
  let file: string | null = null;
  let language: LanguageFlag | null = null;
  let json = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    if (arg === "--help" || arg === "-h") return "help";
    if (arg === "--json") { json = true; continue; }
    if (arg === "--language" || arg.startsWith("--language=")) {
      const value = arg === "--language" ? argv[++i] : arg.slice("--language=".length);
      if (value !== "auto" && value !== "en" && value !== "he") return `--language must be auto, en or he (got ${value ?? "nothing"})`;
      language = value;
      continue;
    }
    if (arg.startsWith("-")) return `unknown option ${arg}`;
    if (file !== null) return "exactly one audio file is required";
    file = arg;
  }
  return file === null ? "an audio file is required" : { file, language, json };
}

/** The recogniser and its gates expect what VoiceBar records: 16 kHz mono 16-bit PCM. */
async function wavFormatError(path: string): Promise<string | null> {
  const { parseWavAudioInfo } = await import("../stt-pause-map");
  const info = parseWavAudioInfo(new Uint8Array(readFileSync(path)));
  if (!info) return "not a readable WAV file";
  if (info.audioFormat !== 1 || info.sampleRate !== 16000 || info.channels !== 1 || info.bitsPerSample !== 16) {
    return `unsupported WAV (${info.sampleRate} Hz, ${info.channels} channel(s), ${info.bitsPerSample}-bit, format ${info.audioFormat}); need 16 kHz mono 16-bit PCM`;
  }
  return info.dataSize > 0 ? null : "the WAV holds no audio";
}

async function modelForBackend(backend: string): Promise<string> {
  const { normalizeWhisperBackend } = await import("../recording-provenance");
  const { whisperServerLaunchRecord } = await import("../whisper-server");
  const { whisperAssetPath, defaultParakeetModelPath } = await import("../recognizer-assets");
  const kind = normalizeWhisperBackend(backend);
  if (kind === "server") return basename(whisperServerLaunchRecord()?.modelPath ?? whisperAssetPath());
  if (kind === "cli") return basename(whisperAssetPath());
  const produced = backend.split("->").pop()?.trim() ?? "";
  if (produced.startsWith("parakeet")) return basename(defaultParakeetModelPath());
  if (produced.startsWith("wispr")) return "wispr-flow";
  return "unknown";
}

async function stopOwnedSidecars(): Promise<void> {
  const { shutdownSTTBackends } = await import("../stt");
  const { stopSTTPolishServerAndWait } = await import("../stt-polish-server");
  const results = await Promise.allSettled([stopSTTPolishServerAndWait(), shutdownSTTBackends()]);
  const failed = results.find(result => result.status === "rejected");
  if (failed?.status === "rejected") throw failed.reason;
}

export async function runTranscribeCli(argv: string[], deps: TranscribeCliDeps = {}): Promise<number> {
  const stdout = deps.stdout ?? ((text: string) => { process.stdout.write(text); });
  const stderr = deps.stderr ?? ((text: string) => { process.stderr.write(text); });
  const parsed = parseArgs(argv);
  if (parsed === "help") { stdout(USAGE); return 0; }
  if (typeof parsed === "string") { stderr(`voicelayer transcribe: ${parsed}\n${USAGE}`); return 2; }

  const file = resolve(parsed.file);
  if (!existsSync(file) || !statSync(file).isFile()) {
    stderr(`voicelayer transcribe: file not found: ${parsed.file}\n`);
    return 1;
  }
  const formatError = await wavFormatError(file);
  if (formatError) {
    stderr(`voicelayer transcribe: ${parsed.file}: ${formatError}\n`);
    return 1;
  }
  // Same switch a dictation reads; set before any decode reads it.
  if (parsed.language) process.env.QA_VOICE_WHISPER_LANG = LANGUAGE_MODES[parsed.language];

  let code = 1;
  try {
    const { getBackend } = await import("../stt");
    const { buildBoundaryContext, finalizeTranscriptionResultForSurface, shouldBuildBoundaryContext } = await import("../input");
    const { processingEnv } = await import("../processing-settings");
    const { getLanguageModeFromEnv } = await import("../language-config");
    const backend = await (deps.getBackend ?? getBackend)();
    const result = await backend.transcribe(file);
    const env = processingEnv();
    const boundary = shouldBuildBoundaryContext(result.text, env)
      ? await buildBoundaryContext(file, result.segments, result.segmentsAudioSha256, env)
      : undefined;
    const finalized = await finalizeTranscriptionResultForSurface(result.text, "dictation", env, boundary);
    const text = finalized.text.trim() ? finalized.text : "";
    if (!text) {
      stderr(`voicelayer transcribe: empty result: no words recognised in ${parsed.file} (backend ${result.backend})\n`);
    } else {
      const mode = getLanguageModeFromEnv();
      const language = mode === "english" ? "en" : mode === "hebrew" ? "he" : "auto";
      stdout(parsed.json
        ? `${JSON.stringify({ format: TRANSCRIPT_FORMAT, text, backend: result.backend, model: await modelForBackend(result.backend), language })}\n`
        : `${text}\n`);
      code = 0;
    }
  } catch (error) {
    stderr(`voicelayer transcribe: ${error instanceof Error ? error.message : String(error)}\n`);
    code = 1;
  } finally {
    try { await (deps.shutdown ?? stopOwnedSidecars)(); }
    catch (error) {
      stderr(`voicelayer transcribe: sidecar shutdown unconfirmed: ${error instanceof Error ? error.message : String(error)}\n`);
      code = 1;
    }
  }
  return code;
}

if (import.meta.main) {
  // Exit explicitly: idle timers in the shared STT modules must not hold the CLI open.
  process.exit(await runTranscribeCli(process.argv.slice(2)));
}
