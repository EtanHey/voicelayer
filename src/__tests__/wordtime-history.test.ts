import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as alignment from "../tts/clone-alignment";
import * as input from "../input";
import * as recording from "../recording-state";
import * as socket from "../socket-client";
import { projectSpeakableText } from "../speakable-text";
import { handleSocketCommand } from "../socket-handlers";
import { clipAlignedWordsToText, combineHistoryTimings } from "../tts/history-timings";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier } from "./long-read-fixture-barriers";

const row = (word_index: number, text: string, offset_ms: number | null = null, duration_ms: number | null = null) =>
  ({ word_index, text, offset_ms, duration_ms });

describe("WORDTIME1 history timings", () => {
  it("appends chunk timings with shifted indices and offsets; an untimed chunk erases nothing", () => {
    expect(combineHistoryTimings([
      { text: "one two", durationMs: 1000, aligned: [row(0, "one", 100, 200), row(1, "two")] },
      { text: "three four", durationMs: 800 },
      { text: "five, six.", durationMs: 900, words: [{ text: "five,", offset_ms: 50, duration_ms: 100 }, { text: "six.", offset_ms: 300, duration_ms: 0 }] },
    ])).toEqual([row(0, "one", 100, 200), row(1, "two"), row(2, "three"), row(3, "four"),
      row(4, "five,", 1850, 100), row(5, "six.")]);
  });

  it("never stores a timing past its chunk's audio or for a token it does not match", () => {
    expect(combineHistoryTimings([{ text: "go home", durationMs: 500,
      aligned: [row(0, "go", 100, 450), row(1, "away", 200, 100)] }])).toBeUndefined();
  });

  it("clips stored timings to the text replay actually displays", () => {
    const words = [row(0, "alpha", 0, 100), row(1, "beta", 200, 100), row(2, "gamma", 400, 100)];
    expect(clipAlignedWordsToText(words, "alpha beta gam")).toEqual(words.slice(0, 2));
  });

  it("persists a read's timings and lets a late clone alignment land on the same entry only", () => {
    const file = `${TEST_TMP}/wordtime-history.mp3`; writeFileSync(file, "audio");
    const words = [{ text: "Hello", offset_ms: 0, duration_ms: 300 }];
    const find = (ref: tts.TTSHistoryRef) => tts.loadHistory().find(e => e.id === ref.id && e.timestamp === ref.timestamp)!;
    const edge = tts.addToHistory("Hello", file, "edge", [], { wordBoundaries: words })!;
    expect(find(edge)).toMatchObject({ text: "Hello", wordBoundaries: words });
    const clone = tts.addToHistory("Hi there", file, "clone")!;
    tts.updateHistoryAlignedWords(clone, [row(0, "Hi", 0, 100), row(1, "there")]);
    expect(find(clone).alignedWords).toEqual([row(0, "Hi", 0, 100), row(1, "there")]);
    expect(find(edge).alignedWords).toBeUndefined();
    tts.updateHistoryAlignedWords({ ...clone, timestamp: clone.timestamp - 1 }, [row(0, "Hi", 5, 10)]);
    tts.updateHistoryAlignedWords(clone, [row(0, "Hi"), row(1, "there")]);
    expect(find(clone).alignedWords![0].offset_ms).toBe(0);
  });
});

describe("WORDTIME1 replay re-broadcasts stored timings", () => {
  let spies: ReturnType<typeof spyOn>[] = [];
  beforeEach(() => {
    spies = [spyOn(input, "getRecordingState").mockReturnValue("idle"),
      spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
      spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0)];
  });
  afterEach(() => { for (const spy of spies) spy.mockRestore(); });

  it("hands the history entry's timings to the replay playback", () => {
    const file = `${TEST_TMP}/wordtime-replay.mp3`; writeFileSync(file, "audio");
    const alignedWords = [row(0, "Retained", 0, 300), row(1, "speech.", 400, 300)];
    const wordBoundaries = [{ text: "Retained", offset_ms: 0, duration_ms: 300 }];
    spies.push(spyOn(tts, "getHistoryEntry").mockReturnValue({ id: 0, text: "Retained speech.", voice: "v", file, timestamp: 0, alignedWords, wordBoundaries }));
    const enqueue = spyOn(tts, "playAudioNonBlocking").mockImplementation(() => undefined as any); spies.push(enqueue);
    expect(handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "accept" });
    expect(enqueue).toHaveBeenCalledWith(file, { text: "Retained speech.", voice: "v", alignedWords, wordBoundaries });
  });
});

describe("WORDTIME1 playback publishes and re-broadcasts aligned timings", () => {
  it("records a clone read's aligned words and broadcasts stored ones at start", async () => {
    const source = `${TEST_TMP}/wordtime-clone.mp3`; writeFileSync(source, "clone audio");
    const players = fixtureBarrier<any>(), events: any[] = [];
    const aligner = spyOn(alignment, "alignCloneAudio").mockImplementation(async request => ({
      status: "timed", identity: { requestId: request.requestId, chunkId: request.chunkId, playbackRate: 1,
        audioSha256: createHash("sha256").update(readFileSync(request.audioPath)).digest("hex") },
      words: [{ text: "Hi", displayRange: { start: 0, end: 2 }, offset_ms: 100, duration_ms: 200 },
              { text: "there", displayRange: { start: 3, end: 8 }, offset_ms: null, duration_ms: null }] }) as any);
    const decode = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({
      result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel() {} });
    const broadcast = spyOn(socket, "broadcast").mockImplementation(e => { events.push(e); });
    const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
      const exit = deferred<number>();
      if (argv[1] === "-version" || argv[1] === "--version" || argv[0] === "which") exit.resolve(0);
      else players.push({ argv, exit });
      return { pid: 95000 + players.values.length, exited: exit.promise, kill: () => exit.resolve(143), stdout: new Blob(["/fake/bin"]).stream() };
    }) as any);
    try {
      const published = deferred<any>();
      const first = tts.playAudioNonBlocking(source, { text: "Hi there", voice: "clone", durationMs: 1000,
        cloneProjection: projectSpeakableText("Hi there", [], "clone"), onAlignedWords: words => published.resolve(words) });
      (await players.at(0));
      expect(await published.promise).toEqual([row(0, "Hi", 100, 200), row(1, "there")]);
      expect(events.find(e => e.type === "subtitle")).toMatchObject({ duration_ms: 1000 });
      players.values[0].exit.resolve(0); await first.playerExited; await tts.awaitCurrentPlayback();

      events.length = 0;
      const replay = tts.playAudioNonBlocking(source, { text: "Hi there", voice: "clone", durationMs: 1000,
        alignedWords: [row(0, "Hi", 100, 200), row(1, "there")] });
      await players.at(1);
      expect(events.find(e => e.type === "subtitle")).toEqual({ type: "subtitle", words: [],
        aligned_words: [row(0, "Hi", 100, 200), row(1, "there")], duration_ms: 1000 });
      players.values[1].exit.resolve(0); await replay.playerExited;
    } finally {
      tts.stopPlayback(); await tts.awaitCurrentPlayback();
      aligner.mockRestore(); decode.mockRestore(); broadcast.mockRestore(); spawn.mockRestore();
    }
  });
});
