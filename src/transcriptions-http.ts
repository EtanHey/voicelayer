import { timingSafeEqual } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import { archiveVoiceBarUntranscribedRecording, buildBoundaryContext, finalizeTranscriptionResultForSurface,
  shouldBuildBoundaryContext, updateArchivedTranscript, updateArchivedRecordingMetadata } from "./input";
import { residencyBusy } from "./model-residency-busy";
import { parakeetWavInfo } from "./parakeet-backend";
import { processingEnv } from "./processing-settings";
import { getLanguageModeFromEnv } from "./language-config";
import { readRecognizerStatus, markRecognizerCleanupUnconfirmed } from "./recognizer-state";
import { loadSpeechSecret } from "./speech-control";
import { getBackend, type STTBackend } from "./stt";
import { requireIsolatedOverride } from "./test-isolation";
import { UpdateBusyError, withVoiceAdmission } from "./update-gate-admission";
import { reserveArchiveRetranscription } from "./voice-operation-reservation";
import { unloadOwnedServer, whisperServerLaunchRecord } from "./whisper-server";

export const MAX_TRANSCRIPTION_BYTES = 25 * 1024 * 1024;
export function transcriptionsSecretPath(): string {
  requireIsolatedOverride(process.env, "VOICELAYER_STATE_DIR");
  return join(process.env.VOICELAYER_STATE_DIR || join(homedir(), ".voicelayer"), "transcriptions.secret");
}
const failure = (status: number, message: string) => Response.json({ error: { message } }, { status,
  headers: status === 503 ? { "Retry-After": "1" } : {} });
function modelLoadable(): boolean {
  const state = readRecognizerStatus(), selected = state.effective ?? state.desired, engine = state.engines[selected];
  return engine.assets_present && !["downloading", "verifying", "runtime"].includes(engine.download.state) &&
    engine.error !== "cleanup-unconfirmed" && state.switch_refusal_reason !== "cleanup-unconfirmed";
}
export function startTranscriptionsHttp(options: {
  hostname?: string; port?: number; decode?: STTBackend["transcribe"];
  canLoad?: () => boolean; deadlineSignal?: () => AbortSignal | undefined;
} = {}) {
  const hostname = options.hostname ?? process.env.VOICELAYER_TRANSCRIPTIONS_HOST ?? "127.0.0.1";
  const port = options.port ?? Number(process.env.VOICELAYER_TRANSCRIPTIONS_PORT ?? "8179");
  if (hostname !== "127.0.0.1") throw new Error("Transcriptions must bind to 127.0.0.1");
  if (!Number.isInteger(port) || port < 0 || port > 65535 || (options.port === undefined && port === 0)) throw new Error("Invalid transcriptions port");
  const token = Buffer.from(loadSpeechSecret(transcriptionsSecretPath())), canLoad = options.canLoad ?? modelLoadable;
  const decode = options.decode ?? (async (path, opts) => (await getBackend()).transcribe(path, opts));
  return Bun.serve({
    hostname, port, idleTimeout: 0, maxRequestBodySize: MAX_TRANSCRIPTION_BYTES + 65536,
    error: () => failure(500, "Transcription request failed"),
    async fetch(request) {
      const supplied = Buffer.from(request.headers.get("authorization")?.match(/^Bearer (.+)$/i)?.[1] ?? "");
      if (supplied.length !== token.length || !timingSafeEqual(supplied, token)) return failure(401, "Unauthorized");
      if (new URL(request.url).pathname !== "/v1/audio/transcriptions" || request.method !== "POST") return failure(404, "Not found");
      if (residencyBusy()) return failure(409, "VoiceLayer is busy; retry when idle");
      // Leave twenty seconds of T3's two-minute budget for confirmed provider cleanup.
      const signal = AbortSignal.any([request.signal, options.deadlineSignal?.() ?? AbortSignal.timeout(100_000)]);
      const interrupted = Promise.withResolvers<never>(), abort = () => interrupted.reject(signal.reason);
      signal.addEventListener("abort", abort, { once: true });
      let form: FormData;
      try { signal.throwIfAborted(); form = await Promise.race([request.formData(), interrupted.promise]); }
      catch { return failure(signal.aborted ? 503 : 400, signal.aborted ? "Upload cancelled or timed out" : "Expected multipart form data within the upload limit"); }
      finally { signal.removeEventListener("abort", abort); }
      const file = form.get("file"), language = form.get("language"), prompt = form.get("prompt");
      const format = form.get("response_format") ?? "json";
      if (!(file instanceof File) || (language !== null && typeof language !== "string") ||
          (prompt !== null && typeof prompt !== "string") || (format !== "json" && format !== "text")) return failure(400, "Expected WAV file, optional language/prompt and json or text response_format");
      if (file.size > MAX_TRANSCRIPTION_BYTES) return failure(413, "WAV exceeds 25 MiB");
      const bytes = new Uint8Array(await file.arrayBuffer());
      let durationMs: number;
      try { durationMs = parakeetWavInfo(bytes).frames / 16; }
      catch { return failure(400, "Expected complete mono 16kHz PCM16 WAV"); }
      // Upload parsing yields: recheck and reserve together before any decode await.
      if (residencyBusy()) return failure(409, "VoiceLayer is busy; retry when idle");
      const reservation = reserveArchiveRetranscription();
      if (!reservation) return failure(409, "VoiceLayer is busy; retry when idle");
      let audio: string | undefined, decoded = false, whisperInference = false, reason = "failed";
      try {
        return await withVoiceAdmission(async () => {
          const archive = archiveVoiceBarUntranscribedRecording({ audioBytes: bytes,
            source: "voicebar", uploadSource: "t3", silenceMode: "standard", pushToEnd: false,
            durationMs, backend: "not-transcribed", reason: "captured" });
          audio = join(archive, "audio.wav");
          signal.throwIfAborted();
          if (!canLoad()) { reason = "unavailable"; throw new Error(reason); }
          const result = await decode(audio, { signal, residentOnly: true, onWhisperInferenceStarted: () => { whisperInference = true; }, ...(prompt ? { promptOverride: prompt } : {}) });
          decoded = true; signal.throwIfAborted();
          const env = { ...processingEnv(), QA_VOICE_STT_POLISH_LOG: "0" };
          const boundary = shouldBuildBoundaryContext(result.text, env)
            ? await buildBoundaryContext(audio, result.segments, result.segmentsAudioSha256, env, signal) : undefined;
          const finalized = await finalizeTranscriptionResultForSurface(result.text, "dictation", env, boundary, signal);
          signal.throwIfAborted();
          updateArchivedTranscript(audio, finalized.text, { backend: result.backend, languageMode: getLanguageModeFromEnv(),
            transcribedDurationMs: durationMs, polishStatus: finalized.polishStatus, requireMetadataUpdate: true });
          return format === "text" ? new Response(finalized.text, { headers: { "Content-Type": "text/plain; charset=utf-8" } }) : Response.json({ text: finalized.text });
        });
      } catch (error) {
        if (signal.aborted) {
          reason = signal.reason?.name === "TimeoutError" ? "timeout" : "aborted";
          if (error instanceof Error && "cleanupFailure" in error) { reason = "cleanup-unconfirmed"; markRecognizerCleanupUnconfirmed("parakeet"); }
          if (!decoded && whisperInference && whisperServerLaunchRecord()) {
            try { if ((await unloadOwnedServer(() => false)).outcome === "reject") markRecognizerCleanupUnconfirmed("whisper"); }
            catch { markRecognizerCleanupUnconfirmed("whisper"); }
          }
        }
        try { if (audio) updateArchivedRecordingMetadata(audio, m => { m.not_transcribed_reason = `api-${reason}`; }, true); }
        catch { console.error("[voicelayer] Upload failure receipt unavailable; retained audio must be recovered"); }
        return error instanceof UpdateBusyError ? failure(409, "VoiceLayer is busy updating; retry when idle")
          : failure(503, !audio ? "Could not archive upload; no transcription started" : reason === "unavailable"
            ? "Selected recognizer assets unavailable, downloading, or cleanup unconfirmed; recording retained" : `Transcription ${reason}; recording retained`);
      } finally { reservation.release(); }
    },
  });
}
export function startTranscriptionsHttpIfEnabled(options?: Parameters<typeof startTranscriptionsHttp>[0]) {
  if (processingEnv().VOICELAYER_TRANSCRIPTIONS_ENABLED !== "1") return null;
  try { return startTranscriptionsHttp(options); }
  catch { console.error("[voicelayer] Transcriptions HTTP startup refused; dictation remains available"); return null; }
}
