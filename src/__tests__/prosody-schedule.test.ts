import { describe, expect, it } from "bun:test";
import { projectSpeakableText } from "../speakable-text";
import { chunkTextForTTS } from "../tts";
import { planProsody, PROSODY_SYNTH_CONCURRENCY, type ProsodyPlan, type ProsodySegment } from "../tts/prosody";
import { createSegmentScheduler } from "../tts/prosody-schedule";
import { runLongRead, type LongReadChunk } from "../tts/long-read";

/** Deterministic virtual time: timers fire in order, and every microtask settles between them. */
class FakeClock {
  now = 0;
  private timers: { at: number; seq: number; fire: () => void }[] = [];
  private seq = 0;
  sleep(ms: number) { return new Promise<void>((fire) => this.timers.push({ at: this.now + ms, seq: this.seq++, fire })); }
  /** Settles pending promise continuations without the event loop: the code under test runs only on
   * promises and this clock, so microtask yields are complete, and no other file's timers, sockets or
   * replaced globals can delay them. */
  private async flush() { for (let i = 0; i < 200; i++) await Promise.resolve(); }
  async until<T>(promise: Promise<T>): Promise<T> {
    let done = false;
    promise.then(() => { done = true; }, () => { done = true; });
    for (;;) {
      await this.flush();
      if (done) return promise;
      this.timers.sort((a, b) => a.at - b.at || a.seq - b.seq);
      const next = this.timers.shift();
      if (!next) throw new Error("deadlock: nothing scheduled");
      this.now = next.at; next.fire();
    }
  }
}

describe("Macroscope #562: delivered results are not retained by the scheduler", () => {
  it("after a chunk is handed out and the caller drops it, its results can be collected", async () => {
    const clock = new FakeClock(), p = plan(Array.from({ length: 40 }, (_, i) => `## Part ${i}\n\nBody ${i} text.`).join("\n\n"));
    const refs = new Map<number, WeakRef<object>>();
    const scheduler = createSegmentScheduler(p, async (_s, index) => {
      await clock.sleep(10);
      const result = { index, pcm: new Float32Array(200_000) };
      refs.set(index, new WeakRef(result));
      return result;
    }, { signal: new AbortController().signal });
    // Deliver one chunk past the ones checked: the newest delivery may still sit on this test's own stack.
    for (const index of [0, 1, 2, 3]) { const result = await clock.until(scheduler.chunk(index)); expect(result.length).toBeGreaterThan(0); }
    const delivered = p.segments.map((_, i) => i).filter((i) => i < p.chunks[2].end);
    // WeakRef targets are only cleared after a real event-loop turn, not a microtask.
    await Bun.sleep(0);
    for (let i = 0; i < 3; i++) { Bun.gc(true); await Promise.resolve(); }
    expect(delivered.filter((i) => refs.get(i)?.deref() !== undefined)).toEqual([]);
    await clock.until(scheduler.close());
  });
});

describe("FakeClock is immune to the event loop and to replaced globals", () => {
  // Full-suite flake (2026-10-26): after socket-byte-framing.test.ts left a VoiceBar client's keepalive and
  // socket alive, Bun ran nested setImmediate callbacks only on real timer wakeups (~1 s apart), so a
  // setImmediate-based flush advanced virtual time once per real second and these tests hit 5 s timeouts.
  it("advances a scheduler scenario even when setImmediate never calls back", async () => {
    const realImmediate = globalThis.setImmediate;
    globalThis.setImmediate = (() => 0) as unknown as typeof setImmediate;
    try {
      const clock = new FakeClock(), p = plan("## Status\n\n- One\n- Two\n- Three\n- Four");
      const controller = new AbortController();
      const scheduler = createSegmentScheduler(p, async (_s, index, signal) => {
        await clock.sleep(50); if (signal.aborted) throw new Error("killed"); return index;
      }, { signal: controller.signal });
      const first = scheduler.chunk(0); first.catch(() => {});
      const finished = (async () => {
        await clock.until(Promise.resolve());
        controller.abort();
        await clock.until(first).catch(() => {});
        await clock.until(scheduler.settled());
        return "done";
      })();
      expect(await Promise.race([finished, Bun.sleep(1000).then(() => "stalled")])).toBe("done");
    } finally { globalThis.setImmediate = realImmediate; }
  });
});

const plan = (text: string, ask = false) => planProsody({ readText: text, projection: projectSpeakableText(text, [], "edge"), ask });

describe("createSegmentScheduler: bounded, ordered, abortable", () => {
  it("B4: a rejected chunk keeps ownership of its successful siblings, including a late one, and close() disposes them", async () => {
    const clock = new FakeClock(), p = plan("## Status\n\n- One\n- Two\n- Three\n- Four\n- Five");
    expect(p.chunks.map((c) => [c.first, c.end])).toEqual([[0, 1], [1, 4], [4, 6]]);
    const disposed: number[] = [];
    const scheduler = createSegmentScheduler(p, async (_s, index) => {
      await clock.sleep(index === 1 ? 2 : index === 3 ? 40 : 5);
      if (index === 1) throw new Error("engine down");
      return index;
    }, { signal: new AbortController().signal, dispose: (result) => disposed.push(result) });
    expect(await clock.until(scheduler.chunk(0))).toEqual([0]);
    await expect(clock.until(scheduler.chunk(1))).rejects.toThrow("engine down");
    await clock.until(scheduler.close());
    expect(disposed.sort()).toEqual([2]);
  });
  it("B4: a chunk that settles after close() is disposed, never delivered", async () => {
    const clock = new FakeClock(), p = plan("## Status\n\n- One\n- Two\n- Three");
    const disposed: number[] = [];
    const scheduler = createSegmentScheduler(p, async (_s, index) => { await clock.sleep(10 * (index + 1)); return index; },
      { signal: new AbortController().signal, dispose: (result) => disposed.push(result) });
    const late = scheduler.chunk(1);
    late.catch(() => {});
    await clock.until(scheduler.close());
    await expect(clock.until(late)).rejects.toThrow();
    // 0, 1 and 2 ran (concurrency 3) and were never handed out; 3 was queued and never started.
    expect(p.chunks.map((c) => [c.first, c.end])).toEqual([[0, 1], [1, 4]]);
    expect(disposed.sort()).toEqual([0, 1, 2]);
    expect(new Set(disposed).size).toBe(disposed.length);
  });
  const doc = "## Status\n\nThe build is green.\n\n- One\n- Two\n- Three\n- Four\n- Five\n\nDone.";
  it("never exceeds the concurrency limit and starts segments strictly in order", async () => {
    const clock = new FakeClock(), p = plan(doc);
    let running = 0, peak = 0;
    const started: number[] = [];
    const scheduler = createSegmentScheduler(p, async (segment, index) => {
      started.push(index); running++; peak = Math.max(peak, running);
      await clock.sleep(100 + 10 * segment.text.length); running--;
      return index;
    }, { signal: new AbortController().signal });
    for (let i = 0; i < p.chunks.length; i++) {
      expect(await clock.until(scheduler.chunk(i))).toEqual(Array.from({ length: p.chunks[i].end - p.chunks[i].first }, (_, k) => p.chunks[i].first + k));
    }
    expect(peak).toBe(PROSODY_SYNTH_CONCURRENCY);
    expect(started).toEqual(p.segments.map((_, i) => i));
  });
  it("requesting chunk 0 prefetches the following chunks", async () => {
    const clock = new FakeClock(), p = plan(doc);
    const started: number[] = [];
    const scheduler = createSegmentScheduler(p, async (_s, index) => { started.push(index); await clock.sleep(10); return index; },
      { signal: new AbortController().signal });
    await clock.until(scheduler.chunk(0));
    expect(started.length).toBeGreaterThan(p.chunks[0].end);
  });
  it("after abort nothing new starts, queued requests reject, and settled() waits for in-flight ones", async () => {
    const clock = new FakeClock(), p = plan(doc), controller = new AbortController();
    const started: number[] = [], finished: number[] = [];
    const scheduler = createSegmentScheduler(p, async (_s, index, signal) => {
      started.push(index); await clock.sleep(50); finished.push(index);
      if (signal.aborted) throw new Error("killed");
      return index;
    }, { signal: controller.signal });
    const first = scheduler.chunk(0), second = scheduler.chunk(1);
    first.catch(() => {}); second.catch(() => {});
    await clock.until(Promise.resolve());
    controller.abort();
    await expect(clock.until(first)).rejects.toThrow();
    await expect(clock.until(second)).rejects.toThrow();
    await clock.until(scheduler.settled());
    expect(started).toEqual([0, 1, 2]);
    expect(finished).toEqual([0, 1, 2]);
    await expect(scheduler.chunk(2)).rejects.toThrow();
    expect(started).toEqual([0, 1, 2]);
  });
  it("a failed request stops later starts and fails its chunk with the original error", async () => {
    const clock = new FakeClock(), p = plan(doc);
    const started: number[] = [];
    const scheduler = createSegmentScheduler(p, async (_s, index) => {
      started.push(index); await clock.sleep(index === 1 ? 5 : 50);
      if (index === 1) throw new Error("engine down");
      return index;
    }, { signal: new AbortController().signal });
    await clock.until(scheduler.chunk(0));
    await expect(clock.until(scheduler.chunk(1))).rejects.toThrow("engine down");
    await clock.until(scheduler.settled());
    expect(started).toEqual([0, 1, 2]);
  });
  it("close() disposes results that were never handed out, exactly once", async () => {
    const clock = new FakeClock(), p = plan(doc);
    const disposed: number[] = [];
    const scheduler = createSegmentScheduler(p, async (_s, index) => { await clock.sleep(10); return index; },
      { signal: new AbortController().signal, dispose: (result) => disposed.push(result) });
    const chunk0 = await clock.until(scheduler.chunk(0));
    await clock.until(scheduler.close());
    expect(disposed.length).toBeGreaterThan(0);
    expect(disposed.some((d) => chunk0.includes(d))).toBe(false);
    expect(new Set(disposed).size).toBe(disposed.length);
  });
});

/** Timing model (assumption, see receipt): edge ≈ 450 ms fixed + 5 ms/char; speech ≈ 65 ms/char.
 * Chunk 0 is a single utterance played as the engine wrote it (no decode before first audio).
 * Every later chunk decodes each segment (35 ms) and pays one splice + encode (40 ms). */
const SYNTH = (text: string) => 450 + 5 * text.length, DECODE = 35, ENCODE = 40, AUDIO = (text: string) => 65 * text.length;

const corpus: [string, string, boolean?][] = [
  ["review's typical Ask", "The build is green and every check passed. Should I merge PR 512 now?\n1. Merge now\n2. Wait for the proof", true],
  ["status with heading and list", "## Status\n\nThe build is green.\n\n- One\n- Two\n- Three\n- Four\n- Five\n\nNothing needed from you."],
  ["video 1", "Nothing needed from you.\n\n**Orchard route**\n\nAn orchard route follows three stops.\n\n1. Pick up the blue basket.\n2. Walk to the garden gate.\n3. Follow the path past the old apple tree to the low stone wall. Then cross the narrow wooden bridge over the stream and keep walking until you reach the orchard gate."],
  ["video 2", "I spent today on:\n- **Archive backend:** saving every spoken reply so history survives a restart.\n- **Your Option+F5 formatting bug:** preserving list and paragraph structure in the read-along.\n- **The cutoff control in your screenshot:** choosing when to switch between short and long voices. That was separate work.\n\nNothing needed from you right now."],
  ["plain short", "New long read."],
  ["plain long", Array.from({ length: 30 }, (_, i) => `Sentence ${i} has enough words to fill the next chunk.`).join(" ")],
  ["labels then long paragraph", "**Summary:** all green.\n\n" + Array.from({ length: 12 }, (_, i) => `Detail ${i} explains one more part of the change.`).join(" ")],
  ["Sol B2: short label, 399-char sentence", "**X:** " + "word ".repeat(79) + "end."],
  ["Sol B2: short heading, 399-char sentence", "## A\n" + "word ".repeat(79) + "end."],
  ["Sol R2-B1: oversized heading", "# " + "word ".repeat(100) + "end.\nBody."],
  ["Sol R2-B1: oversized label", "**" + "word ".repeat(100) + "end:** body."],
  ["heading then long sentences", "# A\n" + Array.from({ length: 12 }, (_, i) => `Sentence ${i} has a fair number of plain words inside it.`).join(" ")],
];

type Played = { index: number; startMs: number; endMs: number };
/** The real pure long-read coordinator, fake synthesis and player, virtual time. */
async function driveLongRead(texts: string[], synthMs: (index: number) => Promise<number>, clock: FakeClock): Promise<Played[]> {
  const played: Played[] = [];
  const signal = new AbortController().signal;
  await clock.until(runLongRead(texts, "virtual", signal, {
    synthesize: async (_text, index) => ({ audioFile: `virtual-${index}`, durationMs: await synthMs(index), wordBoundaries: [] }) satisfies LongReadChunk,
    play: (chunk, _text, info) => {
      const startMs = clock.now;
      return { started: Promise.resolve(true),
        exited: clock.sleep(chunk.durationMs).then(() => { played.push({ index: info.chunk_index, startMs, endMs: clock.now }); return { status: "completed" as const, stopped_at_ms: chunk.durationMs }; }) };
    },
    saveHistory: async () => {},
    dispose: () => {},
  }));
  return played;
}
const stallsOf = (played: Played[]) => played.slice(1).map((p, i) => p.startMs - played[i].endMs);

async function simulate(p: ProsodyPlan, lookahead?: number, concurrency?: number) {
  const clock = new FakeClock();
  const scheduler = createSegmentScheduler(p, async (segment: ProsodySegment, index) => {
    await clock.sleep(SYNTH(segment.text) + (index >= p.chunks[0].end ? DECODE : 0));
    return segment;
  }, { signal: new AbortController().signal, lookahead, concurrency });
  const played = await driveLongRead(p.chunks.map((c) => c.text), async (index) => {
    const segments = await scheduler.chunk(index);
    if (index > 0) await clock.sleep(ENCODE);
    return segments.reduce((ms, s) => ms + AUDIO(s.text) + s.pauseMs, 0);
  }, clock);
  return { firstAudioMs: played[0].startMs, stalls: stallsOf(played) };
}

async function simulateMain(text: string) {
  const clock = new FakeClock(), texts = chunkTextForTTS(text);
  const played = await driveLongRead(texts, async (index) => {
    const speech = projectSpeakableText(texts[index], [], "edge").speechText;
    await clock.sleep(SYNTH(speech));
    return AUDIO(speech);
  }, clock);
  return { firstAudioMs: played[0].startMs, stalls: stallsOf(played) };
}

describe("latency vs main (fake timed synth)", () => {
  for (const [name, text, ask] of corpus) it(`${name}: first audio never later than main, and no join stall`, async () => {
    const p = plan(text, ask);
    expect(p.chunks[0].end - p.chunks[0].first).toBe(1);
    const { firstAudioMs, stalls } = await simulate(p);
    const main = await simulateMain(text);
    // The only allowance: the spec's closing period on an emphasized chunk 0 ("A" → "A.") costs its characters.
    const added = p.segments[0].emphasis ? p.segments[0].text.length - (p.segments[0].speech.end - p.segments[0].speech.start) : 0;
    expect(firstAudioMs).toBeLessThanOrEqual(main.firstAudioMs + 5 * added);
    expect(stalls).toEqual(stalls.map(() => 0));
  });
  it("the model detects stalls: serial synthesis (one request at a time, no prefetch) stalls structured reads", async () => {
    let stalled = 0;
    for (const [, text, ask] of corpus) stalled += (await simulate(plan(text, ask), 0, 1)).stalls.filter((ms) => ms > 0).length;
    expect(stalled).toBeGreaterThan(0);
  });
});
