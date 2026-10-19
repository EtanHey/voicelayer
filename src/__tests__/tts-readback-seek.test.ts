import { expect, it, spyOn } from "bun:test";
import { createHash } from "node:crypto";
import { writeFileSync, unlinkSync, existsSync, readFileSync } from "node:fs";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as alignment from "../tts/clone-alignment";
import { projectSpeakableText } from "../speakable-text";
import * as socket from "../socket-client";
import { reserveStandardVoiceOperation } from "../voice-operation-reservation";
import { parseCommand } from "../socket-protocol";
import { runLongRead, type LongReadSeek } from "../tts/long-read";
import { RetainedReadback } from "../tts/retained-readback";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier } from "./long-read-fixture-barriers";

it("validates explicit retained identity without changing legacy current seeks", () => {
  expect(parseCommand('{"cmd":"seek","scope":"readback","readback_id":"speech-1","offset_ms":300}'))
    .toEqual({ cmd: "seek", scope: "readback", readback_id: "speech-1", offset_ms: 300 });
  expect(parseCommand('{"cmd":"seek","scope":"readback","offset_ms":300}')).toBeNull();
});

for (const [count, played, stopped, clone] of [[1, 1, false, false], [3, 3, false, false], [3, 2, true, false], [1, 1, false, true]] as const) it(`replays ${clone ? "clone" : stopped ? "stopped" : "ended"} ${played}/${count}-chunk readback at its exact offset without synthesis`, async () => {
  const sources = Array.from({ length: count }, (_, i) => `${TEST_TMP}/ended-${i}.mp3`);
  for (const file of sources) writeFileSync(file, "original utterance");
  const players = fixtureBarrier<any>(), conversions = fixtureBarrier<string[]>(), events: any[] = [], trims: string[][] = [];
  let holdTrim = false;
  const subtitles = fixtureBarrier<any>(), alignments: alignment.CloneAlignmentRequest[] = [];
  const aligner = spyOn(alignment, "alignCloneAudio").mockImplementation(async request => {
    alignments.push(request);
    return { status: "timed", identity: { requestId: request.requestId, chunkId: request.chunkId,
      playbackRate: 1, audioSha256: createHash("sha256").update(readFileSync(request.audioPath)).digest("hex") },
      words: [{ text: "Chunk", displayRange: { start: 0, end: 5 }, offset_ms: 300, duration_ms: 200 },
              { text: "0", displayRange: { start: 6, end: 7 }, offset_ms: null, duration_ms: null }] };
  });
  const decode = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({
    result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel() {},
  });
  const broadcast = spyOn(socket, "broadcast").mockImplementation(e => { events.push(e); if (e.type === "subtitle" && e.aligned_words) subtitles.push(e); });
  const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
    const exit = deferred<number>();
    if (argv[1] === "-version" || argv[1] === "--version") exit.resolve(0);
    else if (argv[0] === "which") exit.resolve(0);
    else if (argv.includes("-ss")) { trims.push(argv); conversions.push(argv); writeFileSync(argv.at(-1)!, "slice"); if (!holdTrim) exit.resolve(0); }
    else { players.push({ argv, exit }); }
    return { pid: 94000 + players.values.length, exited: exit.promise, kill: () => exit.resolve(143),
      stdout: new Blob(["/fake/ffmpeg"]).stream() };
  }) as any);
  try {
    for (const [i, source] of sources.slice(0, played).entries()) {
      const handle = tts.playAudioNonBlocking(source, { text: `Chunk ${i}`, voice: "test", durationMs: 1000,
        ...(count > 1 ? { longRead: { id: `original-read-${count}-${played}`, chunk_index: i, chunk_count: count, chunk_start_ms: i * 1000 } } : {}),
        ...(clone ? { cloneProjection: projectSpeakableText(`Chunk ${i}`, [], "clone") }
          : { wordBoundaries: [{ text: "word", offset_ms: 300, duration_ms: 200 }] }) });
      const player = await players.at(i);
      if (clone) await subtitles.at(i);
      if (stopped && i === played - 1) tts.stopPlayback();
      else player.exit.resolve(0);
      await handle.playerExited; await tts.awaitCurrentPlayback();
      unlinkSync(source);
    }
    const readbackID = events.find(e => e.state === "speaking").readback_id;
    const offset = count > 1 ? 1300 : 300;
    expect(tts.seekPlayback(offset, "readback", "stale-owner")).toMatchObject({ outcome: "reject" });
    const operation = reserveStandardVoiceOperation()!;
    expect(tts.seekPlayback(offset, "readback", readbackID)).toMatchObject({ outcome: "reject", reason: "busy" });
    operation.release();
    expect(tts.seekPlayback(offset, "readback", readbackID)).toMatchObject({ outcome: "accept", offset_ms: offset });
    expect(tts.seekPlayback(offset, "readback", readbackID)).toMatchObject({ outcome: "reject", reason: "busy" });
    const replay = await players.at(played);
    if (clone) {
      // WORDTIME1 S4: the retained snapshot re-broadcasts the first run's timings at start; re-alignment still runs.
      expect((await subtitles.at(1)).aligned_words[0].offset_ms).toBe(300);
      expect((await subtitles.at(2)).aligned_words[0].offset_ms).toBe(300);
      expect(alignments[1].audioPath).toBe(trims[0][trims[0].indexOf("-i") + 1]);
      expect(alignments[1].audioPath).not.toBe(replay.argv.at(-1));
      expect(alignments[1].speechText).toBe("Chunk 0");
    }
    expect(trims).toHaveLength(1);
    expect(trims[0][trims[0].indexOf("-ss") + 1]).toBe("0.3");
    expect(trims[0][trims[0].indexOf("-i") + 1]).not.toBe(sources[count > 1 ? 1 : 0]);
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text: `Chunk ${count > 1 ? 1 : 0}`, playback_offset_ms: offset, readback_id: readbackID });
    // SCRUB1: a replayed read's total is already final, so the scrubber never says "so far".
    if (count > 1) expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ duration_ms: played * 1000,
      long_read: { estimated_total_ms: played * 1000 } });
    replay.exit.resolve(0);
    if (played > 2) {
      const tail = await players.at(played + 1);
      expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text: "Chunk 2", playback_offset_ms: 2000 });
      tail.exit.resolve(0);
    }
    await tts.awaitCurrentPlayback();
    if (stopped) expect(tts.seekPlayback(2300, "readback", readbackID))
      .toMatchObject({ outcome: "reject", reason: "Replay position unavailable" });
    const playedCount = players.values.length;
    holdTrim = true;
    expect(tts.seekPlayback(offset, "readback", readbackID).outcome).toBe("accept");
    await conversions.at(1);
    tts.stopPlayback(); // Stop owns and cancels initial replay preparation too.
    await tts.awaitCurrentPlayback();
    expect(players.values).toHaveLength(playedCount);
    // Evicted media must fail clearly instead of replaying some other history row.
    unlinkSync(trims[0][trims[0].indexOf("-i") + 1]);
    expect(tts.seekPlayback(300, "readback", readbackID)).toMatchObject({ outcome: "reject", reason: "Replay prefix audio unavailable" });
  } finally {
    tts.stopPlayback(); for (const p of players.values) p.exit.resolve(0);
    await tts.awaitCurrentPlayback(); spawn.mockRestore(); decode.mockRestore(); broadcast.mockRestore(); aligner.mockRestore();
  }
});


it("consuming a prepared current-seek target does not prepare the initial readback slice again", async () => {
  const controller = new AbortController(), second = deferred<any>(), entered = deferred<void>();
  const plays = fixtureBarrier<any>(), exit = deferred<any>();
  const preparations: number[] = [];
  let control!: LongReadSeek;
  const done = runLongRead(["first", "second"], "initial-replacement", controller.signal, {
    initialOffsetMs: 1300,
    registerSeek: value => { control = value; },
    synthesize: async (_text, index) => {
      if (index === 1) { entered.resolve(); return second.promise; }
      return { audioFile: "first.mp3", durationMs: 1000, wordBoundaries: [] };
    },
    prepareSeek: async (_chunk, offset) => { preparations.push(offset); return "target.wav"; },
    play: (_chunk, _text, _info, position) => {
      plays.push(position);
      return { started: Promise.resolve(true), exited: exit.promise };
    },
    saveHistory: async () => {}, dispose: () => {},
  });
  try {
    await entered.promise;
    expect(control.seek(500).outcome).toBe("accept");
    expect((await plays.at(0)).sliceFile).toBe("target.wav");
    expect(preparations).toEqual([500]);
  } finally {
    controller.abort(); exit.resolve({ status: "interrupted", stopped_at_ms: 500 });
    second.resolve({ audioFile: "second.mp3", durationMs: 1000, wordBoundaries: [] });
    await done;
  }
});


it("exit cleanup removes both the pinned retired copy and current retained audio", () => {
  const cache = new RetainedReadback(), source = `${TEST_TMP}/exit-cleanup.mp3`;
  writeFileSync(source, "synthetic audio");
  const metadata = { text: "synthetic", voice: "test", durationMs: 1000 };
  const firstID = cache.remember(source, metadata, "first");
  const first = cache.acquire(firstID)!;
  const nextID = cache.remember(source, metadata, "next");
  const next = cache.acquire(nextID)!;
  expect(existsSync(first.chunks[0].file)).toBe(true);
  cache.dispose();
  expect(existsSync(first.chunks[0].file)).toBe(false);
  expect(existsSync(next.chunks[0].file)).toBe(false);
  first.release(); next.release(); unlinkSync(source);
});
