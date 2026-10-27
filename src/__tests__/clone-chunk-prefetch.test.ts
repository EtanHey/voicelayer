import { describe, expect, it } from "bun:test";
import { projectSpeakableText } from "../speakable-text";
import { chunkTextForLongRead } from "../tts";
import { runLongRead } from "../tts/long-read";
import { planProsody } from "../tts/prosody";
import { createProsodyRead, PROSODY_SAMPLE_RATE, type ProsodyReadEngine } from "../tts/prosody-read";

class Clock {
  now = 0;
  timers: { at: number; fire(): void }[] = [];
  sleep(ms: number) { return new Promise<void>(fire => this.timers.push({ at: this.now + ms, fire })); }
  async flush() { for (let i = 0; i < 200; i++) await Promise.resolve(); }
  async until<T>(promise: Promise<T>): Promise<T> {
    let settled = false;
    void promise.then(() => { settled = true; }, () => { settled = true; });
    for (;;) {
      await this.flush();
      if (settled) return promise;
      this.timers.sort((a, b) => a.at - b.at);
      const timer = this.timers.shift();
      if (!timer) throw new Error("No scheduled work");
      this.now = timer.at; timer.fire();
    }
  }
}

const prose = "A short opening has enough words to read. " + "The next sentence explains the implementation and its verification with enough detail to require another chunk. ".repeat(8);
const structured = "## Status\n\n1. Keep the service running while the backup is verified.\n2. Open the review page and copy the results into the report.\n3. Check the changes and save the complete verification record.";
const gapFree = "The first sentence has enough words to cover the following request without a playback stop. " + "The next sentence is short enough to finish before the audio ends.";
const letters = (text: string) => text.replace(/[^\p{L}\p{N}]/gu, "").toLowerCase();

describe("S2 F3 clone startup and sequential prefetch", () => {
  it("does not buffer an entire list of tiny clone utterances before first audio", () => {
    const text = "## A\n" + "- Go\n".repeat(100);
    const plan = planProsody({ readText: text, projection: projectSpeakableText(text, [], "clone"), engine: "clone", listNumbers: "inline" });
    expect(plan.chunks[0].end).toBe(1);
    expect(plan.chunks.slice(1).every(chunk => chunk.end - chunk.first === 1)).toBe(true);
  });
  for (const speed of [1, 1.25])
  for (const msPerChar of [30, 48])
  for (const text of ["A short read with no need for another request.", prose, gapFree,
    "A short opening has enough words to read. " + "word ".repeat(160),
    "A short opening has enough words to read. " + "word  ".repeat(100),
    "A short opening has enough words to read. " + "The  next\t sentence keeps all of its words and spacing. ".repeat(8)])
  it(`plain clone meets first-audio and gap budgets (${text.length} chars, ${msPerChar}ms/char, ${speed}x)`, async () => {
    const clock = new Clock();
    const texts = chunkTextForLongRead(text, "clone", speed);
    const starts: number[] = [], ends: number[] = [], requests: [number, number][] = [];
    await clock.until(runLongRead(texts, "plain-clone", new AbortController().signal, {
      synthesize: async (text, index) => {
        const start = clock.now; await clock.sleep(text.length * msPerChar);
        requests.push([start, clock.now]);
        return { audioFile: String(index), durationMs: text.length * 65 / speed, wordBoundaries: [] };
      },
      play: chunk => {
        starts.push(clock.now);
        return { started: Promise.resolve(true), exited: clock.sleep(chunk.durationMs).then(() => {
          ends.push(clock.now); return { status: "completed" as const, stopped_at_ms: chunk.durationMs };
        }) };
      },
      saveHistory: async (audio, info) => {
        expect(letters(info.text)).toBe(letters(text)); expect(audio).toHaveLength(texts.length);
      },
      dispose() {},
    }, 2));
    expect(letters(texts.join(" "))).toBe(letters(text));
    expect(texts.flatMap(text => text.split(/\s+/))).toEqual(chunkTextForLongRead(text).flatMap(text => text.split(/\s+/)));
    expect(starts[0]).toBeLessThanOrEqual(chunkTextForLongRead(text)[0].length * msPerChar * 1.1);
    expect(Math.max(0, ...starts.slice(1).map((start, i) => start - ends[i]))).toBeLessThanOrEqual(300);
    if (requests.length > 1) expect(requests[1][0]).toBe(requests[0][1]);
    expect(requests.slice(1).every(([start], i) => start >= requests[i][1])).toBe(true);
    if (text === gapFree) expect(texts).toEqual(chunkTextForLongRead(text));
    console.info(JSON.stringify({ kind: "plain", speed, chars: text.length, msPerChar, firstAudioMs: starts[0],
      mainFirstAudioMs: chunkTextForLongRead(text)[0].length * msPerChar, maxGapMs: Math.max(0, ...starts.slice(1).map((start, i) => start - ends[i])) }));
  });

  for (const speed of [1, 1.25])
  for (const msPerChar of [30, 48])
  for (const text of [structured, "## A\n- One\n- Two\n- Three", "## A\n" + "word ".repeat(100) + "done."])
  it(`structured clone meets first-audio and gap budgets (${text.length} chars, ${msPerChar}ms/char, ${speed}x)`, async () => {
    const clock = new Clock(), controller = new AbortController();
    const plan = planProsody({ readText: text, projection: projectSpeakableText(text, [], "clone"),
      engine: "clone", listNumbers: "inline", concurrency: 1, ...{ playbackSpeed: speed } });
    const files = new Map<string, Float32Array>(), requests: [number, number][] = [];
    let serial = 0, active = 0, peak = 0, calls = 0, playing = 0;
    const engine: ProsodyReadEngine = {
      async synthesize(segment, signal) {
        expect(calls++).toBeLessThanOrEqual(playing + 2);
        active++; peak = Math.max(peak, active); const start = clock.now;
        await clock.sleep(segment.text.length * msPerChar); active--; signal.throwIfAborted(); requests.push([start, clock.now]);
        const audioFile = `segment-${serial++}`;
        const pcm = new Float32Array(Math.round(segment.text.length * 65 / speed * 24));
        for (let i = 0; i < pcm.length; i++) pcm[i] = 0.3 * Math.sin(2 * Math.PI * i / 48);
        files.set(audioFile, pcm);
        return { audioFile, durationMs: pcm.length / 24, words: [{ text: segment.text, offset_ms: 0, duration_ms: pcm.length / 24 }] };
      },
      async decode(file) { await clock.sleep(50); const pcm = files.get(file); if (!pcm) throw new Error("Missing audio"); return pcm; },
      async encode(pcm) { const file = `chunk-${serial++}`; files.set(file, pcm); return file; },
      unlink(file) { files.delete(file); },
    };
    const read = createProsodyRead(plan, engine, controller.signal, 1, { overlapDecode: true, playbackLookahead: 2 });
    const starts: number[] = [], ends: number[] = [];
    try {
      await clock.until(runLongRead(plan.chunks.map(chunk => chunk.text), "structured-clone", controller.signal, {
        synthesize: async (_text, index) => {
          const chunk = await read.chunk(index);
          return { ...chunk, wordBoundaries: chunk.words };
        },
        play: (chunk, _text, info) => {
          starts.push(clock.now); playing = info.chunk_index;
          read.chunkAdmitted(info.chunk_index);
          if (info.chunk_index === 0) read.firstAudioStarted(chunk.audioFile);
          const pcm = files.get(chunk.audioFile)!;
          expect(chunk.durationMs).toBe(pcm.length * 1000 / PROSODY_SAMPLE_RATE);
          if (info.chunk_index === 0 && plan.chunks[0].end > 1) {
            const speechMs = plan.segments.slice(0, plan.chunks[0].end).reduce((ms, segment) => ms + segment.text.length * 65, 0);
            expect(chunk.durationMs - speechMs).toBeGreaterThanOrEqual(plan.segments[0].pauseMs - 1);
          }
          return { started: Promise.resolve(true), exited: clock.sleep(chunk.durationMs).then(() => {
            ends.push(clock.now); return { status: "completed" as const, stopped_at_ms: chunk.durationMs };
          }) };
        },
        saveHistory: async (audio, info) => {
          expect(letters(info.text)).toBe(letters(text)); expect(audio).toHaveLength(plan.chunks.length);
        },
        dispose(chunk) { engine.unlink(chunk.audioFile); },
      }, 2));
      const baseline = planProsody({ readText: text, projection: projectSpeakableText(text, [], "clone"), listNumbers: "inline" });
      expect(starts[0]).toBeLessThanOrEqual(baseline.segments[0].text.length * msPerChar * 1.1);
      expect(plan.chunks[0].end).toBe(1);
      expect(requests[0][1]).toBe(starts[0]);
      expect(starts.length).toBeGreaterThan(1);
      expect(Math.max(...starts.slice(1).map((start, i) => start - ends[i]))).toBeLessThanOrEqual(300);
      expect(peak).toBe(1);
      expect(requests[1][0]).toBe(requests[0][1]);
      expect(requests.slice(1, 3).every(([start], i) => start === requests[i][1])).toBe(true);
      expect(requests.slice(1).every(([start], i) => start >= requests[i][1])).toBe(true);
      console.info(JSON.stringify({ kind: "structured", speed, chars: text.length, msPerChar, firstAudioMs: starts[0],
        mainFirstAudioMs: baseline.segments[0].text.length * msPerChar, maxGapMs: Math.max(0, ...starts.slice(1).map((start, i) => start - ends[i])) }));
    } finally { controller.abort(); await clock.until(read.close()); }
    expect(files.size).toBe(0);
  });
});
