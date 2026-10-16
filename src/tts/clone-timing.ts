import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { getEffectiveRecordingState, onRecordingStateChange } from "../recording-state";
import { resolveBinaryAsync } from "../resolve-binary";
import type { AlignedWordBoundary } from "../socket-protocol";
import { alignCloneAudio, type CloneAlignmentRequest } from "./clone-alignment";

let tail = Promise.resolve();
type TimingInput = Omit<CloneAlignmentRequest, "decoder" | "language" | "signal" | "lowPriority" | "playbackRate">;
/** Current-player work only. Replacements serialize behind cancellation/reaping,
 * while audio playback itself never awaits this queue. Files are already at rate. */
export function startCloneTiming(input: TimingInput, isCurrent: () => boolean, publish: (words: AlignedWordBoundary[]) => void) {
  const controller = new AbortController(), cancel = () => controller.abort();
  const unsubscribe = onRecordingStateChange(state => { if (state !== "idle") cancel(); });
  // Effective state also covers a separate CLI process's capture/transcription.
  const check = () => { if (!isCurrent() || getEffectiveRecordingState() !== "idle") cancel(); };
  const poll = setInterval(check, 10); poll.unref(); check();
  const current = () => { check(); return !controller.signal.aborted; };
  const done = tail.then(async () => {
    if (!current()) return;
    const [binary, ffmpeg] = await Promise.all([
      resolveBinaryAsync("whisper-cli").then(path => path ?? resolveBinaryAsync("whisper-cpp")),
      resolveBinaryAsync("ffmpeg"),
    ]);
    if (!binary || !ffmpeg || !current()) return;
    const result = await alignCloneAudio({ ...input, playbackRate: 1, lowPriority: true,
      language: /\p{Script=Hebrew}/u.test(input.speechText) ? "he" : "en", signal: controller.signal,
      decoder: { binary, ffmpeg, model: process.env.QA_VOICE_WHISPER_MODEL ?? join(homedir(), ".cache/whisper/ggml-large-v3-turbo.bin") } });
    if (!current() || result.status === "untimed" || result.identity.requestId !== input.requestId ||
        result.identity.chunkId !== input.chunkId || result.identity.playbackRate !== 1) return;
    const sha = createHash("sha256").update(await readFile(input.audioPath)).digest("hex");
    if (!current() || result.identity.audioSha256 !== sha) return;
    const display = Array.from(input.displayText.matchAll(/\S+/gu));
    if (display.length !== result.words.length || result.words.some((word, i) => word.text !== display[i][0] ||
        word.displayRange.start !== display[i].index || word.displayRange.end !== display[i].index + display[i][0].length)) return;
    const words = result.words.map((word, word_index) => {
      const { text, offset_ms: offset, duration_ms: duration } = word;
      const valid = offset !== null && duration !== null && Number.isFinite(offset) && Number.isFinite(duration) &&
        offset >= 0 && duration > 0 && offset + duration <= input.durationMs;
      return { word_index, text, offset_ms: valid ? offset : null, duration_ms: valid ? duration : null };
    });
    // Wire stays chunk-local; Swift adds chunk_start_ms exactly once.
    if (words.some(word => word.offset_ms !== null)) publish(words);
  }).catch(() => {}).finally(() => { clearInterval(poll); unsubscribe(); });
  tail = done;
  return { cancel, done };
}
