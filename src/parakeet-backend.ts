import type { STTBackend, STTResult, STTTranscribeOptions } from "./stt";
import { parakeetServer, ParakeetServiceError, type ParakeetResponse } from "./parakeet-server";
import type { STTOutcome } from "./soundlayer/contracts";
import { requestedLanguageCode } from "./language-config";
import { retainParakeetFallback, type ParakeetFallbackAttempt } from "./parakeet-attempts";
import { mkdirSync, writeFileSync, unlinkSync, openSync, closeSync } from "fs";
import { join } from "path";
import { createHash, randomUUID } from "crypto";
import { getStateDir } from "./paths";
import { noteRecognizerEngine, noteRecognizerEffective } from "./recognizer-state";
import { probeParakeetSpeech, PARAKEET_EMPTY_SPEECH_THRESHOLD, type ParakeetSpeechEvidence } from "./parakeet-vad";
import { probeParakeetLanguage, PARAKEET_LID_MIN_CONFIDENCE, type ParakeetLanguageInput, type ParakeetLanguageEvidence } from "./parakeet-lid";

export class STTQualificationError extends Error {
  constructor(readonly outcome: STTOutcome, readonly attempt: unknown) {
    super(`Transcription unresolved: ${outcome}`); this.name = "STTQualificationError";
  }
}

/** Local model-card languages; not an audio language detector. */
export const PARAKEET_LANGUAGES = new Set("en es fr de bg hr cs da nl et fi el hu it lv lt mt pl pt ro sk sl sv ru uk".split(" "));

export function parakeetLanguage(options: STTTranscribeOptions = {}, env: NodeJS.ProcessEnv = process.env): string {
  const selected = requestedLanguageCode(options.language ?? env.QA_VOICE_WHISPER_LANG ?? "auto");
  const detected = options.detectedLanguage === undefined ? null : requestedLanguageCode(options.detectedLanguage);
  // A language hint never overrides the user's recognizer choice. The worker
  // runs multilingual v3; these values support an advisory only, not routing.
  if (selected && selected !== "auto" && !PARAKEET_LANGUAGES.has(selected)) return selected;
  return detected ?? selected ?? "auto";
}

interface WavInfo { frames: number; sampleRate: number; lastActiveSeconds: number; allZero: boolean; dataOffset: number; }

/** Read geometry and a conservative activity marker, never trim/rewrite audio. */
export function parakeetWavInfo(bytes: Uint8Array): WavInfo {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (offset: number) => String.fromCharCode(...bytes.subarray(offset, offset + 4));
  if (bytes.length < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE" || v.getUint32(4, true) + 8 !== bytes.length) throw new Error("Invalid WAV");
  let sampleRate = 0, dataOffset = -1, dataBytes = 0;
  for (let offset = 12; offset + 8 <= bytes.length;) {
    const size = v.getUint32(offset + 4, true), begin = offset + 8;
    if (begin + size > bytes.length) throw new Error("Truncated WAV");
    if (tag(offset) === "fmt ") {
      if (size < 16 || v.getUint16(begin, true) !== 1 || v.getUint16(begin + 2, true) !== 1 ||
          v.getUint16(begin + 14, true) !== 16 || v.getUint16(begin + 12, true) !== 2) throw new Error("Expected PCM16 mono WAV");
      sampleRate = v.getUint32(begin + 4, true);
    } else if (tag(offset) === "data") {
      if (dataOffset !== -1) throw new Error("Ambiguous WAV data");
      dataOffset = begin; dataBytes = size;
    }
    offset = begin + size + (size % 2);
  }
  if (sampleRate !== 16000 || dataOffset < 0 || dataBytes === 0 || dataBytes % 2) throw new Error("Expected complete 16kHz WAV");
  let last = 0, allZero = true;
  for (let i = 0; i < dataBytes / 2; i++) {
    const sample = v.getInt16(dataOffset + i * 2, true);
    if (sample !== 0) allZero = false;
    if (Math.abs(sample) >= 512) last = (i + 1) / sampleRate;
  }
  return { frames: dataBytes / 2, sampleRate, lastActiveSeconds: last, allZero, dataOffset };
}

export function parakeetOutputRisk(result: ParakeetResponse, info: WavInfo): string | null {
  if (!result || typeof result.text !== "string") return "invalid-response";
  const evidence = result.attemptEvidence;
  if (evidence?.status && !["RETURNED", "EMPTY_RESPONSE"].includes(evidence.status)) return "provider-" + evidence.status.toLowerCase();
  if (evidence?.processExitCode !== undefined && evidence.processExitCode !== null && evidence.processExitCode !== 0) return "provider-error";
  if (evidence?.decodeCoverage === "PARTIAL" || evidence?.tail === "KNOWN_MISSING") return "incomplete-response";
  if (evidence?.timesValid === false) return "invalid-timing";
  if (!result.complete || result.sample_rate !== info.sampleRate || result.input_frames !== info.frames || result.covered_frames !== info.frames) return "incomplete-response";
  if (!result.text.trim()) return "empty-response";
  if (info.allZero) return "zero-pcm-response";
  const duration = info.frames / info.sampleRate;
  // These are retry heuristics, not acoustic completeness or silence claims.
  // A questionable full response is replaced by a full-audio Whisper attempt;
  // never trim real tails or merge a guessed transcript into the result.
  if (duration >= 8 && result.text.trim().split(/\s+/u).length < Math.max(2, duration / 10)) return "sparse-response";
  if (result.last_token_end_s !== null && (result.last_token_end_s < 0 || result.last_token_end_s > duration)) return "invalid-timing";
  if (duration >= 8 && result.last_token_end_s !== null && info.lastActiveSeconds - result.last_token_end_s > Math.max(3, Math.min(8, duration * 0.05))) return "uncovered-tail";
  return null;
}

export interface ParakeetBackendDeps {
  fallbackBackend: STTBackend;
  transcribe?: (path: string) => Promise<ParakeetResponse>;
  isAvailable?: () => boolean;
  unload?: () => Promise<void>;
  env?: () => NodeJS.ProcessEnv;
  retainFallback?: (attempt: ParakeetFallbackAttempt) => string;
  speechProbe?: (path: string) => Promise<ParakeetSpeechEvidence>;
  languageProbe?: (input: ParakeetLanguageInput) => Promise<ParakeetLanguageEvidence>;
  recoveryWhisper?: () => { attempt: unknown } | null;
}

/** Raw text is retained; input.ts's common finalization applies the dictionary
 * to Parakeet exactly as it does to Whisper, including personal alias policy.
 */
export class ParakeetBackend implements STTBackend {
  readonly name = "parakeet-resident";
  private queue: Promise<unknown> = Promise.resolve();
  constructor(private readonly deps: ParakeetBackendDeps) {}

  async isAvailable(): Promise<boolean> {
    return (this.deps.isAvailable ?? (() => parakeetServer.isAvailable()))() || await this.deps.fallbackBackend.isAvailable();
  }

  async transcribe(audioPath: string, options?: STTTranscribeOptions): Promise<STTResult> {
    const result = this.queue.then(() => this.transcribeReserved(audioPath, options));
    this.queue = result.catch(() => {});
    return result;
  }

  /** Called after stopping admissions and cancelling owned providers. */
  async drain(): Promise<void> { await this.queue; }

  private async transcribeReserved(audioPath: string, options?: STTTranscribeOptions): Promise<STTResult> {
    const started = Date.now();
    let info: WavInfo | null = null;
    let inputPath = audioPath, inputSha256: string | null = null, ownedSnapshot: string | null = null;
    let captureTruncated = false;
    let inputBytes: Uint8Array;
    try {
      const bytes = new Uint8Array(await Bun.file(audioPath).arrayBuffer());
      inputBytes = bytes;
      if (bytes.length >= 12 && Buffer.from(bytes.subarray(0, 4)).toString() === "RIFF" && Buffer.from(bytes.subarray(8, 12)).toString() === "WAVE") {
        captureTruncated = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(4, true) + 8 > bytes.length;
      }
      let parsed: WavInfo | null = null;
      try { parsed = parakeetWavInfo(bytes); } catch { /* Preserve all retained bytes; never repair the header. */ }
      const root = join(getStateDir(), "parakeet-inputs");
      mkdirSync(root, { recursive: true, mode: 0o700 });
      const snapshot = join(root, `${randomUUID()}.wav`);
      const fd = openSync(snapshot, "wx", 0o400);
      ownedSnapshot = snapshot;
      try { writeFileSync(fd, bytes); } finally { closeSync(fd); }
      inputPath = snapshot; info = parsed;
      inputSha256 = createHash("sha256").update(bytes).digest("hex");
    } catch (error) {
      if (ownedSnapshot) { try { unlinkSync(ownedSnapshot); } catch {} }
      throw error; // Cannot bind provider input to a snapshot; do not guess identity.
    }
    try { return await this.transcribeSnapshot(audioPath, inputPath, info, inputSha256, captureTruncated, started, inputBytes!, options); }
    finally {
      if (ownedSnapshot) {
        try { unlinkSync(ownedSnapshot); }
        catch { console.error("[voicelayer] Could not remove private Parakeet input snapshot"); }
      }
    }
  }

  private async transcribeSnapshot(audioPath: string, inputPath: string, info: WavInfo | null,
    inputSha256: string | null, captureTruncated: boolean, started: number, inputBytes: Uint8Array, options?: STTTranscribeOptions): Promise<STTResult> {
    const retain = (attempt: ParakeetFallbackAttempt): string | undefined => {
      try { return (this.deps.retainFallback ?? retainParakeetFallback)({ ...attempt, languageEvidence }); }
      catch { console.error("[voicelayer] Could not save Parakeet fallback diagnostic"); return undefined; }
    };
    let speechEvidence: ParakeetSpeechEvidence | undefined;
    let nativeBoundaryPath: string | undefined;
    const env = this.deps.env?.() ?? process.env;
    const language = parakeetLanguage(options, env);
    let languageWarning: STTResult["languageWarning"] = language === "auto" ? "auto-language-unverified" :
      !PARAKEET_LANGUAGES.has(language) ? "unsupported-language-advisory" : undefined;
    let languageTask: Promise<ParakeetLanguageEvidence> | undefined, languageEvidence: ParakeetLanguageEvidence | undefined;
    const finishLanguage = async () => {
      if (!languageTask || languageEvidence) return;
      languageEvidence = await languageTask;
      if (languageEvidence.inputSha256 !== inputSha256) languageEvidence = { status: "UNKNOWN", errorType: "InputIdentityMismatch" };
      if (languageEvidence.status === "COMPLETE" && !(typeof languageEvidence.language === "string" && /^[a-z]{2,3}$/.test(languageEvidence.language) &&
          typeof languageEvidence.probability === "number" && Number.isFinite(languageEvidence.probability) && languageEvidence.probability >= 0 && languageEvidence.probability <= 1)) languageEvidence = { status: "UNKNOWN", errorType: "InvalidEstimate" };
      if (languageEvidence.status === "COMPLETE") {
        if (!PARAKEET_LANGUAGES.has(languageEvidence.language!) && languageEvidence.probability! >= PARAKEET_LID_MIN_CONFIDENCE) languageWarning = "unsupported-language-advisory";
        else if (languageWarning !== "unsupported-language-advisory") languageWarning = languageEvidence.probability! < PARAKEET_LID_MIN_CONFIDENCE ? "language-detection-low-confidence" : undefined;
      }
      console.error(`[voicelayer] Parakeet optional language detection: ${languageEvidence.status}; language=${languageEvidence.status === "COMPLETE" ? languageEvidence.language : "unknown"}; confidence=${languageEvidence.status === "COMPLETE" ? languageEvidence.probability : "unknown"}; warning=${languageWarning ?? "none"}; selected recognizer unchanged`);
    };
    const fallback = async (reason: string, parakeet: unknown = null, parakeetErrorStatus?: string, parakeetCleanupFailure?: { name: string; message: string }) => {
      await finishLanguage(); // No fallback model while a language child is still owned.
      // Commit the first raw boundary BEFORE starting W, so interruption during
      // fallback cannot erase the original empty/error/partial P observation.
      const previousAttemptPath = nativeBoundaryPath ?? retain({ audioPath, submittedPath: inputPath, inputSha256, reason, parakeet, parakeetErrorStatus, parakeetCleanupFailure, speechEvidence,
        whisper: null, errorType: null, stage: "native-or-input-boundary" });
      try {
        // Never allocate Whisper while cleanup of our P model is unconfirmed.
        await (this.deps.unload ?? (() => parakeetServer.unload()))();
        noteRecognizerEngine("whisper", { phase: "loading", error: null }); noteRecognizerEffective("whisper", reason);
        const result = await this.deps.fallbackBackend.transcribe(inputPath, options);
        noteRecognizerEngine("whisper", { phase: result.backend.startsWith("whisper-server") ? "ready" : "sleeping", available: true, error: null });
        const evidence = result.attemptEvidence;
        if ((evidence?.inputSha256 && evidence.inputSha256 !== inputSha256) || (evidence?.inputPath && evidence.inputPath !== inputPath)) throw new STTQualificationError("REFUSED_AUDIO_IDENTITY_MISMATCH", result);
        if (evidence?.status === "ERROR" || evidence?.status === "TIMEOUT" ||
            (evidence?.processExitCode !== undefined && evidence.processExitCode !== null && evidence.processExitCode !== 0)) throw new STTQualificationError("UNRESOLVED_FALLBACK_FAILED", result);
        if (typeof result.text !== "string" || evidence?.status === "PARTIAL" || evidence?.status === "INVALID" ||
            evidence?.decodeCoverage === "PARTIAL" || evidence?.tail === "KNOWN_MISSING") throw new STTQualificationError("UNRESOLVED_FALLBACK_INCOMPLETE", result);
        const firstWasEmpty = parakeet !== null && typeof parakeet === "object" && "text" in parakeet && typeof parakeet.text === "string" && !parakeet.text.trim() && !parakeetErrorStatus;
        if (!result.text.trim() && !info?.allZero) throw new STTQualificationError(firstWasEmpty ? "UNRESOLVED_BOTH_EMPTY" : "UNRESOLVED_FALLBACK_EMPTY", result);
        // Exact integer zeros contain no captured signal. Still perform the
        // required Whisper retry and retain its raw words, but never deliver a
        // hallucinated word from mathematically zero PCM. No RMS/VAD threshold,
        // cropping or removal of quiet/nonzero samples is involved.
        const text = info?.allZero ? "" : result.text;
        const outcome: STTOutcome = info?.allZero ? "VERIFIED_ZERO_PCM" : captureTruncated ? "FALLBACK_NONEMPTY_CAPTURE_TRUNCATED" :
          evidence?.timesValid === false ? "FALLBACK_NONEMPTY_INVALID_TIMESTAMPS" : evidence?.tail === "VERIFIED_BY_EXTERNAL_EVIDENCE" ? "FALLBACK_NONEMPTY_TAIL_VERIFIED" : "FALLBACK_NONEMPTY_COMPLETENESS_UNKNOWN";
        const fallbackEvidencePath = retain({ audioPath, submittedPath: inputPath, inputSha256, reason, parakeet, parakeetErrorStatus, parakeetCleanupFailure, speechEvidence, whisper: result, errorType: null, deliveryText: text, outcome, previousAttemptPath, stage: "fallback-terminal" });
        return { ...result, text, outcome, backend: `${this.name}+fallback-${reason}->${result.backend}${info?.allZero ? "+zero-pcm-empty" : "+qualified-fallback"}`, durationMs: Date.now() - started, fallbackEvidencePath, languageWarning, languageEvidence };
      } catch (error) {
        const outcome = error instanceof STTQualificationError ? error.outcome : "UNRESOLVED_FALLBACK_FAILED";
        const whisperErrorAttempt = error instanceof Error && "attempt" in error ? error.attempt : undefined;
        retain({ audioPath, submittedPath: inputPath, inputSha256, reason, parakeet, parakeetErrorStatus, parakeetCleanupFailure, speechEvidence, whisper: error instanceof STTQualificationError ? error.attempt as STTResult : null, whisperErrorAttempt, errorType: error instanceof Error ? error.name : "unknown", outcome, previousAttemptPath, stage: "fallback-terminal" });
        throw error; // A diagnostic failure must never replace the provider error.
      }
    };
    const recovery = this.deps.recoveryWhisper?.();
    if (recovery) return fallback("parakeet-startup-failed", recovery.attempt, "ERROR");
    if (languageWarning) console.error(`[voicelayer] Parakeet language advisory: ${languageWarning}; keeping the selected recognizer`);
    if (options?.promptOverride?.trim()) console.error("[voicelayer] Parakeet selected: context prompt not applied; dictionary aliases remain post-decode");
    if (!info) return fallback("input-format");
    if (env.VOICELAYER_PARAKEET_LID_WARNING === "1") {
      languageTask = Promise.resolve().then(() => (this.deps.languageProbe ?? (input => probeParakeetLanguage(input, env)))({ bytes: inputBytes, dataOffset: info.dataOffset, frames: info.frames, inputSha256: inputSha256! }))
        .catch(error => ({ status: "UNKNOWN" as const, inputSha256: inputSha256!, errorType: error instanceof Error ? error.name : "unknown" }));
    }
    let returned: ParakeetResponse | null = null;
    try {
      const result = returned = await (this.deps.transcribe ?? (path => parakeetServer.transcribe(path)))(inputPath);
      await finishLanguage();
      if ((result.attemptEvidence?.inputSha256 && result.attemptEvidence.inputSha256 !== inputSha256) ||
          (result.attemptEvidence?.inputPath && result.attemptEvidence.inputPath !== inputPath)) return fallback("input-identity", result);
      const reason = parakeetOutputRisk(result, info);
      if (reason === "empty-response") {
        nativeBoundaryPath = retain({ audioPath, submittedPath: inputPath, inputSha256, reason, parakeet: result, whisper: null, errorType: null, stage: "native-or-input-boundary" });
        try { speechEvidence = await (this.deps.speechProbe ?? probeParakeetSpeech)(inputPath); }
        catch (error) { speechEvidence = { status: "UNKNOWN", threshold: PARAKEET_EMPTY_SPEECH_THRESHOLD, errorType: error instanceof Error ? error.name : "unknown" }; }
        if (speechEvidence.status === "COMPLETE" && speechEvidence.threshold === PARAKEET_EMPTY_SPEECH_THRESHOLD &&
            speechEvidence.inputSha256 === inputSha256 && speechEvidence.frames === info.frames && speechEvidence.analyzedFrames === info.frames &&
            speechEvidence.speechFrames === 0 && typeof speechEvidence.maxProbability === "number" && Number.isFinite(speechEvidence.maxProbability) &&
            speechEvidence.maxProbability >= 0 && speechEvidence.maxProbability < PARAKEET_EMPTY_SPEECH_THRESHOLD) {
          const outcome: STTOutcome = "VAD_NO_SPEECH";
          const fallbackEvidencePath = retain({ audioPath, submittedPath: inputPath, inputSha256, reason: "vad-no-speech", parakeet: result,
            whisper: null, whisperStatus: "NOT_RUN", speechEvidence, errorType: null, deliveryText: "", outcome, previousAttemptPath: nativeBoundaryPath, stage: "native-terminal" });
          return { text: "", backend: this.name + "+vad-no-speech", durationMs: Date.now() - started, outcome, fallbackEvidencePath, languageWarning, languageEvidence, attemptEvidence: result.attemptEvidence };
        }
        nativeBoundaryPath = retain({ audioPath, submittedPath: inputPath, inputSha256, reason, parakeet: result, whisper: null,
          speechEvidence, errorType: null, previousAttemptPath: nativeBoundaryPath, stage: "vad-boundary" }) ?? nativeBoundaryPath;
      }
      if (reason) return fallback(reason, result);
      return { text: result.text, backend: this.name, durationMs: Date.now() - started, outcome: "NATIVE_NONEMPTY_COMPLETENESS_UNKNOWN", languageWarning, languageEvidence, attemptEvidence: result.attemptEvidence };
    } catch (error) {
      noteRecognizerEngine("parakeet", { phase: "error", error: error instanceof ParakeetServiceError && error.cleanupFailure ? "cleanup-unconfirmed" : "parakeet-provider-error" });
      // No retry of Parakeet after a provider/protocol error; owned child cleanup
      // belongs to the manager. The next request may cold-start a healthy child.
      return fallback("provider-error", returned ?? (error instanceof ParakeetServiceError ? error.attempt : null), error instanceof ParakeetServiceError ? error.status : "ERROR", error instanceof ParakeetServiceError ? error.cleanupFailure : undefined);
    }
  }
}
