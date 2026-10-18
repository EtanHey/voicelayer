import { expect, it, spyOn } from "bun:test";
import { writeFileSync, unlinkSync } from "node:fs";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import { reserveStandardVoiceOperation } from "../voice-operation-reservation";
import { parseCommand } from "../socket-protocol";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier } from "./long-read-fixture-barriers";

it("validates explicit retained identity without changing legacy current seeks", () => {
  expect(parseCommand('{"cmd":"seek","scope":"readback","readback_id":"speech-1","offset_ms":300}'))
    .toEqual({ cmd: "seek", scope: "readback", readback_id: "speech-1", offset_ms: 300 });
  expect(parseCommand('{"cmd":"seek","scope":"readback","offset_ms":300}')).toBeNull();
});

for (const count of [1, 3]) it(`replays ended ${count}-chunk readback at its exact offset without synthesis`, async () => {
  const sources = Array.from({ length: count }, (_, i) => `${TEST_TMP}/ended-${i}.mp3`);
  for (const file of sources) writeFileSync(file, "original utterance");
  const players = fixtureBarrier<any>(), conversions = fixtureBarrier<string[]>(), events: any[] = [], trims: string[][] = [];
  let holdTrim = false;
  const decode = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({
    result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel() {},
  });
  const broadcast = spyOn(socket, "broadcast").mockImplementation(e => { events.push(e); });
  const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
    const exit = deferred<number>();
    if (argv[1] === "-version") exit.resolve(0);
    else if (argv[0] === "which") exit.resolve(0);
    else if (argv.includes("-ss")) { trims.push(argv); conversions.push(argv); writeFileSync(argv.at(-1)!, "slice"); if (!holdTrim) exit.resolve(0); }
    else { players.push({ argv, exit }); }
    return { pid: 94000 + players.values.length, exited: exit.promise, kill: () => exit.resolve(143),
      stdout: new Blob(["/fake/ffmpeg"]).stream() };
  }) as any);
  try {
    for (const [i, source] of sources.entries()) {
      const handle = tts.playAudioNonBlocking(source, { text: `Chunk ${i}`, voice: "test", durationMs: 1000,
        ...(count > 1 ? { longRead: { id: "original-read", chunk_index: i, chunk_count: count, chunk_start_ms: i * 1000 } } : {}),
        wordBoundaries: [{ text: "word", offset_ms: 300, duration_ms: 200 }] });
      (await players.at(i)).exit.resolve(0);
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
    const replay = await players.at(count);
    expect(trims).toHaveLength(1);
    expect(trims[0][trims[0].indexOf("-ss") + 1]).toBe("0.3");
    expect(trims[0][trims[0].indexOf("-i") + 1]).not.toBe(sources[count > 1 ? 1 : 0]);
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text: `Chunk ${count > 1 ? 1 : 0}`, playback_offset_ms: offset, readback_id: readbackID });
    replay.exit.resolve(0);
    if (count > 1) {
      const tail = await players.at(count + 1);
      expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text: "Chunk 2", playback_offset_ms: 2000 });
      tail.exit.resolve(0);
    }
    await tts.awaitCurrentPlayback();
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
    await tts.awaitCurrentPlayback(); spawn.mockRestore(); decode.mockRestore(); broadcast.mockRestore();
  }
});
