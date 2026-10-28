import { throwIfAbortedSafe } from "../abort";
import type { SpeakableText } from "../speakable-text";
import type { ProjectionRange, TextRange } from "./structured-speech";
import { resolveBinaryAsync } from "../resolve-binary";
import type { WordBoundary } from "../socket-protocol";
import { mapper, PROSODY_POLICY, type ProsodyPlan, type ProsodySegment } from "./prosody";
import { measurePCMExtent, splicePCM } from "./prosody-pcm";
import { createSegmentScheduler } from "./prosody-schedule";

/** Every engine result is decoded to mono float PCM at this one rate before splicing. */
export const PROSODY_SAMPLE_RATE = 24000;

export interface ProsodyReadEngine {
  /** One utterance as the engine writes it (MP3), with words relative to that file. */
  synthesize(segment: ProsodySegment, signal: AbortSignal): Promise<{ audioFile: string; words: WordBoundary[]; durationMs: number }>;
  decode(audioFile: string, signal: AbortSignal): Promise<Float32Array>;
  /** Writes an MP3 (the archive and history container) and returns its path. */
  encode(pcm: Float32Array, signal: AbortSignal): Promise<string>;
  unlink(audioFile: string): void;
}
export interface ProsodyReadChunk { audioFile: string; durationMs: number; words: WordBoundary[]; spokenText: string }

/** Prosody engages only for structure; plain prose (any length) keeps the existing chunker byte-for-byte. */
export function isStructuredPlan(plan: ProsodyPlan): boolean {
  return plan.segments.some((s) => s.kind !== "prose" || s.pauseMs > PROSODY_POLICY.pauses.sentence);
}

/** The whole read's projection restricted to one chunk (trimmed read span), in chunk-local offsets.
 * Alignment uses this instead of re-projecting the chunk text, which can speak it differently. */
export function sliceProjection(projection: SpeakableText, read: TextRange): SpeakableText {
  const raw = projection.displayText.slice(read.start, read.end);
  const start = read.start + raw.length - raw.trimStart().length, end = Math.max(start, read.end - (raw.length - raw.trimEnd().length));
  const displayText = projection.displayText.slice(start, end);
  // An atomic range belongs to the chunk the planner gave its speech to: the same offset mapping that cut
  // the synthesized segments. A chunk whose (untrimmed) start falls inside one owns it whole.
  const speechAt = mapper(projection.ranges);
  const ownStart = speechAt(read.start), ownEnd = read.end >= projection.displayText.length ? projection.speechText.length : speechAt(read.end);
  const ranges: ProjectionRange[] = [];
  let speechText = "";
  for (const range of projection.ranges) {
    const { source } = range;
    let text: string;
    if (source.start === source.end) {
      if (!(source.start > start && source.start <= end)) continue;
      text = projection.speechText.slice(range.speech.start, range.speech.end);
    } else {
      const from = Math.max(source.start, start), to = Math.min(source.end, end);
      if (to <= from) continue;
      text = range.kind === "identity"
        ? projection.speechText.slice(range.speech.start + from - source.start, range.speech.start + to - source.start)
        : ownStart <= range.speech.start && range.speech.start < ownEnd ? projection.speechText.slice(range.speech.start, range.speech.end) : "";
    }
    const local = { start: Math.max(source.start, start) - start, end: Math.min(source.end, end) - start };
    if (source.start === source.end) local.end = local.start;
    const speech = { start: speechText.length, end: speechText.length + text.length };
    speechText += text;
    ranges.push({ source: local, display: { ...local }, speech,
      kind: local.start === local.end ? "insertion" : !text ? "omission" : displayText.slice(local.start, local.end) === text ? "identity" : "replacement" });
  }
  return { displayText, speechText, ranges };
}

type Synthesized =
  | { raw: true; audioFile: string; words: WordBoundary[]; durationMs: number }
  | { raw: false; pcm: Float32Array; words: WordBoundary[] };

export function createProsodyRead(plan: ProsodyPlan, engine: ProsodyReadEngine, signal: AbortSignal, concurrency?: number,
  { prepared, lookahead, overlapDecode = false, playbackLookahead }: {
    prepared?: ProsodyReadChunk; lookahead?: number; overlapDecode?: boolean; playbackLookahead?: number;
  } = {}) {
  const firstEnd = plan.chunks[0]?.end ?? 0;
  let admittedChunk = 0;
  const decodeFailure = new AbortController();
  const decoding = new Set<Promise<Synthesized>>();
  const schedulerPlan = prepared ? { segments: plan.segments.slice(firstEnd), chunks: plan.chunks.slice(1).map(chunk =>
    ({ ...chunk, first: chunk.first - firstEnd, end: chunk.end - firstEnd })) } : plan;
  const scheduler = createSegmentScheduler<{ ready: Promise<Synthesized>; rawFile?: string }>(schedulerPlan, async (segment, index, signal) => {
    const result = await engine.synthesize(segment, signal);
    if (!prepared && index === 0 && firstEnd === 1)
      return { ready: Promise.resolve({ raw: true, ...result }), rawFile: result.audioFile };
    const ready = (async (): Promise<Synthesized> => {
      try { return { raw: false, pcm: await engine.decode(result.audioFile, signal), words: result.words }; }
      finally { engine.unlink(result.audioFile); }
    })();
    decoding.add(ready);
    void ready.then(() => decoding.delete(ready), error => { decoding.delete(ready); decodeFailure.abort(error); });
    if (!overlapDecode) await ready;
    return { ready };
  }, { signal: AbortSignal.any([signal, decodeFailure.signal]), concurrency, lookahead,
    canStart: playbackLookahead === undefined ? undefined : index => index < (schedulerPlan.chunks[
      Math.min(admittedChunk + playbackLookahead - (prepared ? 1 : 0), schedulerPlan.chunks.length - 1)]?.end ?? 0),
    dispose: (result) => { if (result.rawFile) engine.unlink(result.rawFile); } });
  let preparedDelivered = false;
  let previousTailMs: Promise<number> = Promise.resolve(0);
  // Chunk 0's tail: decoded only after its player started; resolves 0 if it never starts or on abort.
  const tailAbort = new AbortController();
  let resolveTail!: (ms: number) => void;
  const tail = new Promise<number>((resolve) => { resolveTail = resolve; });
  let firstRaw: { audioFile: string; words: WordBoundary[] } | undefined, tailClaimed = false;
  let tailTask: Promise<void> | undefined;
  const cancelTail = () => { tailAbort.abort(); resolveTail(0); };
  if (signal.aborted) cancelTail(); else signal.addEventListener("abort", cancelTail, { once: true });
  const settleTail = async () => {
    tailClaimed = true; cancelTail();
    await tailTask;
  };
  const spoken = (index: number) => plan.segments.slice(plan.chunks[index].first, plan.chunks[index].end).map((s) => s.text).join(" ");

  return {
    chunkAdmitted(index: number) { admittedChunk = Math.max(admittedChunk, index); scheduler.resume(); },
    async chunk(index: number): Promise<ProsodyReadChunk> {
      if (prepared && index === 0) {
        throwIfAbortedSafe(signal);
        if (preparedDelivered) throw new Error("Prosody chunk already delivered");
        preparedDelivered = true; firstRaw = prepared; previousTailMs = tail;
        return prepared;
      }
      const pending = await scheduler.chunk(prepared ? index - 1 : index);
      const parts = await Promise.all(pending.map(part => part.ready));
      const [first] = parts;
      if (index === 0 && parts.length === 1 && first.raw) {
        firstRaw = first;
        previousTailMs = tail;
        return { audioFile: first.audioFile, durationMs: first.durationMs, words: first.words, spokenText: spoken(0) };
      }
      const tailMs = await previousTailMs;
      throwIfAbortedSafe(signal);
      const segments = plan.segments.slice(plan.chunks[index].first, plan.chunks[index].end);
      const spliced = splicePCM(parts.map((part, i) => {
        if (part.raw) throw new Error("Only chunk 0 plays an engine file directly");
        return { pcm: part.pcm, words: part.words, pauseMs: segments[i].pauseMs };
      }), PROSODY_SAMPLE_RATE, index > 0 ? { leadingPauseMs: plan.chunks[index - 1].trailingPauseMs, previousTailMs: tailMs } : {});
      const audioFile = await engine.encode(spliced.pcm, signal);
      previousTailMs = Promise.resolve(measurePCMExtent(spliced.pcm, PROSODY_SAMPLE_RATE).tailMs);
      return { audioFile, durationMs: spliced.durationMs, words: spliced.words, spokenText: spoken(index) };
    },
    /** Chunk 0's player actually started: measure its tail now, never before first audio. */
    firstAudioStarted(audioFile: string) {
      if (tailClaimed || firstRaw?.audioFile !== audioFile) return;
      tailClaimed = true;
      const raw = firstRaw;
      tailTask = engine.decode(raw.audioFile, tailAbort.signal)
        .then((pcm) => resolveTail(measurePCMExtent(pcm, PROSODY_SAMPLE_RATE, raw.words).tailMs), () => resolveTail(0));
    },
    /** Chunk 0 will not play (player failed or never started): later chunks pad from a zero tail. */
    firstAudioUnavailable() {
      if (tailClaimed) return;
      tailClaimed = true; resolveTail(0);
    },
    /** Cancels and awaits chunk 0's tail decode; call before disposing chunk 0's file. */
    settleTail,
    /** Waits for every started request and the tail decode; removes files that were never delivered. */
    async close() {
      signal.removeEventListener("abort", cancelTail);
      await settleTail();
      await scheduler.close();
      await Promise.allSettled([...decoding]);
      if (prepared && !preparedDelivered) { preparedDelivered = true; engine.unlink(prepared.audioFile); }
    },
  };
}

async function ffmpegChild(args: string[], signal: AbortSignal, stdin?: Float32Array) {
  throwIfAbortedSafe(signal);
  const ffmpeg = await resolveBinaryAsync("ffmpeg");
  if (!ffmpeg) throw new Error("ffmpeg unavailable for speech prosody");
  throwIfAbortedSafe(signal);
  const proc = Bun.spawn([ffmpeg, ...args], { env: process.env, stdin: stdin ? "pipe" : "ignore", stdout: "pipe", stderr: "ignore" });
  let killed = false;
  const kill = () => { if (killed) return; killed = true; try { proc.kill("SIGKILL"); } catch {} };
  const timeout = setTimeout(kill, 30_000);
  signal.addEventListener("abort", kill, { once: true });
  try {
    if (stdin && proc.stdin && typeof proc.stdin !== "number") {
      proc.stdin.write(new Uint8Array(stdin.buffer, stdin.byteOffset, stdin.byteLength));
      await proc.stdin.end();
    }
    const [output, code] = await Promise.all([new Response(proc.stdout as ReadableStream).arrayBuffer(), proc.exited]);
    throwIfAbortedSafe(signal);
    if (code !== 0) throw new Error(`Speech prosody audio conversion failed (${code})`);
    return output;
  } catch (error) {
    // Any failure after spawn (stdin EPIPE, stdout error, abort): the owned child dies and is reaped
    // before the caller cleans up, and the original error is what the caller sees.
    kill();
    await proc.exited.catch(() => {});
    throw error;
  } finally {
    clearTimeout(timeout);
    signal.removeEventListener("abort", kill);
  }
}

/** Any engine container → mono float PCM at PROSODY_SAMPLE_RATE (downmixed and resampled). */
export async function decodeAudioToPCM(audioFile: string, signal: AbortSignal): Promise<Float32Array> {
  const output = await ffmpegChild(["-nostdin", "-v", "error", "-i", audioFile, "-f", "f32le", "-ac", "1", "-ar", String(PROSODY_SAMPLE_RATE), "pipe:1"], signal);
  return new Float32Array(output.slice(0, output.byteLength - output.byteLength % 4));
}

/** Spliced PCM → MP3 at `audioFile`; never a WAV under an .mp3 name. */
export async function encodePCMToMp3(pcm: Float32Array, audioFile: string, signal: AbortSignal): Promise<void> {
  await ffmpegChild(["-y", "-v", "error", "-f", "f32le", "-ar", String(PROSODY_SAMPLE_RATE), "-ac", "1", "-i", "pipe:0",
    "-codec:a", "libmp3lame", "-q:a", "2", "-f", "mp3", audioFile], signal, pcm);
}
