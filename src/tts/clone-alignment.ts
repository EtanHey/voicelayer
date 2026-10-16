import { createHash } from "node:crypto";
import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import type { ProjectionRange, TextRange } from "./structured-speech";

export interface CloneAlignmentRequest {
  audioPath: string;
  /** Duration of this exact file before any player speed adjustment. */
  durationMs: number;
  displayText: string;
  speechText: string;
  ranges: readonly ProjectionRange[];
  language: string;
  requestId: string;
  chunkId: string;
  /** Player speed relative to this file. Already rate-adjusted files use 1. */
  playbackRate: number;
  signal?: AbortSignal;
  /** Background integration yields CPU scheduling to dictation. */
  lowPriority?: boolean;
  /** Synchronous admission immediately before EACH native child; false yields. */
  canSpawn?: () => boolean;
  /** Existing whisper.cpp, large-v3-turbo and ffmpeg; no download or daemon. */
  decoder: { binary: string; model: string; ffmpeg: string };
}
export interface CloneAlignmentResult {
  status: "timed" | "partial" | "untimed";
  reason?: "invalid" | "unavailable" | "cancelled" | "deadline" | "unmatched";
  identity: { requestId: string; chunkId: string; audioSha256: string | null; playbackRate: number };
  words: { text: string; displayRange: TextRange; offset_ms: number | null; duration_ms: number | null }[];
}
interface MeasuredWord { text: string; start: number; end: number; valid: boolean }
const lexical = (text: string) => Array.from(text.matchAll(/[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*/gu));
const canonical = (text: string) => text.normalize("NFC").toLowerCase().replace(/’/g, "'");
const overlap = (a: TextRange, b: TextRange) => a.start < b.end && b.start < a.end;

/** Exact matches must occur in EVERY minimum-edit alignment. An arbitrary
 * traceback would attach an omitted repeated word to the wrong occurrence. */
function matchWords(expected: string[], heard: MeasuredWord[]): (number | null)[] {
  const n = expected.length, m = heard.length, forward = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  const backward = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  const same = (i: number, j: number) => canonical(expected[i]) === canonical(heard[j].text);
  for (let i = 0; i <= n; i++) forward[i][0] = i;
  for (let j = 0; j <= m; j++) forward[0][j] = j;
  for (let i = 1; i <= n; i++) for (let j = 1; j <= m; j++)
    forward[i][j] = Math.min(forward[i - 1][j] + 1, forward[i][j - 1] + 1, forward[i - 1][j - 1] + Number(!same(i - 1, j - 1)));
  for (let i = n; i >= 0; i--) backward[i][m] = n - i;
  for (let j = m; j >= 0; j--) backward[n][j] = m - j;
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
    backward[i][j] = Math.min(backward[i + 1][j] + 1, backward[i][j + 1] + 1, backward[i + 1][j + 1] + Number(!same(i, j)));
  const best = forward[n][m];
  return expected.map((_, i) => {
    const candidates = new Set<number>(); let unmatched = false;
    for (let j = 0; j <= m; j++) {
      if (forward[i][j] + 1 + backward[i + 1][j] === best) unmatched = true;
      if (j === m) continue;
      if (same(i, j) && forward[i][j] + backward[i + 1][j + 1] === best) candidates.add(j);
      if (!same(i, j) && forward[i][j] + 1 + backward[i + 1][j + 1] === best) unmatched = true;
    }
    return !unmatched && candidates.size === 1 ? [...candidates][0] : null;
  });
}

const DTW_ANCHOR_TOLERANCE_MS = 30; // Frozen Edge comparison; never extends a returned span.
/** whisper.cpp's offsets are estimates and can interpolate silence. DTW supplies
 * a separate acoustic token anchor, NOT a word onset. Never turn that anchor into
 * a fabricated onset/end: keep the original span when its anchor agrees within
 * the bounded tolerance. This is corroboration, not acoustic correctness proof. */
function measuredWords(payload: any, duration: number): MeasuredWord[] {
  if (!Array.isArray(payload?.transcription)) return [];
  const spans: (MeasuredWord & { range: TextRange })[] = []; let previousEnd = 0, text = "";
  for (const segment of payload.transcription) {
    if (!Array.isArray(segment?.tokens)) return [];
    for (const token of segment.tokens) {
      if (typeof token?.text !== "string") return [];
      if (token.text.startsWith("[_")) continue;
      // Reconstruct the literal surface BEFORE lexing: stripping an apostrophe
      // from "'re", or ignoring a standalone quote/space, changes word identity.
      const range = { start: text.length, end: text.length + token.text.length }; text += token.text;
      const pieces = lexical(token.text), start = token.offsets?.from, end = token.offsets?.to, anchor = token.t_dtw * 10;
      if (!pieces.length) continue; // Punctuation has lexical effect, but no acoustic target of its own.
      if (pieces.length !== 1 || !Number.isFinite(start) || !Number.isFinite(end) || start < previousEnd || end < start || end > duration) return [];
      const valid = end > start && Number.isFinite(token.t_dtw) && anchor >= 0 && anchor <= duration &&
        anchor >= start - DTW_ANCHOR_TOLERANCE_MS && anchor <= end + DTW_ANCHOR_TOLERANCE_MS && Number.isFinite(token.p) && token.p >= .9 && token.p <= 1;
      spans.push({ text: token.text, range, start, end, valid });
      previousEnd = end;
    }
  }
  return lexical(text).map(word => {
    const parts = spans.filter(span => overlap(span.range, { start: word.index, end: word.index + word[0].length }));
    return { text: word[0], start: parts[0].start, end: parts.at(-1)!.end, valid: parts.every(part => part.valid) };
  });
}

function validProjection(input: CloneAlignmentRequest): boolean {
  let display = 0, speech = 0;
  for (const range of input.ranges) {
    const d = range.display, s = range.speech;
    if (![d.start, d.end, s.start, s.end].every(Number.isInteger) || d.start !== display || s.start !== speech || d.end < display || s.end < speech) return false;
    if (range.kind === "identity" && input.displayText.slice(d.start, d.end) !== input.speechText.slice(s.start, s.end)) return false;
    if (range.kind === "omission" && s.start !== s.end || range.kind === "insertion" && d.start !== d.end) return false;
    if (!["identity", "replacement", "insertion", "omission"].includes(range.kind)) return false;
    display = d.end; speech = s.end;
  }
  return display === input.displayText.length && speech === input.speechText.length;
}

/** Leaf adapter only: no playback, live daemon, microphone, or runtime wiring.
 * A private audio snapshot binds decoding and its SHA to the same request/chunk.
 * The native child is always killed/reaped before cancellation/deadline returns. */
export async function alignCloneAudio(request: CloneAlignmentRequest): Promise<CloneAlignmentResult> {
  const startedAt = performance.now();
  const input = { ...request, decoder: { ...request.decoder }, ranges: structuredClone(request.ranges) };
  const result: CloneAlignmentResult = {
    status: "untimed", identity: { requestId: input.requestId, chunkId: input.chunkId, audioSha256: null, playbackRate: input.playbackRate },
    words: Array.from(input.displayText.matchAll(/\S+/gu), word => ({ text: word[0], displayRange: { start: word.index, end: word.index + word[0].length }, offset_ms: null, duration_ms: null })),
  };
  const untimed = (reason: CloneAlignmentResult["reason"]) => {
    result.status = "untimed"; result.reason = reason;
    for (const word of result.words) { word.offset_ms = null; word.duration_ms = null; }
    return result;
  };
  const expected = lexical(input.speechText);
  if (!Number.isFinite(input.durationMs) || input.durationMs <= 0 || !Number.isFinite(input.playbackRate) || input.playbackRate <= 0 ||
    !input.requestId || !input.chunkId || !/^[a-z]{2,3}$/.test(input.language) || expected.length > 256 || input.ranges.length > 2048 || !validProjection(input)) return untimed("invalid");
  if (input.signal?.aborted) return untimed("cancelled");
  const controller = new AbortController(); let deadline = false, directory: string | undefined;
  const expiresAt = startedAt + input.durationMs / input.playbackRate * .5;
  const expired = () => { if (performance.now() >= expiresAt) { deadline = true; controller.abort(); } return controller.signal.aborted; };
  let child: ReturnType<typeof Bun.spawn> | undefined, stopFailed = false;
  const abort = () => controller.abort(), stop = () => {
    try { if (child?.exitCode === null) child.kill("SIGKILL"); } catch { stopFailed = true; }
  };
  input.signal?.addEventListener("abort", abort, { once: true });
  controller.signal.addEventListener("abort", stop);
  const timer = setTimeout(() => { deadline = true; controller.abort(); }, Math.max(0, expiresAt - performance.now()));
  try {
    const audio = await readFile(input.audioPath, { signal: controller.signal });
    if (audio.length > 16 * 1024 * 1024) return untimed("invalid");
    result.identity.audioSha256 = createHash("sha256").update(audio).digest("hex");
    await Promise.all([access(input.decoder.binary), access(input.decoder.model), access(input.decoder.ffmpeg)]);
    directory = await mkdtemp(join(tmpdir(), "vl-cln1a-"));
    const file = join(directory, "audio" + extname(input.audioPath)), output = join(directory, "alignment");
    await writeFile(file, audio, { signal: controller.signal });
    if (expired()) return untimed(deadline ? "deadline" : "cancelled");
    // Pin decoding to the benchmark's PCM path: whisper.cpp's direct MP3
    // reader produced different, less accurate spans for the same fixture.
    const wav = join(directory, "decoded.wav");
    const priority = input.lowPriority ? ["/usr/bin/nice", "-n", "19"] : [];
    if (input.canSpawn?.() === false || expired()) return untimed(deadline ? "deadline" : "cancelled");
    child = Bun.spawn([...priority, input.decoder.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", file,
      "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
    const prepared = await child.exited;
    if (expired()) return untimed(deadline ? "deadline" : "cancelled");
    if (prepared !== 0) return untimed("unavailable");
    if (input.canSpawn?.() === false || expired()) return untimed(deadline ? "deadline" : "cancelled");
    child = Bun.spawn([...priority, input.decoder.binary, "-m", input.decoder.model, "-f", wav, "-l", input.language,
      "-dtw", "large.v3.turbo", "-nfa", "-ojf", "-of", output], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
    const code = await child.exited;
    if (expired()) return untimed(deadline ? "deadline" : "cancelled");
    if (code !== 0) return untimed("unavailable");
    const heard = measuredWords(JSON.parse(await readFile(output + ".json", "utf8")), input.durationMs);
    if (heard.length > 256) return untimed("invalid");
    const matches = matchWords(expected.map(word => word[0]), heard);
    for (const display of result.words) {
      const relevant = new Set<number>(); let ambiguous = false;
      for (const range of input.ranges) {
        if (!overlap(display.displayRange, range.display) || range.kind === "omission") continue;
        if (range.kind === "replacement" && result.words.filter(word => overlap(word.displayRange, range.display)).length !== 1) ambiguous = true;
        for (let i = 0; i < expected.length; i++) {
          const word = { start: expected[i].index, end: expected[i].index + expected[i][0].length };
          const target = range.kind === "identity" ? {
            start: range.speech.start + Math.max(display.displayRange.start, range.display.start) - range.display.start,
            end: range.speech.start + Math.min(display.displayRange.end, range.display.end) - range.display.start,
          } : range.speech;
          if (overlap(word, target)) relevant.add(i);
        }
      }
      const measured = [...relevant].map(i => matches[i] === null ? undefined : heard[matches[i]!]);
      if (ambiguous || !measured.length || measured.some(word => !word?.valid)) continue;
      const start = Math.min(...measured.map(word => word!.start)), end = Math.max(...measured.map(word => word!.end));
      display.offset_ms = start / input.playbackRate; display.duration_ms = (end - start) / input.playbackRate;
    }
    if (expired()) return untimed(deadline ? "deadline" : "cancelled");
    const count = result.words.filter(word => word.offset_ms !== null).length;
    result.status = !count ? "untimed" : count === result.words.length ? "timed" : "partial";
    if (!count) result.reason = "unmatched";
    return result;
  } catch {
    return untimed(controller.signal.aborted ? deadline ? "deadline" : "cancelled" : "unavailable");
  } finally {
    clearTimeout(timer); input.signal?.removeEventListener("abort", abort); controller.signal.removeEventListener("abort", stop);
    let cleanupFailed = stopFailed;
    // Every cleanup step still runs if killing or reaping the child fails.
    try { if (child?.exitCode === null) child.kill("SIGKILL"); } catch { cleanupFailed = true; }
    try { if (child) await child.exited; } catch { cleanupFailed = true; }
    try { if (directory) await rm(directory, { recursive: true, force: true }); } catch { cleanupFailed = true; }
    if (cleanupFailed) untimed(controller.signal.aborted ? deadline ? "deadline" : "cancelled" : "unavailable");
    // Include cleanup in the deadline, and reject cancellation during cleanup.
    if (input.signal?.aborted) untimed("cancelled");
    else if (performance.now() >= expiresAt) untimed("deadline");
  }
}
